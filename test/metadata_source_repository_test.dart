import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/scraper_repository.dart';

import 'database_test_helper.dart';

/// Provenance and fill-gaps behaviour of the metadata writers in
/// [ScraperRepository], plus the scrape-candidate join that ScreenScraper's
/// `new_only` mode depends on.
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
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) "
      "VALUES ('nes', 'NES', 'nes', 3)",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<Map<String, dynamic>> row(String system, String filename) async {
    final rows = await db.rawQuery(
      'SELECT * FROM user_screenscraper_metadata '
      'WHERE app_system_id = ? AND filename = ?',
      [system, filename],
    );
    expect(rows.length, 1, reason: 'expected one row for $system/$filename');
    return rows.first;
  }

  group('MetadataSource', () {
    test('round-trips every value through its db string', () {
      for (final source in MetadataSource.values) {
        expect(MetadataSource.fromDb(source.dbValue), source);
      }
    });

    test('db strings are the values the spec names', () {
      expect(MetadataSource.screenscraper.dbValue, 'screenscraper');
      expect(MetadataSource.romm.dbValue, 'romm');
      expect(MetadataSource.esde.dbValue, 'esde');
      expect(MetadataSource.steam.dbValue, 'steam');
      expect(MetadataSource.manual.dbValue, 'manual');
    });

    test('null and unknown values decode to null, not a guess', () {
      expect(MetadataSource.fromDb(null), isNull);
      expect(MetadataSource.fromDb(''), isNull);
      expect(MetadataSource.fromDb('launchbox'), isNull);
    });
  });

  group('saveGameMetadata', () {
    test('records the source on insert', () async {
      final saved = await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'real_name': 'Game'},
        'snes',
        source: MetadataSource.screenscraper,
      );
      expect(saved, isTrue);

      final r = await row('snes', 'game.smc');
      expect(r['metadata_source'], 'screenscraper');
    });

    test('a later replace by another source takes over the row', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'real_name': 'Game', 'publisher': 'Pub'},
        'snes',
        source: MetadataSource.screenscraper,
      );

      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'real_name': 'Game (RomM)'},
        'snes',
        source: MetadataSource.romm,
        isFullyScraped: true,
      );

      final r = await row('snes', 'game.smc');
      expect(r['metadata_source'], 'romm');
      expect(r['real_name'], 'Game (RomM)');
      expect(r['is_fully_scraped'], 1);
      expect(
        r['publisher'],
        isNull,
        reason: 'saveGameMetadata is a whole-row replace',
      );
    });

    test('a caller-supplied metadata_source is overridden', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'metadata_source': 'manual'},
        'snes',
        source: MetadataSource.esde,
      );

      final r = await row('snes', 'game.smc');
      expect(r['metadata_source'], 'esde');
    });
  });

  group('upsertSteamMetadata', () {
    test('records the steam source on every write', () async {
      await ScraperRepository.upsertSteamMetadata({
        'app_system_id': 'snes',
        'filename': 'game.steam',
        'real_name': 'Steam Game',
      });
      expect((await row('snes', 'game.steam'))['metadata_source'], 'steam');

      await ScraperRepository.upsertSteamMetadata({
        'app_system_id': 'snes',
        'filename': 'game.steam',
        'real_name': 'Steam Game 2',
        'metadata_source': 'manual',
      });
      final r = await row('snes', 'game.steam');
      expect(r['metadata_source'], 'steam');
      expect(r['real_name'], 'Steam Game 2');
    });
  });

  group('updateGameMetadata', () {
    test('marks a hand edit of an existing row as manual', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'real_name': 'Game', 'genre': 'RPG'},
        'snes',
        source: MetadataSource.screenscraper,
        isFullyScraped: true,
      );

      final ok = await ScraperRepository.updateGameMetadata(
        'snes',
        'game.smc',
        {'real_name': 'Game (edited)'},
      );
      expect(ok, isTrue);

      final r = await row('snes', 'game.smc');
      expect(r['metadata_source'], 'manual');
      expect(r['real_name'], 'Game (edited)');
      expect(r['genre'], 'RPG', reason: 'untouched columns are kept');
      expect(r['is_fully_scraped'], 1, reason: 'scrape state is not touched');
    });

    test('a minimal row created by the editor is manual', () async {
      final ok = await ScraperRepository.updateGameMetadata('snes', 'new.smc', {
        'developer': 'Someone',
      });
      expect(ok, isTrue);

      final r = await row('snes', 'new.smc');
      expect(r['metadata_source'], 'manual');
      expect(r['is_fully_scraped'], 0);
      expect(r['developer'], 'Someone');
    });

    test('a call that touches no metadata column leaves the source', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'real_name': 'Game'},
        'snes',
        source: MetadataSource.romm,
      );

      // Only reserved keys: nothing user-visible changes, so provenance stays.
      final ok = await ScraperRepository.updateGameMetadata(
        'snes',
        'game.smc',
        {'metadata_source': 'manual', 'is_fully_scraped': 1},
      );
      expect(ok, isTrue);

      final r = await row('snes', 'game.smc');
      expect(r['metadata_source'], 'romm');
      expect(r['is_fully_scraped'], 0);
    });
  });

  group('buildFillGapsMetadataWrite', () {
    test('an insert carries the key, scrape state, and source', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: null,
        incoming: {'real_name': 'Game', 'genre': 'RPG'},
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );

      expect(write, isNotNull);
      expect(write!['app_system_id'], 'snes');
      expect(write['filename'], 'game.smc');
      expect(write['is_fully_scraped'], 1);
      expect(write['metadata_source'], 'romm');
      expect(write['real_name'], 'Game');
      expect(write['genre'], 'RPG');
      expect(write['updated_at'], isNotNull);
    });

    test('an insert defaults to not fully scraped', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: null,
        incoming: {'real_name': 'Game'},
        source: MetadataSource.esde,
      );
      expect(write!['is_fully_scraped'], 0);
      expect(write['metadata_source'], 'esde');
    });

    test('an existing row keeps its source and scrape state; only empty '
        'columns are filled', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {
          'app_system_id': 'snes',
          'filename': 'game.smc',
          'real_name': 'Scraped Name',
          'description_en': 'Scraped description',
          'genre': null,
          'developer': '   ',
          'is_fully_scraped': 1,
          'metadata_source': 'screenscraper',
        },
        incoming: {
          'real_name': 'RomM Name',
          'description_en': 'RomM description',
          'genre': 'RPG',
          'developer': 'Dev',
          'players': '2',
        },
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );

      expect(write, isNotNull);
      expect(
        write!.keys.toSet(),
        {'genre', 'developer', 'players', 'updated_at'},
        reason:
            'populated columns are untouched, blank counts as empty, and '
            'the key / scrape state / source are not rewritten',
      );
      expect(write['genre'], 'RPG');
      expect(write['developer'], 'Dev');
      expect(write['players'], '2');
    });

    test('null and blank candidates are ignored', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {'genre': null, 'developer': null},
        incoming: {'genre': null, 'developer': '  '},
        source: MetadataSource.romm,
      );
      expect(write, isNull, reason: 'nothing to write');
    });

    test('nothing to fill on a complete row returns null', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {'genre': 'RPG', 'metadata_source': 'screenscraper'},
        incoming: {'genre': 'Action'},
        source: MetadataSource.romm,
      );
      expect(write, isNull);
    });

    test('reserved columns in the candidate map are never taken', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {'genre': null, 'metadata_source': null, 'is_fully_scraped': 0},
        incoming: {
          'genre': 'RPG',
          'metadata_source': 'manual',
          'is_fully_scraped': 1,
          'filename': 'other.smc',
        },
        source: MetadataSource.romm,
      );
      expect(write!.keys.toSet(), {'genre', 'updated_at'});
    });

    test('alwaysWrite columns go in even when nothing else does', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {'genre': 'RPG', 'esde_media_subdir': 'old'},
        incoming: {'genre': 'Action'},
        source: MetadataSource.esde,
        alwaysWrite: {'esde_media_subdir': 'new'},
      );
      expect(write!.keys.toSet(), {'esde_media_subdir', 'updated_at'});
      expect(write['esde_media_subdir'], 'new');
    });
  });

  group('buildEsdeMetadataWrite', () {
    test('an insert is an esde-sourced, esde_imported row', () {
      final write = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: null,
        esde: {'real_name': 'Game'},
        mediaSubdir: 'sub',
      );
      expect(write!['metadata_source'], 'esde');
      expect(write['esde_imported'], 1);
      expect(write['is_fully_scraped'], 0);
      expect(write['esde_media_subdir'], 'sub');
    });

    test('a gap-fill into an existing row marks neither provenance', () {
      final write = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {
          'real_name': 'Scraped',
          'genre': null,
          'metadata_source': 'screenscraper',
          'esde_media_subdir': 'sub',
        },
        esde: {'real_name': 'ES-DE', 'genre': 'RPG'},
        mediaSubdir: 'sub',
      );
      expect(write!.keys.toSet(), {'genre', 'updated_at'});
    });

    test('a changed media subdir alone is still a write', () {
      final write = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: 'snes',
        filename: 'game.smc',
        row: {'real_name': 'Scraped', 'esde_media_subdir': 'old'},
        esde: {'real_name': 'ES-DE'},
        mediaSubdir: 'new',
      );
      expect(write!.keys.toSet(), {'esde_media_subdir', 'updated_at'});
    });
  });

  group('mergeFillGapsMetadata', () {
    test(
      'fills an empty genre on a ScreenScraper row and keeps the source',
      () async {
        await ScraperRepository.saveGameMetadata(
          {
            'filename': 'game.smc',
            'real_name': 'Game',
            'description_fr': 'Description FR',
            'publisher': 'Pub',
          },
          'snes',
          source: MetadataSource.screenscraper,
          isFullyScraped: true,
        );

        final merged = await ScraperRepository.mergeFillGapsMetadata(
          'snes',
          'game.smc',
          {
            'real_name': 'RomM Name',
            'genre': 'RPG',
            'description_fr': null,
            'publisher': null,
          },
          source: MetadataSource.romm,
          insertFullyScraped: true,
        );
        expect(merged, isTrue);

        final r = await row('snes', 'game.smc');
        expect(r['genre'], 'RPG');
        expect(r['real_name'], 'Game');
        expect(r['description_fr'], 'Description FR');
        expect(r['publisher'], 'Pub');
        expect(r['metadata_source'], 'screenscraper');
        expect(r['is_fully_scraped'], 1);
      },
    );

    test('inserts a fully scraped row with the given source', () async {
      final merged = await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'new.smc',
        {'real_name': 'New Game'},
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );
      expect(merged, isTrue);

      final r = await row('snes', 'new.smc');
      expect(r['metadata_source'], 'romm');
      expect(r['is_fully_scraped'], 1);
      expect(r['real_name'], 'New Game');
    });

    test('returns false when there is nothing to fill', () async {
      await ScraperRepository.saveGameMetadata(
        {'filename': 'game.smc', 'genre': 'RPG'},
        'snes',
        source: MetadataSource.screenscraper,
      );

      final merged = await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'game.smc',
        {'genre': 'Action'},
        source: MetadataSource.romm,
      );
      expect(merged, isFalse);
      expect((await row('snes', 'game.smc'))['genre'], 'RPG');
    });
  });

  group('scrape candidates', () {
    Future<void> rom(String system, String filename) => db.execute(
      'INSERT INTO user_roms (filename, rom_path, app_system_id) '
      'VALUES (?, ?, ?)',
      [filename, '/roms/$system/$filename', system],
    );

    test('the same filename under two systems is judged per system', () async {
      await rom('snes', 'Game.zip');
      await rom('nes', 'Game.zip');
      await db.execute(
        "INSERT INTO user_screenscraper_metadata "
        "(app_system_id, filename, is_fully_scraped) "
        "VALUES ('snes', 'Game.zip', 1)",
      );

      final nesRoms = await ScraperRepository.getRomsForScraping(
        'nes',
        'new_only',
      );
      expect(nesRoms.map((r) => r['filename']).toList(), [
        'Game.zip',
      ], reason: 'a metadata row under snes must not hide the nes ROM');
      expect(
        await ScraperRepository.getRomCountForScraping('nes', 'new_only'),
        1,
      );

      expect(
        await ScraperRepository.getRomsForScraping('snes', 'new_only'),
        isEmpty,
      );
      expect(
        await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
        0,
      );
    });

    test('the row and count queries agree in every mode', () async {
      await rom('snes', 'a.smc');
      await rom('snes', 'b.smc');
      await rom('snes', 'c.smc');
      await db.execute(
        "INSERT INTO user_screenscraper_metadata "
        "(app_system_id, filename, is_fully_scraped) VALUES "
        "('snes', 'a.smc', 1), ('snes', 'b.smc', 0)",
      );

      for (final mode in ['new_only', 'all']) {
        final roms = await ScraperRepository.getRomsForScraping('snes', mode);
        final count = await ScraperRepository.getRomCountForScraping(
          'snes',
          mode,
        );
        expect(count, roms.length, reason: 'mode $mode');
      }
      expect(
        (await ScraperRepository.getRomsForScraping(
          'snes',
          'new_only',
        )).map((r) => r['filename']).toSet(),
        {'b.smc', 'c.smc'},
      );
    });

    test('a row a RomM fill-gaps insert marked fully scraped is skipped in '
        'new_only', () async {
      await rom('snes', 'linked.smc');
      await rom('snes', 'fresh.smc');
      await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'linked.smc',
        {'real_name': 'Linked Game'},
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );

      final roms = await ScraperRepository.getRomsForScraping(
        'snes',
        'new_only',
      );
      expect(roms.map((r) => r['filename']).toList(), ['fresh.smc']);
      expect(
        await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
        1,
      );
    });

    test('a fill-gaps write into an existing partial row does not change '
        'new_only eligibility', () async {
      await rom('snes', 'partial.smc');
      await ScraperRepository.saveGameMetadata(
        {'filename': 'partial.smc', 'real_name': 'Partial'},
        'snes',
        source: MetadataSource.screenscraper,
        isFullyScraped: false,
      );

      await ScraperRepository.mergeFillGapsMetadata(
        'snes',
        'partial.smc',
        {'genre': 'RPG'},
        source: MetadataSource.romm,
        insertFullyScraped: true,
      );

      final roms = await ScraperRepository.getRomsForScraping(
        'snes',
        'new_only',
      );
      expect(roms.map((r) => r['filename']).toList(), [
        'partial.smc',
      ], reason: 'still a partial scrape, still eligible');
      expect((await row('snes', 'partial.smc'))['is_fully_scraped'], 0);
    });
  });
}
