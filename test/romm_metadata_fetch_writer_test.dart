import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// The RomM metadata writer ([RommProvider.fetchMetadata]) in both modes
/// (SPEC-0005 "RomM Metadata Writer With Two Modes" and "Error Handling
/// Standards") against the in-memory database, a scripted server detail, a
/// fake image fetch, and a temp media directory.
///
/// What is pinned: fill-gaps writes only empty columns and missing files and
/// leaves an existing row's scrape state and source alone; replace writes
/// every mapped column and file and stamps the row; the rating scale; the
/// not-found and not-linked outcomes; a media failure after the columns
/// landed is partial, logged with its URL; the detail is read once; and the
/// row is keyed by the map row's stored filename, never the display name.

// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "RomM Metadata Writer With Two Modes"

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

/// A minimal PNG header, enough for the extension sniff to say `png`.
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

Map<String, dynamic> _detail({num? rating = 85}) => {
  'id': 42,
  'name': 'Chrono Trigger',
  'fs_name': 'ct.sfc',
  'fs_name_no_ext': 'ct',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
  'summary': 'A time-travel RPG.',
  'metadatum': {
    'genres': ['RPG', 'Adventure'],
    'companies': ['Square'],
    'player_count': '1',
    'first_release_date': DateTime.utc(1995, 3, 11).millisecondsSinceEpoch,
    'average_rating': rating,
  },
  'path_cover_large': _coverUrl,
  'ss_metadata': {
    'fanart_path': 'roms/1/42/fanart.png',
    'logo_path': 'roms/1/42/logo.png',
    'title_screen_path': 'roms/1/42/title.png',
    'video_path': 'roms/1/42/video.mp4',
  },
  'merged_screenshots': [_screenshotUrl],
};

/// The server: one scripted detail and a map of fetchable assets.
class _FakeRommService extends RommService {
  Map<String, dynamic>? detail;
  int detailCalls = 0;
  bool detailThrows = false;
  final Map<String, Uint8List> assets = {
    _coverUrl: _png,
    _fanartUrl: _png,
    _logoUrl: _png,
    _screenshotUrl: _png,
    _videoUrl: _mp4,
  };
  final Set<String> failing = {};
  final List<String> fetched = [];

