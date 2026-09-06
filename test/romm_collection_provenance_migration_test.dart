import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v161, which adds the four nullable RomM provenance
/// columns to `user_collections`: `romm_server_url`, `romm_collection_id`,
/// `romm_collection_virtual` and `romm_synced_at`.
///
/// A collection made before this version mirrors nothing, so every existing
/// row keeps null in all four.
///
/// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ
/// "Collection Provenance Columns"
void main() {
  late Database db;

  /// The "old device" case: `user_collections` as v139 created it, without
  /// the provenance columns.
  const v139Table = '''
    CREATE TABLE user_collections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      image_path TEXT,
      color1 TEXT,
      color2 TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  ''';

  const provenance = [
    'romm_server_url',
    'romm_collection_id',
    'romm_collection_virtual',
    'romm_synced_at',
  ];

  setUp(() {
    db = sqlite3.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV161() => SqliteMigrations.migrateToVersion(db, 161);

  List<String> columns() => db
      .select('PRAGMA table_info(user_collections)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v161', () {
    test('a fresh database gets all four columns from the CREATE', () {
      db.execute(SqliteMigrations.createUserCollectionsTableSql);
      expect(columns(), containsAll(provenance));
      expect(SqliteMigrations.rommCollectionProvenanceColumns, provenance);
    });

    test('adds all four columns to a v160 database', () async {
      db.execute(v139Table);
      for (final column in provenance) {
        expect(columns(), isNot(contains(column)));
      }

      await runV161();

      expect(columns(), containsAll(provenance));
      final types = {
        for (final c in db.select('PRAGMA table_info(user_collections)'))
          c['name'].toString(): c['type'].toString(),
      };
      expect(types['romm_collection_virtual'], 'INTEGER');
      expect(types['romm_server_url'], 'TEXT');
      expect(types['romm_collection_id'], 'TEXT');
      expect(types['romm_synced_at'], 'TEXT');
    });

    test('leaves existing collections intact with null provenance', () async {
      db.execute(v139Table);
      db.execute(
        "INSERT INTO user_collections (id, name, color1, sort_order) "
        "VALUES ('c1', 'Favourites', '#ff0000', 3)",
      );
      db.execute(
        "INSERT INTO user_collections (id, name) VALUES ('c2', 'RPGs')",
      );

      await runV161();

      final rows = db.select(
        'SELECT id, name, color1, sort_order, romm_server_url, '
        'romm_collection_id, romm_collection_virtual, romm_synced_at '
        'FROM user_collections ORDER BY id',
      );
      expect(rows.length, 2);
      expect(rows.first['name'], 'Favourites');
      expect(rows.first['color1'], '#ff0000');
      expect(rows.first['sort_order'], 3);
      for (final row in rows) {
        for (final column in provenance) {
          expect(row[column], isNull, reason: '$column of ${row['id']}');
        }
      }
    });

    test('stores and reads provenance after migrating', () async {
      db.execute(v139Table);
      await runV161();
      db.execute(
        "INSERT INTO user_collections (id, name, romm_server_url, "
        "romm_collection_id, romm_collection_virtual, romm_synced_at) "
        "VALUES ('c1', 'Best of SNES', 'https://romm.local', '12', 0, "
        "'2026-09-05T10:00:00.000Z')",
      );
      final row = db.select('SELECT * FROM user_collections').first;
      expect(row['romm_server_url'], 'https://romm.local');
      expect(row['romm_collection_id'], '12');
      expect(row['romm_collection_virtual'], 0);
      expect(row['romm_synced_at'], '2026-09-05T10:00:00.000Z');
    });

    test('adds only the columns that are missing', () async {
      db.execute(v139Table);
      db.execute(
        'ALTER TABLE user_collections ADD COLUMN romm_collection_id TEXT',
      );
      db.execute(
        "INSERT INTO user_collections (id, name, romm_collection_id) "
        "VALUES ('c1', 'Best of SNES', '12')",
      );

      await runV161();

      expect(columns().where((c) => c == 'romm_collection_id').length, 1);
      expect(columns(), containsAll(provenance));
      final row = db.select('SELECT * FROM user_collections').first;
      expect(row['romm_collection_id'], '12');
      expect(row['romm_server_url'], isNull);
      expect(row['romm_collection_virtual'], isNull);
      expect(row['romm_synced_at'], isNull);
    });

    test('running twice is a no-op', () async {
      db.execute(v139Table);
      db.execute(
        "INSERT INTO user_collections (id, name) VALUES ('c1', 'RPGs')",
      );

      await runV161();
      final after = db.select('SELECT * FROM user_collections');
      await runV161();

      for (final column in provenance) {
        expect(columns().where((c) => c == column).length, 1);
      }
      expect(
        db.select('SELECT * FROM user_collections'),
        after,
        reason: 'the second run must change nothing',
      );
    });

    test('a database without the table is left alone', () async {
      await runV161();
      expect(columns(), isEmpty);
    });
  });
}
