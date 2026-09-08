import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migration v167 — `user_collections.romm_origin` with its backfill, and
/// the collection push outbox table — against the "old device" schema v161
/// left behind: guarded, idempotent, and only the mirrored rows get `romm`.
///
/// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Origin Column",
/// REQ "Follow-Up Pushes", REQ "Database Operation Standards"
void main() {
  late Database db;

  /// `user_collections` as v161 left it: provenance, no origin.
  const v161Table = '''
    CREATE TABLE user_collections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      image_path TEXT,
      color1 TEXT,
      color2 TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      romm_server_url TEXT,
      romm_collection_id TEXT,
      romm_collection_virtual INTEGER,
      romm_synced_at TEXT
    )
  ''';

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.close());

  Future<void> runV167() => SqliteMigrations.migrateToVersion(db, 167);

  List<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table)')
      .map((c) => c['name'].toString())
      .toList();

  bool tableExists(String name) => db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    [name],
  ).isNotEmpty;

  Map<String, Object?> originOf(String id) => db.select(
    'SELECT romm_origin FROM user_collections WHERE id = ?',
    [id],
  ).first;

  void seed() {
    db.execute(v161Table);
    db.execute(
      "INSERT INTO user_collections (id, name) VALUES ('plain', 'RPGs')",
    );
    db.execute(
      "INSERT INTO user_collections (id, name, romm_server_url, "
      "romm_collection_id, romm_collection_virtual) "
      "VALUES ('mirror', 'Best of SNES', 'https://romm.local', '12', 0)",
    );
    db.execute(
      "INSERT INTO user_collections (id, name, romm_server_url, "
      "romm_collection_id, romm_collection_virtual) "
      "VALUES ('virtual', 'RPG series', 'https://romm.local', 'genre:rpg', 1)",
    );
  }

  group('migration v167', () {
    // Scenario: legacy mirror rows.
    test('adds romm_origin and backfills romm on mirrored rows', () async {
      seed();
      expect(columnsOf('user_collections'), isNot(contains('romm_origin')));

      await runV167();

      expect(columnsOf('user_collections'), contains('romm_origin'));
      expect(originOf('plain')['romm_origin'], isNull);
      expect(originOf('mirror')['romm_origin'], 'romm');
      expect(originOf('virtual')['romm_origin'], 'romm');
    });

    test('the column constant names what the migration adds', () async {
      seed();
      await runV167();
      expect(
        columnsOf('user_collections'),
        contains(SqliteMigrations.rommCollectionOriginColumn),
      );
      expect(
        SqliteMigrations.createUserCollectionsTableSql,
        contains(SqliteMigrations.rommCollectionOriginColumn),
      );
    });

    // Scenario: migration idempotent.
    test(
      'running twice leaves the column and the table exactly once',
      () async {
        seed();

        await runV167();
        await runV167();

        expect(columnsOf('user_collections').where((c) => c == 'romm_origin'), [
          'romm_origin',
        ]);
        expect(tableExists('app_romm_collection_outbox'), isTrue);
        expect(originOf('mirror')['romm_origin'], 'romm');
        expect(originOf('plain')['romm_origin'], isNull);
      },
    );

    test(
      'a database a branch already carried past v167 keeps its local rows',
      () async {
        // The column exists and a push already recorded `local`; the backfill
        // only fills nulls, so the pushed collection is not re-labelled.
        seed();
        db.execute('ALTER TABLE user_collections ADD COLUMN romm_origin TEXT');
        db.execute(
          "INSERT INTO user_collections (id, name, romm_server_url, "
          "romm_collection_id, romm_collection_virtual, romm_origin) "
          "VALUES ('pushed', 'Mine', 'https://romm.local', '30', 0, 'local')",
        );

        await runV167();

        expect(originOf('pushed')['romm_origin'], 'local');
        expect(originOf('mirror')['romm_origin'], 'romm');
        expect(originOf('plain')['romm_origin'], isNull);
      },
    );

    test('creates the outbox keyed by collection_id', () async {
      seed();
      await runV167();

      expect(tableExists('app_romm_collection_outbox'), isTrue);
      expect(columnsOf('app_romm_collection_outbox'), [
        'collection_id',
        'romm_server_url',
        'romm_collection_id',
        'name_dirty',
        'artwork_dirty',
        'members_dirty',
        'delete_remote',
        'last_pushed_rom_ids',
        'updated_at',
      ]);
      final key = db
          .select('PRAGMA table_info(app_romm_collection_outbox)')
          .where((c) => (c['pk'] as int) > 0)
          .map((c) => c['name'].toString());
      expect(key, ['collection_id']);

      final info = {
        for (final c in db.select(
          'PRAGMA table_info(app_romm_collection_outbox)',
        ))
          c['name'].toString(): c,
      };
      for (final flag in [
        'name_dirty',
        'artwork_dirty',
        'members_dirty',
        'delete_remote',
      ]) {
        expect(info[flag]!['notnull'], 1, reason: '$flag is NOT NULL');
        expect(info[flag]!['dflt_value'], '0', reason: '$flag defaults to 0');
      }
      expect(info['last_pushed_rom_ids']!['notnull'], 0);
    });

    test(
      'a database without user_collections still gets the outbox, not failed',
      () async {
        await runV167();

        expect(tableExists('user_collections'), isFalse);
        expect(tableExists('app_romm_collection_outbox'), isTrue);
      },
    );

    test('a fresh database gets the column and the table from the CREATEs', () {
      db.execute(SqliteMigrations.createUserCollectionsTableSql);
      db.execute(SqliteMigrations.createAppRommCollectionOutboxTableSql);

      expect(columnsOf('user_collections'), contains('romm_origin'));
      expect(tableExists('app_romm_collection_outbox'), isTrue);
    });
  });
}
