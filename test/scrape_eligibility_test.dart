import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/scraper_repository.dart';

import 'database_test_helper.dart';

/// Which games a `new_only` ScreenScraper pass is offered.
///
/// `is_fully_scraped` is one flag for the whole row and any source sets it, so
/// a RomM fetch that filled three of fourteen columns marked the game done and
/// ScreenScraper never looked at it again. In a RomM-first library that is the
/// common path, not an edge: games sat with no genre, no players count and no
/// summary, and a full re-scrape of the system was the only way out.
///
/// The predicate now also offers rows ScreenScraper has never completed, which
/// `metadata_source` answers because only a whole-row writer sets it. Issue
/// #233.
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
    final db = await SqliteService.getDatabase();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
  });
  tearDown(() async => dbHelper.tearDown());

  Future<void> addRom(String filename) async {
    final db = await SqliteService.getDatabase();
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) "
      "VALUES ('$filename', '/roms/snes/$filename', 'snes')",
    );
  }

  Future<void> addMetadata(
    String filename, {
    required String? source,
    required int fullyScraped,
  }) async {
    final db = await SqliteService.getDatabase();
    await db.execute(
      "INSERT INTO user_screenscraper_metadata "
      "(app_system_id, filename, genre, is_fully_scraped, metadata_source) "
      "VALUES ('snes', '$filename', 'Action', $fullyScraped, "
      "${source == null ? 'NULL' : "'$source'"})",
    );
  }

  Future<Set<String>> eligible() async {
    final rows = await ScraperRepository.getRomsForScraping('snes', 'new_only');
    return rows.map((r) => r['filename'].toString()).toSet();
  }

  test('a RomM-filled game is offered to ScreenScraper', () async {
    await addRom('zelda.sfc');
    await addMetadata('zelda.sfc', source: 'romm', fullyScraped: 1);

    expect(
      await eligible(),
      contains('zelda.sfc'),
      reason: 'RomM marked it done; ScreenScraper never had a pass at it',
    );
  });

  test('a ScreenScraper-completed game is not offered again', () async {
    await addRom('metroid.sfc');
    await addMetadata('metroid.sfc', source: 'screenscraper', fullyScraped: 1);

    expect(
      await eligible(),
      isNot(contains('metroid.sfc')),
      reason:
          'the predicate has to terminate, or every pass redoes the library',
    );
  });

  test('an unfinished ScreenScraper row is still offered', () async {
    await addRom('mario.sfc');
    await addMetadata('mario.sfc', source: 'screenscraper', fullyScraped: 0);

    expect(await eligible(), contains('mario.sfc'));
  });

  test('a game with no metadata row at all is offered', () async {
    await addRom('kirby.sfc');

    expect(await eligible(), contains('kirby.sfc'));
  });

  test('a legacy row with no recorded source is left alone', () async {
    // Rows written before `metadata_source` existed all read null. Offering
    // them looked like the safe direction and is not: every one of them would
    // come back on the first `new_only` pass after an upgrade, turning it into
    // a full re-scrape of the library against a daily request quota. A legacy
    // row keeping a gap is the cheaper mistake, and `all` mode is the way out
    // of it.
    await addRom('dkc.sfc');
    await addMetadata('dkc.sfc', source: null, fullyScraped: 1);

    expect(await eligible(), isNot(contains('dkc.sfc')));
  });

  test('the count and the list agree', () async {
    await addRom('zelda.sfc');
    await addMetadata('zelda.sfc', source: 'romm', fullyScraped: 1);
    await addRom('metroid.sfc');
    await addMetadata('metroid.sfc', source: 'screenscraper', fullyScraped: 1);

    // Two queries, one predicate — they are built from the same filter and a
    // progress bar that disagrees with the work is its own bug.
    expect(
      await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
      (await eligible()).length,
    );
  });
}
