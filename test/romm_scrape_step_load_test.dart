import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';
import 'package:neostation/services/romm/romm_paging.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// Characterisation of the load the RomM-first scrape chain puts on the
/// server, measured through the real writer behind a fake `RommService`
/// that records how many requests are in flight at once.
///
/// The step's fetches run inside `fetchMetadataForRomId`, which takes the
/// writer's shared gate (sized `RommPaging.concurrency`) once per call; the
/// measurements below pin that the same bound holds when the chain is driven
/// by the scrape entry points:
/// * one `scrapeSingleGame` with the provider step;
/// * a whole bulk scrape (`startMetadataScraping`) across all its workers,
///   driven at a worker count larger than the gate;
/// * a bulk scrape and a per-system metadata pass running at the same time.
///
/// This is Round 1's ledger: it records the load as the chain stands before
/// any server-protection behaviour is added, so anything a later change does
/// to these numbers has to be argued against them.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

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

/// The asset URL for a fresh detail's media, and the detail itself, keyed on
/// the rom id so games never share asset keys and the counts stay per game.
const _coverUrl = '/assets/romm/resources/roms/1/_ID_/cover/big.png';
const _fanartUrl = '/assets/romm/resources/roms/1/_ID_/fanart.png';
const _logoUrl = '/assets/romm/resources/roms/1/_ID_/logo.png';
const _screenshotUrl = '/assets/romm/resources/roms/1/_ID_/ss1.png';
const _videoUrl = '/assets/romm/resources/roms/1/_ID_/video.mp4';

String _withId(String template, int id) => template.replaceAll('_ID_', '$id');

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
  },
  'path_cover_large': _withId(_coverUrl, romId),
  'ss_metadata': {
    'fanart_path': 'roms/1/$romId/fanart.png',
    'logo_path': 'roms/1/$romId/logo.png',
    'title_screen_path': 'roms/1/$romId/title.png',
    'video_path': 'roms/1/$romId/video.mp4',
  },
  'merged_screenshots': [_withId(_screenshotUrl, romId)],
};

/// The fake server: scripts details and assets, and measures how many calls
/// are in flight at once. Every call yields to the event loop several times
/// are in flight at once. Every call yields to the event loop several times
/// while counted as in flight, so a path that does not bound its callers
/// shows up as a high peak rather than accidentally serialising.
class _RecordingService extends RommService {
  final Map<int, Map<String, dynamic>> details;
  final Map<String, Uint8List> assets;

  _RecordingService({required this.details, required this.assets});

  int _inFlight = 0;
  int peakInFlight = 0;
  int detailCalls = 0;
  int mediaCalls = 0;
  final List<int> detailRequestOrder = [];

  Future<void> _hold() async {
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    _inFlight--;
  }

