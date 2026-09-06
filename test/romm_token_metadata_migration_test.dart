import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v160, which adds `user_romm_config.romm_token_name`
/// and `user_romm_config.romm_token_expires_at` — the display metadata of a
/// client token obtained through RomM's pairing code.
///
/// A row written before the columns existed describes a pasted key or a
/// password login, which has no token name to show, so the migration leaves
/// both null.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Database
/// Operation Standards"
void main() {
  late Database db;

  /// The "old device" case: user_romm_config as v131 left it, without the
  /// paired-token columns.
  const v131Table = '''
    CREATE TABLE user_romm_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      server_url TEXT,
      username TEXT,
      password TEXT,
      api_key TEXT,
      access_token TEXT,
      refresh_token TEXT,
      token_expires INTEGER,
      last_verified TEXT,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  ''';

  setUp(() {
    db = sqlite3.openInMemory();
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV160() => SqliteMigrations.migrateToVersion(db, 160);

  List<String> columns() => db
      .select('PRAGMA table_info(user_romm_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v160', () {
    test('a fresh database gets both columns from the CREATE', () {
      db.execute(SqliteMigrations.createUserRommConfigTableSql);
      expect(
        columns(),
        containsAll(['romm_token_name', 'romm_token_expires_at']),
      );
    });

    test('adds both columns to a v159 database', () async {
      db.execute(v131Table);
      expect(columns(), isNot(contains('romm_token_name')));
      expect(columns(), isNot(contains('romm_token_expires_at')));

      await runV160();

      expect(
        columns(),
        containsAll(['romm_token_name', 'romm_token_expires_at']),
      );
    });

    test(
      'leaves the existing connection row intact with null metadata',
      () async {
        db.execute(v131Table);
        db.execute(
          "INSERT INTO user_romm_config (id, server_url, username, api_key) "
          "VALUES (1, 'https://romm.local', 'jon', '')",
        );

        await runV160();

        final rows = db.select(
          'SELECT server_url, username, api_key, romm_token_name, '
          'romm_token_expires_at FROM user_romm_config',
        );
        expect(rows.length, 1);
        expect(rows.first['server_url'], 'https://romm.local');
        expect(rows.first['username'], 'jon');
        expect(rows.first['api_key'], '');
        expect(rows.first['romm_token_name'], isNull);
        expect(rows.first['romm_token_expires_at'], isNull);
      },
    );

    test('stores and reads the metadata after migrating', () async {
      db.execute(v131Table);
      await runV160();
      db.execute(
        "INSERT INTO user_romm_config "
        "(id, server_url, romm_token_name, romm_token_expires_at) "
        "VALUES (1, 'https://x', 'Nova', '2027-01-02T03:04:05.000Z')",
      );
      final row = db.select('SELECT * FROM user_romm_config').first;
      expect(row['romm_token_name'], 'Nova');
      expect(row['romm_token_expires_at'], '2027-01-02T03:04:05.000Z');
    });

    test('is a no-op when only one column is missing', () async {
      db.execute(v131Table);
      db.execute(
        'ALTER TABLE user_romm_config ADD COLUMN romm_token_name TEXT',
      );
      db.execute(
        "INSERT INTO user_romm_config (id, server_url, romm_token_name) "
        "VALUES (1, 'https://x', 'Nova')",
      );

      await runV160();

      expect(columns().where((c) => c == 'romm_token_name').length, 1);
      expect(columns(), contains('romm_token_expires_at'));
      final row = db.select('SELECT * FROM user_romm_config').first;
      expect(row['romm_token_name'], 'Nova');
      expect(row['romm_token_expires_at'], isNull);
    });

    test('running twice is a no-op', () async {
      db.execute(v131Table);
      db.execute(
        "INSERT INTO user_romm_config (id, server_url) VALUES (1, 'https://x')",
      );

      await runV160();
      final after = db.select('SELECT * FROM user_romm_config');
      await runV160();

      expect(columns().where((c) => c == 'romm_token_name').length, 1);
      expect(columns().where((c) => c == 'romm_token_expires_at').length, 1);
      expect(
        db.select('SELECT * FROM user_romm_config'),
        after,
        reason: 'the second run must change nothing',
      );
    });

    test('a database without the table is left alone', () async {
      await runV160();
      expect(columns(), isEmpty);
    });
  });
}
