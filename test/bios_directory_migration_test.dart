import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v162, which adds `user_config.bios_directory` — the
/// folder the user picks for BIOS/firmware downloads when RetroArch's own
/// `system_directory` is unknown.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Database Operation Standards"
void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    // The "old device" case: a user_config without the new column.
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        scan_on_startup INTEGER DEFAULT 1,
        esde_folder_path TEXT DEFAULT ''
      )
    ''');
    db.execute('INSERT INTO user_config (id) VALUES (1)');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV162() => SqliteMigrations.migrateToVersion(db, 162);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v162', () {
    test('adds bios_directory when the column is missing', () async {
      await runV162();

      expect(configColumns(), contains('bios_directory'));
    });

    test('leaves existing rows null', () async {
      await runV162();

      final row = db.select('SELECT bios_directory FROM user_config').first;
      expect(row['bios_directory'], isNull);
    });

    test(
      're-running adds the column once and keeps the stored value',
      () async {
        await runV162();
        db.execute('UPDATE user_config SET bios_directory = ?', ['/roms/bios']);

        await runV162();

        expect(
          configColumns().where((c) => c == 'bios_directory'),
          hasLength(1),
        );
        final row = db.select('SELECT bios_directory FROM user_config').first;
        expect(row['bios_directory'], '/roms/bios');
      },
    );

    test('leaves the other config columns untouched', () async {
      await runV162();

      final columns = configColumns();
      expect(columns, contains('scan_on_startup'));
      expect(columns, contains('esde_folder_path'));
    });

    test('is a no-op when user_config does not exist', () async {
      db.execute('DROP TABLE user_config');

      await runV162();

      expect(
        db
            .select("SELECT name FROM sqlite_master WHERE name = 'user_config'")
            .isEmpty,
        isTrue,
      );
    });
  });
}
