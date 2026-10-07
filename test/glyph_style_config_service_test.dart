import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/services/gamepad/glyph_style_config.dart';

import 'database_test_helper.dart';

/// Writes a config with `gamepadGlyphStyle: 'nintendo'` through
/// `SqliteConfigService.saveConfig` against the in-memory database and reads
/// it back through `loadConfig`, verifying the read/write plumbing end to end.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"
void main() {
  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  test('saveConfig with nintendo round-trips through loadConfig', () async {
    final written = ConfigModel(gamepadGlyphStyle: 'nintendo');
    await SqliteConfigService.saveConfig(written);

    final read = await SqliteConfigService.loadConfig();
    expect(read.gamepadGlyphStyle, 'nintendo');

    // The stored value is the plain enum name, which the converter reads
    // back as the pinned style.
    expect(glyphStyleFromConfig(read.gamepadGlyphStyle), GlyphStyle.nintendo);
  });

  test('a fresh row reads the DEFAULT (auto) through loadConfig', () async {
    // Insert a bare row without touching the column: the DEFAULT must
    // produce 'auto' on read.
    // The DatabaseTestHelper injected the in-memory adapter; the raw sqlite3
    // database is reachable through it. Re-run setUp() to get the adapter.
    final adapter = await dbHelper.setUp();
    adapter.execute('INSERT INTO user_config (id) VALUES (1)');

    final read = await SqliteConfigService.loadConfig();
    expect(read.gamepadGlyphStyle, 'auto');
    expect(glyphStyleFromConfig(read.gamepadGlyphStyle), isNull);
  });

  test('a NULL in the column falls back to auto through loadConfig', () async {
    // An explicit NULL exercises the read-side fallback, which the DEFAULT
    // hides on a plain INSERT.
    final adapter = await dbHelper.setUp();
    adapter.execute('INSERT INTO user_config (id) VALUES (1)');
    adapter.execute(
      'UPDATE user_config SET gamepad_glyph_style = NULL WHERE id = 1',
    );

    final read = await SqliteConfigService.loadConfig();
    expect(read.gamepadGlyphStyle, 'auto');
    expect(glyphStyleFromConfig(read.gamepadGlyphStyle), isNull);
  });
}
