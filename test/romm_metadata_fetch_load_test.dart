import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';
import 'package:neostation/services/romm/romm_paging.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// Characterisation of the load the per-system RomM metadata pass puts on
/// the server: how many requests are in flight at once, and how many
/// requests one game costs.
///
/// #535 (upstream) fixed the browse grid's covers after an unbounded client
/// starved the server; the lesson was that "it has a bound" has to be
/// measured by a test, not asserted in a comment. These tests measure the
/// pass's bound through the real writer (`RommProvider
/// .fetchMetadataForRomId`) against a fake server that records concurrency,
/// so detail GETs and media downloads both count.
///
/// What is pinned:
/// * peak simultaneous server requests across a 50-game pass is within
///   `RommPaging.concurrency`, in fill-gaps and in replace mode — and is
///   greater than one, so the pool really does parallelise (a measurement of
///   1 would say nothing about the bound);
/// * the exact request count for one game with nothing on disk, with all
///   media already on disk in fill-gaps mode (must skip the downloads), and
///   in replace mode (must redownload);
/// * the ad-hoc paths that call the writer directly (link confirm, browser
///   confirm, download completion) have **no** pool of their own — pinned
///   here as current behaviour so a later change has something to flip.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

const _coverUrl = '/assets/romm/resources/roms/1/42/cover/big.png';
const _fanartUrl = '/assets/romm/resources/roms/1/42/fanart.png';
const _logoUrl = '/assets/romm/resources/roms/1/42/logo.png';
const _screenshotUrl = '/assets/romm/resources/roms/1/42/ss1.png';
const _videoUrl = '/assets/romm/resources/roms/1/42/video.mp4';

final Uint8List _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
]);
final Uint8List _mp4 = Uint8List.fromList([0, 0, 0, 0x18, 0x66, 0x74, 0x79]);

/// A detail with every media field populated, every first candidate
/// fetchable — the richest single game the writer will ever ask for.
Map<String, dynamic> _detail(int romId) => {
  'id': romId,
  'name': 'Game $romId',
  'fs_name': 'game$romId.sfc',
  'fs_name_no_ext': 'game$romId',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
  'summary': 'A game.',
  'metadatum': const {
    'genres': ['RPG'],
    'companies': ['Square'],
    'player_count': '1',
  },
  'path_cover_large': _coverUrl,
  'ss_metadata': const {
    'fanart_path': 'roms/1/42/fanart.png',
    'logo_path': 'roms/1/42/logo.png',
    'title_screen_path': 'roms/1/42/title.png',
    'video_path': 'roms/1/42/video.mp4',
  },
  'merged_screenshots': const [_screenshotUrl],
};

/// A detail with no media fields at all — one request, nothing else.
Map<String, dynamic> _bareDetail(int romId) => {
  'id': romId,
  'name': 'Game $romId',
  'fs_name': 'game$romId.sfc',
  'fs_name_no_ext': 'game$romId',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
};

/// The fake server: scripts details and assets, and measures how many calls
/// are in flight at once. Every call yields to the event loop several times
/// while counted as in flight, so a pool that does not bound its workers
/// shows up as a high peak rather than accidentally serialising.
class _RecordingService extends RommService {
  final Map<int, Map<String, dynamic>> details;
  final Map<String, Uint8List> assets;

  _RecordingService({required this.details, required this.assets});

  int _inFlight = 0;
  int peakInFlight = 0;
  int detailCalls = 0;
  int mediaCalls = 0;

  Future<void> _hold() async {
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    // Enough turns for the pool's other workers to start their own calls;
    // one turn is not enough when callers await in a tight sequence.
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    _inFlight--;
  }

  @override
  Future<RommDetailFetch> fetchRomDetail(int id) async {
    detailCalls++;
    await _hold();
    final body = details[id];
    return body == null
        ? const RommDetailFetch.missing(RommDetailMiss.absent)
        : RommDetailFetch.found(body);
  }

  @override
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    mediaCalls++;
    await _hold();
    final bytes = assets[pathOrUrl];
    return bytes == null
        ? const RommImageFetch.missing(RommImageMiss.absent)
        : RommImageFetch.found(bytes);
  }
}