  @override
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    detailCalls++;
    if (detailThrows) throw const SocketException('timeout');
    return detail;
  }

  @override
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
  }) async {
    fetched.add(pathOrUrl);
    if (failing.contains(pathOrUrl)) {
      throw const SocketException('connection reset');
    }
    return assets[pathOrUrl];
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

GameModel _game(String romname, {String? romPath}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: romPath ?? '/roms/snes/$romname.sfc',
  systemId: 'snes',
  systemFolderName: 'snes',
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late _FakeRommService svc;
  late _TestProvider provider;
  late _TempMedia media;

  Future<Map<String, dynamic>?> row([String filename = 'ct.sfc']) =>
      ScraperRepository.getGameMetadata('snes', filename);

  File mediaFile(String type, String ext) =>
      File(media.getMediaPath('snes', type, 'ct.sfc', ext));

  Future<void> link({int romId = 42, String romname = 'ct.sfc'}) async {
    await RommSaveMapRepository.putMapping(
      romname: romname,
      systemFolder: 'snes',
      rommRomId: romId,
      source: RommLinkSource.download,
      fsName: 'ct.sfc',
    );
  }

  /// A ScreenScraper row with an English and a French description, a
  /// publisher, and a cover on disk — everything fill-gaps must leave alone.
  Future<void> scrapedRow() async {
    await ScraperRepository.saveGameMetadata(
      {
        'filename': 'ct.sfc',
        'real_name': 'Chrono Trigger (SS)',
        'description_en': 'SS English',
        'description_fr': 'SS French',
        'publisher': 'Square Soft',
      },
      'snes',
      source: MetadataSource.screenscraper,
    );
    final cover = mediaFile('box2d', 'png');
    await cover.create(recursive: true);
    await cover.writeAsString('OLD');
  }

  Future<RommMetadataOutcome> fetch(RommMetadataMode mode) =>
      provider.fetchMetadata(
        game: _game('ct'),
        system: _snes,
        mode: mode,
        fileProvider: media,
      );

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(
      "INSERT INTO app_systems (id, folder_name) VALUES ('snes', 'snes')",
    );
    root = await Directory.systemTemp.createTemp('romm_meta_');
    media = _TempMedia(root.path);
    svc = _FakeRommService()..detail = _detail();
    provider = _TestProvider(svc);
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  group('mapping', () {
    test('every mapped column, never publisher, only English', () {
      final cols = RommProvider.rommMetadataColumns(
        _detail(),
        indexedName: 'ct.sfc',
      );
      expect(cols['filename'], 'ct.sfc');
      expect(cols['real_name'], 'Chrono Trigger');
      expect(cols['description_en'], 'A time-travel RPG.');
      expect(cols['genre'], 'RPG, Adventure');
      expect(cols['developer'], 'Square');
      expect(cols['players'], '1');
      expect(cols['release_date'], '1995-03-11');
      expect(cols['rating'], 17.0);
      expect(cols.containsKey('publisher'), isFalse);
      expect(cols.keys.where((k) => k.startsWith('description_')), [
        'description_en',
      ]);
    });

    test('rating: 0-100 onto 0-20, one decimal, absent stays absent', () {
      double? ratingFor(num? r) =>
          RommProvider.rommMetadataColumns(
                _detail(rating: r),
                indexedName: 'ct.sfc',
              )['rating']
              as double?;
      expect(ratingFor(85), 17.0);
      expect(ratingFor(87), 17.4);
      expect(ratingFor(100), 20.0);
      expect(ratingFor(0), 0.0);
      expect(ratingFor(null), isNull);
    });
  });

  group('fill gaps', () {
    test('preserves populated columns, French, publisher, cover', () async {
      await link();
      await scrapedRow();

      final outcome = await fetch(RommMetadataMode.fillGaps);

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      final r = (await row())!;
      expect(r['real_name'], 'Chrono Trigger (SS)');
      expect(r['description_en'], 'SS English');
      expect(r['description_fr'], 'SS French');
      expect(r['publisher'], 'Square Soft');
      // The empty ones are filled.
      expect(r['genre'], 'RPG, Adventure');
      expect(r['developer'], 'Square');
      expect(r['players'], '1');
      expect(r['release_date'], '1995-03-11');
      expect(r['rating'], 17.0);
      expect(
        outcome.columnsWritten,
        5,
        reason: 'genre, developer, players, release_date, rating',
      );
      // Scrape state and provenance of an existing row are untouched.
      expect(r['metadata_source'], 'screenscraper');
      expect(r['is_fully_scraped'], 0);
      // The cover on disk is kept and was never even requested.
      expect(await mediaFile('box2d', 'png').readAsString(), 'OLD');
      expect(svc.fetched, isNot(contains(_coverUrl)));
      expect(outcome.mediaSkipped, 1);
      // Missing media is written.
      expect(await mediaFile('fanarts', 'png').exists(), isTrue);
      expect(await mediaFile('wheels', 'png').exists(), isTrue);
      expect(await mediaFile('screenshots', 'png').exists(), isTrue);
      expect(await mediaFile('videos', 'mp4').exists(), isTrue);
      expect(outcome.mediaWritten, 4);
      expect(outcome.mediaFailed, 0);
      expect(svc.detailCalls, 1, reason: 'the detail is read once');
    });

    test('a cover under another extension is an existing cover', () async {
      await link();
      final jpg = mediaFile('box2d', 'jpg');
      await jpg.create(recursive: true);
      await jpg.writeAsString('OLD');

      final outcome = await fetch(RommMetadataMode.fillGaps);

      expect(outcome.mediaSkipped, 1);
      expect(await jpg.readAsString(), 'OLD');
      expect(await mediaFile('box2d', 'png').exists(), isFalse);
    });

    test('inserts a fully scraped row with source romm', () async {
      await link();

      final outcome = await fetch(RommMetadataMode.fillGaps);

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      final r = (await row())!;
      expect(r['metadata_source'], 'romm');
      expect(r['is_fully_scraped'], 1);
      expect(r['description_en'], 'A time-travel RPG.');
      expect(r['publisher'], isNull);
      expect(outcome.columnsWritten, 7);
    });

    test('an already complete row is left exactly as it was', () async {
      await link();
      await ScraperRepository.saveGameMetadata(
        {
          'filename': 'ct.sfc',
          'real_name': 'Mine',
          'description_en': 'Mine',
          'genre': 'Mine',
          'developer': 'Mine',
          'players': '2',
          'release_date': '2000-01-01',
          'rating': 3.0,
        },
        'snes',
        source: MetadataSource.manual,
        isFullyScraped: true,
      );
      final before = (await row())!;

      final outcome = await fetch(RommMetadataMode.fillGaps);

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      expect(outcome.columnsWritten, 0);
      final after = (await row())!;
      for (final col in [
        'real_name',
        'description_en',
        'genre',
        'developer',
        'players',
        'release_date',
        'rating',
        'metadata_source',
        'is_fully_scraped',
        'updated_at',
      ]) {
        expect(after[col], before[col], reason: col);
      }
    });
  });

  group('replace', () {
    test('overwrites every mapped column and file, clears French', () async {
      await link();
      await scrapedRow();

      final outcome = await fetch(RommMetadataMode.replace);

      expect(outcome.kind, RommMetadataOutcomeKind.replaced);
      final r = (await row())!;
      expect(r['real_name'], 'Chrono Trigger');
      expect(r['description_en'], 'A time-travel RPG.');
      expect(r['description_fr'], isNull);
      expect(r['publisher'], isNull, reason: 'RomM has no publisher');
      expect(r['genre'], 'RPG, Adventure');
      expect(r['developer'], 'Square');
      expect(r['players'], '1');
      expect(r['release_date'], '1995-03-11');
      expect(r['rating'], 17.0);
      expect(r['metadata_source'], 'romm');
      expect(r['is_fully_scraped'], 1);
      expect(outcome.columnsWritten, 7);
      // The cover was replaced, not kept.
      expect(await mediaFile('box2d', 'png').readAsBytes(), _png);
      expect(svc.fetched, contains(_coverUrl));
      expect(outcome.mediaWritten, 5);
      expect(outcome.mediaSkipped, 0);
    });
  });

  group('outcomes', () {
    test('no detail: nothing written, reported as not found', () async {
      await link();
      svc.detail = null;

      final outcome = await fetch(RommMetadataMode.replace);

      expect(outcome.kind, RommMetadataOutcomeKind.notFound);
      expect(await row(), isNull);
      expect(svc.fetched, isEmpty);
      expect(await Directory(p.join(root.path, 'snes')).exists(), isFalse);
    });

    test('not linked: failed with the sentinel, no request made', () async {
      final outcome = await fetch(RommMetadataMode.fillGaps);

      expect(outcome.kind, RommMetadataOutcomeKind.failed);
      final error = outcome.error;
      expect(error, isA<RommMetadataFetchException>());
      expect((error as RommMetadataFetchException).isNotLinked, isTrue);
      expect(svc.detailCalls, 0);
    });

    test('a detail request that throws is wrapped, never thrown', () async {
      await link();
      svc.detailThrows = true;

      final outcome = await fetch(RommMetadataMode.replace);

      expect(outcome.kind, RommMetadataOutcomeKind.failed);
      final error = outcome.error as RommMetadataFetchException;
      expect(error.stage, 'detail');
      expect(error.romId, 42);
      expect(error.cause, isA<SocketException>());
      expect(error.toString(), contains('rom=42'));
      expect(await row(), isNull);
    });

    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
    test('cover download fails after the columns: partial, logged', () async {
      await link();
      svc.failing.add(_coverUrl);

      final outcome = await fetch(RommMetadataMode.replace);

      expect(outcome.kind, RommMetadataOutcomeKind.partial);
      expect(outcome.columnsWritten, 7);
      expect((await row())?['description_en'], 'A time-travel RPG.');
      expect(outcome.mediaFailed, 1);
      expect(
        outcome.mediaWritten,
        4,
        reason: 'the other types are independent of the cover',
      );
      expect(await mediaFile('box2d', 'png').exists(), isFalse);
      expect(await mediaFile('fanarts', 'png').exists(), isTrue);
      final error = outcome.error as RommMetadataFetchException;
      expect(error.stage, 'media');
      expect(error.cause, isA<SocketException>());
      final logged = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('e|RomM media import failed'))
          .toList();
      expect(logged, hasLength(1));
      expect(logged.single, contains('url=$_coverUrl'));
      expect(logged.single, contains('type=box2d'));
    });
  });

  group('row key', () {
    test('is the map row\'s stored filename, not the display name', () async {
      await link(romname: 'Chrono Trigger (USA).sfc');

      final outcome = await provider.fetchMetadata(
        game: _game(
          'Chrono Trigger (USA)',
          romPath: '/roms/snes/Chrono Trigger (USA).sfc',
        ),
        system: _snes,
        mode: RommMetadataMode.fillGaps,
        fileProvider: media,
      );

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      expect(await row('Chrono Trigger (USA).sfc'), isNotNull);
      expect(await row('Chrono Trigger (USA)'), isNull);
      expect(
        await File(
          media.getMediaPath(
            'snes',
            'box2d',
            'Chrono Trigger (USA).sfc',
            'png',
          ),
        ).exists(),
        isTrue,
      );
    });

    test('download completion is the same writer in replace mode', () async {
      await scrapedRow();

      final outcome = await provider.fetchMetadataForRomId(
        romId: 42,
        system: _snes,
        fileProvider: media,
        indexedName: 'ct.sfc',
        mode: RommMetadataMode.replace,
      );

      expect(outcome.kind, RommMetadataOutcomeKind.replaced);
      final r = (await row())!;
      expect(r['metadata_source'], 'romm');
      expect(r['is_fully_scraped'], 1);
      expect(r['description_fr'], isNull);
    });
  });
}