  @override
  Future<RommDetailFetch> fetchRomDetail(int id) async {
    detailCalls++;
    detailRequestOrder.add(id);
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
  bool connected = true;
  _TestProvider(this.fake);

  @override
  RommService get service => fake;

  @override
  bool get isConnected => connected;
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

/// The only thing `startMetadataScraping` asks its context is `mounted`,
/// right before the summary dialog; an unmounted context skips the dialog.
class _NoScreenContext implements BuildContext {
  @override
  bool get mounted => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('BuildContext.${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // ScrapingProvider toggles the wakelock on start/stop; answer its pigeon
    // channel so the plugin call does not fail the test with no platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late _TempMedia media;
  late _RecordingService svc;
  late _TestProvider provider;

  setUp(() async {
    RommMetadataNetwork.resetForTesting();
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(
      "INSERT INTO app_systems (id, folder_name, real_name, screenscraper_id) "
      "VALUES ('snes', 'snes', 'Super Nintendo', 4)",
    );
    root = await Directory.systemTemp.createTemp('romm_scrape_load_');
    media = _TempMedia(root.path);
    svc = _RecordingService(
      details: {for (var i = 0; i < 80; i++) i: _detail(i)},
      assets: {
        for (var i = 0; i < 80; i++) ...{
          _withId(_coverUrl, i): _png,
          _withId(_fanartUrl, i): _png,
          _withId(_logoUrl, i): _png,
          _withId(_screenshotUrl, i): _png,
          _withId(_videoUrl, i): _mp4,
        },
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

  Future<void> seedLinkedGames(
    int count, {
    String prefix = 'game',
    int romIdBase = 0,
  }) async {
    // What the bulk pipeline reads before scraping: the detected systems
    // join and the ROMs to scrape.
    await db.execute(
      "INSERT OR IGNORE INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('snes', 'snes')",
    );
    for (var i = 0; i < count; i++) {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) "
        "VALUES ('$prefix$i.sfc', '/roms/snes/$prefix$i.sfc', 'snes')",
      );
      await RommSaveMapRepository.putMapping(
        romname: '$prefix$i.sfc',
        systemFolder: 'snes',
        rommRomId: romIdBase + i,
        source: RommLinkSource.download,
        fsName: '$prefix$i.sfc',
      );
    }
  }

  group('one scrapeSingleGame through the provider step', () {
    test('costs one detail GET and five media downloads, peak one', () async {
      await RommSaveMapRepository.putMapping(
        romname: 'game0.sfc',
        systemFolder: 'snes',
        rommRomId: 7,
        source: RommLinkSource.download,
        fsName: 'game0.sfc',
      );
      final step = provider.scrapeStep(media)!;

      final result = await ScreenScraperService.scrapeSingleGame(
        appSystemId: 'snes',
        romName: 'game0.sfc',
        systemFolder: 'snes',
        romPath: '/roms/snes/game0.sfc',
        rommStep: step,
      );

      expect(result['success'], isTrue);
      expect(result['source'], ScreenScraperService.scrapeSourceRomm);
      expect(
        svc.detailCalls,
        1,
        reason: 'the RomM detail for one game is read once',
      );
      expect(
        svc.mediaCalls,
        5,
        reason: 'cover, fanart, logo, screenshot and video, each fetched once',
      );
      expect(
        svc.detailCalls + svc.mediaCalls,
        6,
        reason: 'requests per game for the RomM step, nothing on disk',
      );
      expect(svc.peakInFlight, 1, reason: 'a single game cannot be parallel');
      expect(
        RommMetadataNetwork.instance.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
      );
    });
  });

  group('a whole bulk scrape across its workers', () {
    test('peak in-flight RomM requests stay within the shared gate', () async {
      const games = 8;
      await seedLinkedGames(games);
      final scrapingProvider = ScrapingProvider()..startScraping(maxThreads: 4);
      final rommStep = await provider.bulkScrapeStep(media);

      final finished = await ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        scrapingProvider,
        shouldCancel: () => false,
        rommStep: rommStep,
      );

      expect(finished, isTrue);
      expect(
        scrapingProvider.successfulGames,
        games,
        reason: 'every linked game rides RomM',
      );
      expect(
        svc.detailCalls,
        games,
        reason: 'one detail GET per game, issued through the gate',
      );
      expect(
        svc.detailCalls + svc.mediaCalls,
        games * 6,
        reason: 'six server requests per game with nothing on disk',
      );
      expect(
        svc.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
        reason:
            'the bulk workers are sized by ScreenScraper threads; the RomM '
            'load they produce is held to RommPaging.concurrency',
      );
      expect(
        svc.peakInFlight,
        greaterThan(1),
        reason: 'the bound must actually parallelise to say something',
      );
      expect(
        RommMetadataNetwork.instance.peakInFlight,
        lessThanOrEqualTo(RommPaging.concurrency),
      );
    });
  });

  group('bulk scrape and per-system pass at the same time', () {
    test(
      'share the gate without deadlocking and stay within its bound',
      () async {
        // The bulk run's games (ids 0-7, database link rows) and the pass's
        // games (ids 10-17, injected index) never overlap, so any finished
        // count tells the two runs apart unambiguously.
        await seedLinkedGames(8);
        final passGames = [
          for (var i = 0; i < 8; i++)
            DatabaseGameModel(
              filename: 'pass$i.sfc',
              romPath: '/roms/snes/pass$i.sfc',
              systemFolderName: 'snes',
            ),
        ];
        final pass = RommMetadataFetch(
          listGames: (folder) async => passGames,
          linkIndex: () async => RommRomIdIndex({
            for (var i = 0; i < 8; i++)
              RommRomIdIndex.keyFor('snes', 'pass$i.sfc'): 10 + i,
          }),
          fetchOne: (target, system, mode) => provider.fetchMetadataForRomId(
            romId: target.romId,
            system: system,
            fileProvider: media,
            indexedName: target.indexedName,
            mode: mode,
          ),
        );

        final scrapingProvider = ScrapingProvider()
          ..startScraping(maxThreads: 4);
        final rommStep = await provider.bulkScrapeStep(media);

        final bulk = ScreenScraperService.startMetadataScraping(
          _NoScreenContext(),
          scrapingProvider,
          shouldCancel: () => false,
          rommStep: rommStep,
        );

        final summary = await pass.run(_snes, RommMetadataMode.fillGaps);
        expect(await bulk, isTrue, reason: 'the bulk run finished too');

        expect(summary.filled, 8, reason: 'the pass finished completely');
        expect(scrapingProvider.successfulGames, 8, reason: 'bulk finished');
        expect(
          svc.detailCalls + svc.mediaCalls,
          16 * 6,
          reason: 'sixteen games, each costing six requests in total',
        );
        expect(
          svc.peakInFlight,
          lessThanOrEqualTo(RommPaging.concurrency),
          reason:
              'both runs together put at most RommPaging.concurrency '
              'requests in flight',
        );
        expect(
          RommMetadataNetwork.instance.peakInFlight,
          lessThanOrEqualTo(RommPaging.concurrency),
        );
      },
    );
  });
}
