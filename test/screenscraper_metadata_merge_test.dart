import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/metadata_field_sources.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/screenscraper_service.dart';

import 'database_test_helper.dart';

/// What a ScreenScraper pass does to a row another source already wrote.
///
/// Before #248 `saveGameMetadata` was an unconditional `INSERT OR REPLACE`
/// against `UNIQUE(app_system_id, filename)`, so SQLite deleted the row and
/// reinserted only the 14 columns ScreenScraper's mapper supplies — resetting
/// RomM's seven columns, the ES-DE importer's media location, and the
/// `field_sources` provenance. The write now takes an explicit
/// [MetadataWriteMode]: [MetadataWriteMode.merge] for a routine pass,
/// [MetadataWriteMode.replace] for a forced `all`-mode re-scrape.
///
/// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source
/// Provenance", REQ "Cooperation With ScreenScraper"
void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('snes', 'SNES', 'snes', 4)",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<Map<String, dynamic>> row(String filename) async {
    final rows = await db.rawQuery(
      'SELECT * FROM user_screenscraper_metadata '
      'WHERE app_system_id = ? AND filename = ?',
      ['snes', filename],
    );
    expect(rows.length, 1, reason: 'expected one row for snes/$filename');
    return rows.first;
  }

  /// The row a RomM fetch leaves behind: SPEC-0005's seven columns, written
  /// the way RomM's replace mode writes them.
  Future<void> rommRow(String filename) async {
    await ScraperRepository.saveGameMetadata(
      {
        'filename': filename,
        'real_name': 'Chrono Trigger',
        'description_en': 'RomM English',
        'genre': 'RPG',
        'developer': 'Squaresoft',
        'players': '1',
        'release_date': '1995-03-11',
        'rating': 0.95,
      },
      'snes',
      source: MetadataSource.romm,
      mode: MetadataWriteMode.replace,
      isFullyScraped: true,
    );
  }

  /// What ScreenScraper's mapper produces for a game the API knows only
  /// thinly: a name and an English synopsis, nothing else.
  Map<String, dynamic> thinScreenscraperMap(String filename) => {
    'filename': filename,
    'real_name': 'Chrono Trigger (USA)',
    'description_en': 'ScreenScraper English',
  };

  group('merge mode', () {
    test('keeps the columns ScreenScraper has no value for', () async {
      await rommRow('ct.sfc');

      final saved = await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );
      expect(saved, isTrue);

      final r = await row('ct.sfc');
      // RomM's, untouched.
      expect(r['genre'], 'RPG');
      expect(r['developer'], 'Squaresoft');
      expect(r['players'], '1');
      expect(r['release_date'], '1995-03-11');
      expect(r['rating'], 0.95);
      // ScreenScraper's, where it had something.
      expect(r['real_name'], 'Chrono Trigger (USA)');
      expect(r['description_en'], 'ScreenScraper English');
    });

    test('an explicit null counts as "no value", not as "clear it"', () async {
      await rommRow('ct.sfc');

      await ScraperRepository.saveGameMetadata(
        {
          ...thinScreenscraperMap('ct.sfc'),
          // The present-but-null shape the mapper used to produce.
          'developer': null,
          'publisher': null,
          'players': null,
          'genre': '   ',
        },
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );

      final r = await row('ct.sfc');
      expect(r['developer'], 'Squaresoft');
      expect(r['players'], '1');
      expect(r['genre'], 'RPG');
    });

    test('keeps the ES-DE importer\'s media location and flag', () async {
      await ScraperRepository.saveGameMetadata(
        {
          'filename': 'ct.sfc',
          'real_name': 'Chrono Trigger',
          'esde_media_subdir': 'rpg/square',
          'esde_imported': 1,
        },
        'snes',
        source: MetadataSource.esde,
        mode: MetadataWriteMode.replace,
      );

      await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );

      final r = await row('ct.sfc');
      expect(r['esde_media_subdir'], 'rpg/square');
      expect(r['esde_imported'], 1);
    });

    test('carries field_sources forward and records its own writes', () async {
      // A fill-gaps RomM write is what populates the column today.
      await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'ct.sfc',
        {
          'real_name': 'Chrono Trigger',
          'genre': 'RPG',
          'developer': 'Squaresoft',
        },
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );

      await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );

      final sources = MetadataFieldSources.fromDb(
        (await row('ct.sfc'))[MetadataFieldSources.column],
      );
      expect(
        sources.sourceOf('genre'),
        'romm',
        reason: 'a column this pass did not touch keeps its writer',
      );
      expect(sources.sourceOf('developer'), 'romm');
      expect(
        sources.sourceOf('real_name'),
        'screenscraper',
        reason: 'a column this pass overwrote moves to this pass',
      );
      expect(sources.sourceOf('description_en'), 'screenscraper');
    });

    test('still records screenscraper, so new_only terminates', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) "
        "VALUES ('ct.sfc', '/roms/snes/ct.sfc', 'snes')",
      );
      await rommRow('ct.sfc');
      expect(
        await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
        1,
        reason: 'a romm-written row is a new_only candidate (#246)',
      );

      await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );

      expect((await row('ct.sfc'))['metadata_source'], 'screenscraper');
      expect(
        await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
        0,
        reason: 'the row must drop out, or it is re-offered every pass',
      );
    });

    test('inserts a complete row when the game has none', () async {
      final saved = await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('new.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.merge,
        isFullyScraped: true,
      );
      expect(saved, isTrue);

      final r = await row('new.sfc');
      expect(r['app_system_id'], 'snes');
      expect(r['real_name'], 'Chrono Trigger (USA)');
      expect(r['metadata_source'], 'screenscraper');
      expect(r['is_fully_scraped'], 1);
    });
  });

  group('replace mode', () {
    test('still clears every column it was not handed', () async {
      await rommRow('ct.sfc');

      await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.replace,
        isFullyScraped: true,
      );

      final r = await row('ct.sfc');
      expect(r['genre'], isNull);
      expect(r['developer'], isNull);
      expect(r['players'], isNull);
      expect(r['release_date'], isNull);
      expect(r['rating'], isNull);
      expect(r['real_name'], 'Chrono Trigger (USA)');
      expect(r['metadata_source'], 'screenscraper');
    });

    test('still clears the ES-DE columns and field_sources', () async {
      await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'ct.sfc',
        {'real_name': 'Chrono Trigger', 'genre': 'RPG'},
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );
      await ScraperRepository.updateGameMetadata('snes', 'ct.sfc', {
        'esde_media_subdir': 'rpg/square',
      });
      expect(
        (await row('ct.sfc'))[MetadataFieldSources.column],
        isNotNull,
        reason: 'precondition: the row has provenance to lose',
      );

      await ScraperRepository.saveGameMetadata(
        thinScreenscraperMap('ct.sfc'),
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.replace,
        isFullyScraped: true,
      );

      final r = await row('ct.sfc');
      expect(r['esde_media_subdir'], isNull);
      expect(r[MetadataFieldSources.column], isNull);
    });
  });

  group('writeModeFor', () {
    test('all mode keeps the whole-row replace', () {
      expect(
        ScreenScraperService.writeModeFor({'scrape_mode': 'all'}),
        MetadataWriteMode.replace,
      );
    });

    test('every other mode is a routine pass that merges', () {
      expect(
        ScreenScraperService.writeModeFor({'scrape_mode': 'new_only'}),
        MetadataWriteMode.merge,
      );
      expect(
        ScreenScraperService.writeModeFor({'scrape_mode': null}),
        MetadataWriteMode.merge,
      );
    });
  });

  group('mapGameInfoToMetadata', () {
    test('omits the columns the API response has no value for', () async {
      final metadata = await ScreenScraperService.mapGameInfoToMetadata(
        'ct.sfc',
        '/roms/snes/ct.sfc',
        {
          'noms': [
            {'region': 'us', 'text': 'Chrono Trigger (USA)'},
          ],
          'synopsis': [
            {'langue': 'en', 'text': 'ScreenScraper English'},
          ],
          // No developpeur / editeur / joueurs / genres / note / dates.
        },
        preferredLanguage: 'en',
      );

      expect(metadata.keys, contains('real_name'));
      expect(metadata.keys, contains('description_en'));
      // Present-but-null is the shape that wrote NULL over RomM's values.
      expect(metadata.containsKey('developer'), isFalse);
      expect(metadata.containsKey('publisher'), isFalse);
      expect(metadata.containsKey('players'), isFalse);
      expect(metadata.containsKey('genre'), isFalse);
    });

    test('omits real_name rather than falling back to the filename', () async {
      final metadata = await ScreenScraperService.mapGameInfoToMetadata(
        'ct.sfc',
        '/roms/snes/ct.sfc',
        {
          'noms': <dynamic>[],
          'synopsis': [
            {'langue': 'en', 'text': 'ScreenScraper English'},
          ],
        },
        preferredLanguage: 'en',
      );

      expect(
        metadata.containsKey('real_name'),
        isFalse,
        reason:
            'the raw filename must not overwrite another source\'s name; '
            'the display queries already COALESCE to it',
      );
    });

    test('keeps the values it does have', () async {
      final metadata = await ScreenScraperService.mapGameInfoToMetadata(
        'ct.sfc',
        '/roms/snes/ct.sfc',
        {
          'noms': [
            {'region': 'us', 'text': 'Chrono Trigger (USA)'},
          ],
          'synopsis': <dynamic>[],
          'developpeur': {'text': 'Squaresoft'},
          'editeur': {'text': 'Square'},
          'joueurs': {'text': '1'},
          'genres': [
            {
              'noms': [
                {'langue': 'en', 'text': 'RPG'},
              ],
            },
          ],
        },
        preferredLanguage: 'en',
      );

      expect(metadata['developer'], 'Squaresoft');
      expect(metadata['publisher'], 'Square');
      expect(metadata['players'], '1');
      expect(metadata['genre'], 'RPG');
    });
  });
}
