import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v157, which adds `user_system_settings.esde_media_root`
/// — the absolute per-system media root recorded by an in-folder gamelist
/// import (RomM / Batocera layout).
///
/// The column sits beside the ES-DE `esde_media_dir` folder name and must not
/// disturb it: a database that already carries ES-DE imports has to come out
/// of the upgrade with every folder name intact and the new column null, so
/// those systems keep resolving media exactly as before.
///
/// Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Schema
/// Migration"
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_system_settings as v98 left it — with the
    // ES-DE folder-name column but without the absolute media root.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_system_settings (
        app_system_id TEXT NOT NULL,
        recursive_scan INTEGER DEFAULT 1,
        subfolder_view INTEGER DEFAULT 0,
        esde_media_dir TEXT,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(app_system_id)
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV157() => SqliteMigrations.migrateToVersion(db, 157);

  List<String> settingsColumns() => db
      .select('PRAGMA table_info(user_system_settings)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v157', () {
    test('adds esde_media_root when the column is missing', () async {
      expect(settingsColumns(), isNot(contains('esde_media_root')));

      await runV157();

      expect(settingsColumns(), contains('esde_media_root'));
    });

    test(
      'keeps existing ES-DE media folder names and leaves the root null',
      () async {
        db.execute(
          "INSERT INTO user_system_settings (app_system_id, esde_media_dir) "
          "VALUES ('snes', 'snes'), ('megadrive', 'genesis'), ('nes', NULL)",
        );

        await runV157();

        final rows = db.select(
          'SELECT app_system_id, esde_media_dir, esde_media_root '
          'FROM user_system_settings ORDER BY app_system_id',
        );
        expect(rows.length, 3);
        expect(
          rows.map((r) => [r['app_system_id'], r['esde_media_dir']]).toList(),
          [
            ['megadrive', 'genesis'],
            ['nes', null],
            ['snes', 'snes'],
          ],
          reason: 'ES-DE folder names must survive the upgrade untouched',
        );
        expect(rows.map((r) => r['esde_media_root']).toList(), [
          null,
          null,
          null,
        ], reason: 'no system gains an absolute root behind the user\'s back');
      },
    );

    test(
      'a row inserted after the migration defaults to a null root',
      () async {
        await runV157();
        db.execute(
          "INSERT INTO user_system_settings (app_system_id) VALUES ('snes')",
        );

        final rows = db.select(
          "SELECT esde_media_root FROM user_system_settings "
          "WHERE app_system_id = 'snes'",
        );
        expect(rows.first['esde_media_root'], isNull);
      },
    );

    test('stores an absolute root alongside an ES-DE folder name', () async {
      await runV157();
      db.execute(
        "INSERT INTO user_system_settings "
        "(app_system_id, esde_media_dir, esde_media_root) "
        "VALUES ('snes', 'snes', '/roms/snes')",
      );

      final rows = db.select(
        "SELECT esde_media_dir, esde_media_root FROM user_system_settings "
        "WHERE app_system_id = 'snes'",
      );
      expect(rows.first['esde_media_dir'], 'snes');
      expect(rows.first['esde_media_root'], '/roms/snes');
    });

    test('is a no-op when the column already exists', () async {
      db.execute(
        'ALTER TABLE user_system_settings ADD COLUMN esde_media_root TEXT',
      );
      db.execute(
        "INSERT INTO user_system_settings "
        "(app_system_id, esde_media_dir, esde_media_root) "
        "VALUES ('snes', NULL, '/roms/snes')",
      );

      await runV157();

      // A device that already has the column keeps the recorded root.
      final rows = db.select(
        "SELECT esde_media_root FROM user_system_settings "
        "WHERE app_system_id = 'snes'",
      );
      expect(rows.first['esde_media_root'], '/roms/snes');
      expect(
        settingsColumns().where((c) => c == 'esde_media_root').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('re-running the migration stays a no-op', () async {
      db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) "
        "VALUES ('snes', 'snes')",
      );

      await runV157();
      final after = db.select('SELECT * FROM user_system_settings');
      await runV157();

      expect(settingsColumns(), contains('esde_media_root'));
      expect(settingsColumns().where((c) => c == 'esde_media_root').length, 1);
      expect(
        db.select('SELECT * FROM user_system_settings'),
        after,
        reason: 'the second run must change nothing',
      );
    });
  });
}
