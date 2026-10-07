import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// Tests for migration v173, which adds `user_config.gamepad_glyph_style`.
///
/// The default is the point: `'auto'` (not pinned, style follows the pad)
/// must match what a config written before the column existed should read on
/// upgrade. The value space is `'auto'`, `'xbox'`, `'nintendo'`,
/// `'playstation'`, `'positional'`.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"
void main() {
  late Database db;

  setUp(() {
    // The "old device" case: user_config without the new column.
    db = sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        game_view_mode TEXT DEFAULT 'list',
        legend_hidden INTEGER DEFAULT 0
      )
    ''');
  });

  tearDown(() {
    db.close();
  });

  Future<void> runV173() => SqliteMigrations.migrateToVersion(db, 173);

  List<String> configColumns() => db
      .select('PRAGMA table_info(user_config)')
      .map((c) => c['name'].toString())
      .toList();

  group('migration v173', () {
    test('adds gamepad_glyph_style when it is missing', () async {
      expect(configColumns(), isNot(contains('gamepad_glyph_style')));

      await runV173();

      expect(configColumns(), contains('gamepad_glyph_style'));
    });

    test("an existing row reads 'auto' after the migration", () async {
      db.execute('INSERT INTO user_config (id) VALUES (1)');

      await runV173();

      final rows = db.select(
        'SELECT gamepad_glyph_style FROM user_config WHERE id = 1',
      );
      expect(rows.first['gamepad_glyph_style'], 'auto');
    });

    test('a row inserted afterwards with an explicit value keeps it', () async {
      await runV173();

      db.execute(
        "INSERT INTO user_config (id, gamepad_glyph_style) VALUES (1, 'nintendo')",
      );

      final rows = db.select(
        'SELECT gamepad_glyph_style FROM user_config WHERE id = 1',
      );
      expect(rows.first['gamepad_glyph_style'], 'nintendo');
    });

    test(
      're-running the migration is a no-op and keeps a stored value',
      () async {
        await runV173();
        db.execute(
          "INSERT INTO user_config (id, gamepad_glyph_style) VALUES (1, 'xbox')",
        );
        await runV173();

        final rows = db.select(
          'SELECT gamepad_glyph_style FROM user_config WHERE id = 1',
        );
        expect(rows.first['gamepad_glyph_style'], 'xbox');
        expect(
          configColumns().where((c) => c == 'gamepad_glyph_style').length,
          1,
          reason: 'the column must not be added twice',
        );
      },
    );

    test('running when the column already exists is a no-op', () async {
      db.execute(
        "ALTER TABLE user_config ADD COLUMN gamepad_glyph_style "
        "TEXT DEFAULT 'auto'",
      );
      db.execute(
        "INSERT INTO user_config (id, gamepad_glyph_style) VALUES (1, 'positional')",
      );

      await runV173();

      // The user's choice survives.
      final rows = db.select(
        'SELECT gamepad_glyph_style FROM user_config WHERE id = 1',
      );
      expect(rows.first['gamepad_glyph_style'], 'positional');
      expect(
        configColumns().where((c) => c == 'gamepad_glyph_style').length,
        1,
        reason: 'the column must not be added twice',
      );
    });

    test('a database with no user_config table does not throw', () async {
      final bare = sqlite3.openInMemory();
      addTearDown(bare.close);

      // Must complete without throwing and without creating the table.
      await SqliteMigrations.migrateToVersion(bare, 173);

      final tables = bare
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='user_config'",
          )
          .map((r) => r['name'].toString())
          .toList();
      expect(tables, isEmpty, reason: 'v173 must not create user_config');
    });
  });
}
