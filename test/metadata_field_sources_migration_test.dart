import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/metadata_field_sources.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v168 — `user_screenscraper_metadata.field_sources` — against the
/// "old device" schema v167 left behind: guarded, idempotent, not backfilled,
/// and a no-op on a database that has no metadata table at all.
///
/// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source Provenance",
/// REQ "Database Operation Standards"
void main() {
  late Database db;

  /// `user_screenscraper_metadata` as v167 left it: row-level
  /// `metadata_source`, no per-field provenance.
  const v167Table = '''
    CREATE TABLE user_screenscraper_metadata (
      app_system_id TEXT NOT NULL,
      filename TEXT NOT NULL,
      id_ra INTEGER,
      real_name TEXT,
      description_en TEXT,
      description_es TEXT,
      description_fr TEXT,
      description_de TEXT,
      description_it TEXT,
      description_pt TEXT,
      rating REAL,
      release_date TEXT,
      developer TEXT,
      publisher TEXT,
      genre TEXT,
      players TEXT,
      is_fully_scraped INTEGER DEFAULT 0,
      esde_media_subdir TEXT,
      esde_imported INTEGER DEFAULT 0,
      metadata_source TEXT,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(app_system_id, filename)
    )
  ''';

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.close());

  Future<void> runV168() => SqliteMigrations.migrateToVersion(db, 168);

  List<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table)')
      .map((c) => c['name'].toString())
      .toList();

  bool tableExists(String name) => db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    [name],
  ).isNotEmpty;

  Map<String, Object?> rowOf(String filename) => db.select(
    'SELECT * FROM user_screenscraper_metadata WHERE filename = ?',
    [filename],
  ).first;

  void seed() {
    db.execute(v167Table);
    db.execute(
      "INSERT INTO user_screenscraper_metadata "
      "(app_system_id, filename, genre, is_fully_scraped, metadata_source) "
      "VALUES ('snes', 'ct.sfc', 'RPG', 1, 'romm')",
    );
    db.execute(
      "INSERT INTO user_screenscraper_metadata "
      "(app_system_id, filename, genre, is_fully_scraped, metadata_source) "
      "VALUES ('snes', 'sm.sfc', 'Platform', 1, 'screenscraper')",
    );
  }

  group('migration v168', () {
    // Scenario: an existing database gains the column.
    test('adds field_sources to an old-device schema', () async {
      seed();
      expect(
        columnsOf('user_screenscraper_metadata'),
        isNot(contains('field_sources')),
      );

      await runV168();

      expect(
        columnsOf('user_screenscraper_metadata'),
        contains('field_sources'),
      );
    });

    test('the column constant names what the migration adds', () async {
      seed();
      await runV168();
      expect(
        columnsOf('user_screenscraper_metadata'),
        contains(MetadataFieldSources.column),
      );
    });

    // Scenario: existing rows are not backfilled — a row RomM wrote may since
    // have had its gaps filled by ScreenScraper, and nothing in the row says
    // which columns went which way, so "nothing known" is the honest record.
    test('existing rows read as nothing known, and keep their data', () async {
      seed();

      await runV168();

      final romm = rowOf('ct.sfc');
      expect(romm['field_sources'], isNull);
      expect(romm['metadata_source'], 'romm');
      expect(romm['genre'], 'RPG');
      expect(rowOf('sm.sfc')['field_sources'], isNull);
      expect(
        MetadataFieldSources.fromDb(romm['field_sources']).isEmpty,
        isTrue,
      );
    });

    // Scenario: migration idempotent.
    test('running twice leaves the column exactly once', () async {
      seed();

      await runV168();
      db.execute(
        "UPDATE user_screenscraper_metadata SET field_sources = "
        "'{\"genre\":\"romm\"}' WHERE filename = 'ct.sfc'",
      );
      await runV168();

      expect(
        columnsOf(
          'user_screenscraper_metadata',
        ).where((c) => c == 'field_sources'),
        ['field_sources'],
      );
      expect(rowOf('ct.sfc')['field_sources'], '{"genre":"romm"}');
    });

    // Scenario: a database a branch already carried past v168. The guard is
    // what makes the version number a floor rather than a promise the body
    // ran, so re-adding must not throw.
    test('a database that already has the column is left alone', () async {
      seed();
      db.execute(
        'ALTER TABLE user_screenscraper_metadata ADD COLUMN field_sources TEXT',
      );

      await runV168();

      expect(
        columnsOf(
          'user_screenscraper_metadata',
        ).where((c) => c == 'field_sources'),
        ['field_sources'],
      );
    });

    // Scenario: no metadata table at all. `PRAGMA table_info` on a missing
    // table returns no rows, and an ALTER would throw; the empty guard is what
    // keeps that from failing the whole migration run.
    test('a database without the table is a no-op, not a failure', () async {
      expect(tableExists('user_screenscraper_metadata'), isFalse);

      await expectLater(runV168(), completes);

      expect(tableExists('user_screenscraper_metadata'), isFalse);
    });
  });
}