class _TestProvider extends RommProvider {
  final RommService fake;
  _TestProvider(this.fake);

  @override
  RommService get service => fake;
}

/// Media paths rooted in a temp directory, the same shape the app writes.
class _TempMedia extends FileProvider {
  final String root;
  _TempMedia(this.root);

  @override
  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) => p.join(
    root,
    systemFolderName,
    imageType,
    '${p.basenameWithoutExtension(romName)}.$extension',
  );
}

DatabaseGameModel _game(int i) => DatabaseGameModel(
  filename: 'game$i.sfc',
  romPath: '/roms/snes/game$i.sfc',
  systemFolderName: 'snes',
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late _TempMedia media;
  late _TestProvider provider;
  late _RecordingService svc;

  /// A pass over [count] games whose map rows point at rom ids 0..count-1.
  RommMetadataFetch pass(int count) => RommMetadataFetch(
    listGames: (folder) async => [for (var i = 0; i < count; i++) _game(i)],
    linkIndex: () async => RommRomIdIndex({
      for (var i = 0; i < count; i++)
        RommRomIdIndex.keyFor('snes', 'game$i.sfc'): i,
    }),
    fetchOne: (target, system, mode) => provider.fetchMetadataForRomId(
      romId: target.romId,
      system: system,
      fileProvider: media,
      indexedName: target.indexedName,
      mode: mode,
    ),
  );

  setUp(() async {
    RommMetadataNetwork.resetForTesting();
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(
      "INSERT INTO app_systems (id, folder_name) VALUES ('snes', 'snes')",
    );
    root = await Directory.systemTemp.createTemp('romm_load_');
    media = _TempMedia(root.path);
    svc = _RecordingService(
      details: {for (var i = 0; i < 60; i++) i: _detail(i)},
      assets: {
        _coverUrl: _png,
        _fanartUrl: _png,
        _logoUrl: _png,
        _screenshotUrl: _png,
        _videoUrl: _mp4,
      },
    );
    provider = _TestProvider(svc);
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  group('peak in-flight requests, 50-game pass', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
    test('fill-gaps mode stays within the pool bound', () async {
      final summary = await pass(50).run(_snes, RommMetadataMode.fillGaps);

      expect(summary.filled, 50);
      expect(summary.failed, 0, reason: 'a healthy fake server');
      expect(
        svc.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
        reason:
            'the pass must not put more requests on the server at once than '
            'RommPaging.concurrency allows',
      );
      expect(
        svc.peakInFlight,
        greaterThan(1),
        reason:
            'the pool must actually parallelise — a peak of 1 would mean this '
            'test measured nothing about the bound',
      );
    });

    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
    test('replace mode stays within the pool bound', () async {
      final summary = await pass(50).run(_snes, RommMetadataMode.replace);

      expect(summary.replaced, 50);
      expect(summary.failed, 0);
      expect(svc.peakInFlight, lessThanOrEqualTo(RommPaging.concurrency));
      expect(svc.peakInFlight, greaterThan(1));
    });
  });

  group('requests per game', () {
    test('nothing on disk: one detail GET plus five media downloads', () async {
      await provider.fetchMetadataForRomId(
        romId: 0,
        system: _snes,
        fileProvider: media,
        indexedName: 'game0.sfc',
        mode: RommMetadataMode.fillGaps,
      );

      expect(svc.detailCalls, 1, reason: 'the detail is read once');
      expect(
        svc.mediaCalls,
        5,
        reason:
            'box2d, fanarts, wheels, screenshots and videos — each fetched '
            'once when the first candidate answers with bytes',
      );
      expect(svc.detailCalls + svc.mediaCalls, 6);
    });

    test(
      'all media on disk, fill-gaps: the detail only, every download skipped',
      () async {
        for (final type in ['box2d', 'fanarts', 'wheels', 'screenshots']) {
          final file = File(
            media.getMediaPath('snes', type, 'game0.sfc', 'png'),
          );
          await file.create(recursive: true);
          await file.writeAsBytes(_png);
        }
        final video = File(
          media.getMediaPath('snes', 'videos', 'game0.sfc', 'mp4'),
        );
        await video.create(recursive: true);
        await video.writeAsBytes(_mp4);

        final outcome = await provider.fetchMetadataForRomId(
          romId: 0,
          system: _snes,
          fileProvider: media,
          indexedName: 'game0.sfc',
          mode: RommMetadataMode.fillGaps,
        );

        expect(outcome.mediaSkipped, 5, reason: 'nothing is redownloaded');
        expect(svc.mediaCalls, 0, reason: 'existing files are never asked for');
        expect(svc.detailCalls, 1);
        expect(svc.detailCalls + svc.mediaCalls, 1);
      },
    );

    test('all media on disk, replace mode: redownloads everything', () async {
      for (final type in ['box2d', 'fanarts', 'wheels', 'screenshots']) {
        final file = File(media.getMediaPath('snes', type, 'game0.sfc', 'png'));
        await file.create(recursive: true);
        await file.writeAsBytes(_png);
      }
      final video = File(
        media.getMediaPath('snes', 'videos', 'game0.sfc', 'mp4'),
      );
      await video.create(recursive: true);
      await video.writeAsBytes(_mp4);

      final outcome = await provider.fetchMetadataForRomId(
        romId: 0,
        system: _snes,
        fileProvider: media,
        indexedName: 'game0.sfc',
        mode: RommMetadataMode.replace,
      );

      expect(outcome.mediaWritten, 5, reason: 'replace means take it again');
      expect(svc.mediaCalls, 5);
      expect(svc.detailCalls, 1);
      expect(svc.detailCalls + svc.mediaCalls, 6);
    });

    test('a detail with no media fields costs exactly one request', () async {
      svc.details[0] = _bareDetail(0);

      await provider.fetchMetadataForRomId(
        romId: 0,
        system: _snes,
        fileProvider: media,
        indexedName: 'game0.sfc',
        mode: RommMetadataMode.fillGaps,
      );

      expect(svc.detailCalls, 1);
      expect(svc.mediaCalls, 0);
    });
  });

  group('ad-hoc writer calls', () {
    // The link-picker confirm, the browser's "already downloaded" confirm
    // and a completed download all call the writer directly. They used to
    // have no bound at all (Round 1 pinned peak 2 for two concurrent
    // confirms); they now share the pass's gate, so the bound holds.
    test('six concurrent link-confirm fetches share the pass bound', () async {
      await Future.wait([
        for (var i = 0; i < 6; i++)
          provider.fetchMetadataForRomId(
            romId: i,
            system: _snes,
            fileProvider: media,
            indexedName: 'game$i.sfc',
            mode: RommMetadataMode.fillGaps,
          ),
      ]);

      expect(
        svc.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
        reason: 'the shared gate must bound ad-hoc calls too',
      );
      expect(
        RommMetadataNetwork.instance.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
      );
    });

    // Equal sizes (pass pool 3, gate 3) must not deadlock: the gate is
    // acquired once per call, in the writer, and the pass's runBounded
    // workers never hold it themselves. A deadlock hangs this test until
    // the framework's timeout fails it.
    test(
      'a pass and a burst of ad-hoc calls share the bound without deadlocking',
      () async {
        final adHoc = Future.wait([
          for (var i = 10; i < 20; i++)
            provider.fetchMetadataForRomId(
              romId: i,
              system: _snes,
              fileProvider: media,
              indexedName: 'game$i.sfc',
              mode: RommMetadataMode.replace,
            ),
        ]);

        final summary = await pass(10).run(_snes, RommMetadataMode.fillGaps);
        final outcomes = await adHoc;

        expect(summary.filled, 10, reason: 'the pass finished');
        expect(
          outcomes.every((o) => o.kind == RommMetadataOutcomeKind.replaced),
          isTrue,
          reason: 'every ad-hoc call finished',
        );
        expect(
          svc.peakInFlight,
          lessThanOrEqualTo(RommPaging.concurrency),
          reason:
              'pass pool and ad-hoc burst together must stay within the '
              'shared bound',
        );
        expect(
          RommMetadataNetwork.instance.peakInFlight,
          lessThanOrEqualTo(RommPaging.concurrency),
        );
      },
    );
  });
}
