import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v159, which adds
/// `user_screenscraper_metadata.metadata_source` — the column that records
/// which writer (ScreenScraper, RomM, ES-DE, Steam, or the manual editor)
/// produced a metadata row.
///
/// Rows written before the column existed carry nothing that says who wrote
/// them, so the migration leaves them null rather than guessing.
///
/// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source
/// Provenance"
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_screenscraper_metadata as v100 left it,
    // without the provenance column.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_screenscraper_metadata (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        real_name TEXT,
        description_en TEXT,
        genre TEXT,
        is_fully_scraped INTEGER DEFAULT 0,
        esde_media_subdir TEXT,
        esde_imported INTEGER DEFAULT 0,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(app_system_id, filename)
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV159() => SqliteMigrations.migrateToVersion(db, 159);

  List<String> metaColumns() => db
      .select('PRAGMA table_info(user_screenscraper_metadata)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v159', () {
    test('adds metadata_source when the column is missing', () async {
      expect(metaColumns(), isNot(contains('metadata_source')));

      await runV159();

      expect(metaColumns(), contains('metadata_source'));
    });

    test('leaves existing rows intact with a null source', () async {
      db.execute(
        "INSERT INTO user_screenscraper_metadata "
        "(app_system_id, filename, real_name, is_fully_scraped, esde_imported) "
        "VALUES "
        "('snes', 'Game.sfc', 'Game', 1, 0), "
        "('megadrive', 'Other.bin', 'Other', 0, 1)",
      );

      await runV159();

      final rows = db.select(
        'SELECT app_system_id, filename, real_name, is_fully_scraped, '
        'esde_imported, metadata_source '
        'FROM user_screenscraper_metadata ORDER BY filename',
      );
      expect(rows.length, 2);
      expect(
        rows
            .map(
              (r) => [
                r['app_system_id'],
                r['filename'],
                r['real_name'],
                r['is_fully_scraped'],
                r['esde_imported'],
              ],
            )
            .toList(),
        [
          ['snes', 'Game.sfc', 'Game', 1, 0],
          ['megadrive', 'Other.bin', 'Other', 0, 1],
        ],
        reason: 'the metadata itself must survive the upgrade untouched',
      );
      expect(rows.map((r) => r['metadata_source']).toList(), [
        null,
        null,
      ], reason: 'no row gains a provenance it cannot be known to have');
    });

    test(
      'a row inserted after the migration defaults to a null source',
      () async {
        await runV159();
        db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename) "
          "VALUES ('snes', 'Game.sfc')",
        );

        final rows = db.select(
          "SELECT metadata_source FROM user_screenscraper_metadata "
          "WHERE filename = 'Game.sfc'",
        );
        expect(rows.first['metadata_source'], isNull);
      },
    );

    test('stores each of the sources', () async {
      await runV159();
      db.execute(
        "INSERT INTO user_screenscraper_metadata "
        "(app_system_id, filename, metadata_source) VALUES "
        "('snes', 'A.sfc', 'screenscraper'), "
        "('snes', 'B.sfc', 'romm'), "
        "('snes', 'C.sfc', 'esde'), "
        "('snes', 'D.sfc', 'steam'), "
        "('snes', 'E.sfc', 'manual')",
      );

      final rows = db.select(
        'SELECT metadata_source FROM user_screenscraper_metadata '
        'ORDER BY filename',
      );
      expect(rows.map((r) => r['metadata_source']).toList(), [
        'screenscraper',
        'romm',
        'esde',
        'steam',
        'manual',
      ]);
    });

    test('is a no-op when the column already exists', () async {
      db.execute(
        'ALTER TABLE user_screenscraper_metadata ADD COLUMN metadata_source TEXT',
      );
      db.execute(
        "INSERT INTO user_screenscraper_metadata "
        "(app_system_id, filename, metadata_source) "
        "VALUES ('snes', 'Game.sfc', 'romm')",
      );

      await runV159();

      // A device that already has the column keeps the recorded source.
      final rows = db.select(
        "SELECT metadata_source FROM user_screenscraper_metadata "
        "WHERE filename = 'Game.sfc'",
      );
      expect(rows.first['metadata_source'], 'romm');
      expect(
        metaColumns().where((c) => c == 'metadata_source').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename) "
        "VALUES ('snes', 'Game.sfc')",
      );

      await runV159();
      final after = db.select('SELECT * FROM user_screenscraper_metadata');
      await runV159();

      expect(metaColumns(), contains('metadata_source'));
      expect(metaColumns().where((c) => c == 'metadata_source').length, 1);
      expect(
        db.select('SELECT * FROM user_screenscraper_metadata'),
        after,
        reason: 'the second run must change nothing',
      );
    });
  });
}
