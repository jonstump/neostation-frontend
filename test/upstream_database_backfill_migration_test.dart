import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v172, the backfill for a database an upstream build
/// migrated.
///
/// Upstream and this fork both used slots 157 to 160, for different columns.
/// A database upstream left at 160 is already past those slots when it first
/// meets this binary, so the fork's v157 to v160 never run on it. v172 runs
/// them again; each is guarded per column, so it is a no-op everywhere else.
void main() {
  late Database db;

  setUp(() {
    // The "upstream device" case: every table as upstream's v160 leaves it,
    // without the columns this fork added in its own v157 to v160.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_system_settings (
        app_system_id TEXT NOT NULL,
        esde_media_dir TEXT,
        UNIQUE(app_system_id)
      )
    ''');
    db.execute('''
      CREATE TABLE app_romm_rom_map (
        romname TEXT NOT NULL,
        system_folder TEXT NOT NULL,
        romm_rom_id INTEGER NOT NULL,
        romm_fs_name TEXT
      )
    ''');
    db.execute('''
      CREATE TABLE user_screenscraper_metadata (
        app_system_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        real_name TEXT
      )
    ''');
    db.execute('''
      CREATE TABLE user_romm_config (
        id INTEGER PRIMARY KEY,
        server_url TEXT
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV172() => SqliteMigrations.migrateToVersion(db, 172);

  List<String> columns(String table) => db
      .select('PRAGMA table_info($table)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v172', () {
    test('adds every column the skipped v157 to v160 would have', () async {
      await runV172();

      expect(columns('user_system_settings'), contains('esde_media_root'));
      expect(columns('app_romm_rom_map'), contains('link_source'));
      expect(
        columns('user_screenscraper_metadata'),
        contains('metadata_source'),
      );
      expect(
        columns('user_romm_config'),
        containsAll(['romm_token_name', 'romm_token_expires_at']),
      );
    });

    test('keeps the rows that were already there', () async {
      db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) "
        "VALUES ('snes', 'snes')",
      );
      db.execute(
        "INSERT INTO user_romm_config (id, server_url) "
        "VALUES (1, 'https://romm.example')",
      );

      await runV172();

      final settings = db.select('SELECT * FROM user_system_settings').single;
      expect(settings['esde_media_dir'], 'snes');
      expect(settings['esde_media_root'], isNull);
      final config = db.select('SELECT * FROM user_romm_config').single;
      expect(config['server_url'], 'https://romm.example');
      expect(config['romm_token_name'], isNull);
    });

    test('is a no-op on a database that already ran them', () async {
      await runV172();
      final before = {
        for (final t in const [
          'user_system_settings',
          'app_romm_rom_map',
          'user_screenscraper_metadata',
          'user_romm_config',
        ])
          t: columns(t),
      };

      await runV172();

      for (final entry in before.entries) {
        expect(columns(entry.key), entry.value);
      }
    });
  });
}
