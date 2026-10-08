import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/gamepad/glyph_service.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';

import 'database_test_helper.dart';

/// The provider's glyph-style setter keeps [GlyphService] in sync with the
/// stored value: a pin change is visible to already-mounted hints without a
/// restart (SPEC-0022 REQ "Auto Style With A Pin").
///
/// The load path (`initialize` → `_loadConfig` → `_syncGlyphStyle`) is NOT
/// tested here: `initialize()` touches platform channels, network downloads
/// and asset syncing that no test harness can satisfy safely. See the PR's
/// "Found, not changed".
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Auto Style With A Pin"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late SqliteConfigProvider provider;

  setUp(() async {
    await helper.setUp();
    provider = SqliteConfigProvider();
  });

  tearDown(() async {
    // Reset the singleton so the next test starts unpinned on xbox.
    GlyphService.instance.setPinned(null);
    GlyphService.instance.setDetected(GlyphStyle.xbox);
    await helper.tearDown();
  });

  group('updateGamepadGlyphStyle', () {
    test('nintendo: config, stored row and service all agree', () async {
      var notifications = 0;
      provider.addListener(() => notifications++);

      await provider.updateGamepadGlyphStyle('nintendo');

      expect(provider.config.gamepadGlyphStyle, 'nintendo');
      final stored = await SqliteService.getUserConfig();
      expect(stored?['gamepad_glyph_style'].toString(), 'nintendo');
      expect(GlyphService.instance.pinned, GlyphStyle.nintendo);
      expect(GlyphService.instance.activeStyle, GlyphStyle.nintendo);
      // Exactly one provider notification for the call.
      expect(notifications, 1);
    });

    test('every style pins that style; auto clears the pin', () async {
      // Pin each style in turn.
      for (final entry in {
        'xbox': GlyphStyle.xbox,
        'nintendo': GlyphStyle.nintendo,
        'playstation': GlyphStyle.playstation,
        'positional': GlyphStyle.positional,
      }.entries) {
        await provider.updateGamepadGlyphStyle(entry.key);
        expect(provider.config.gamepadGlyphStyle, entry.key, reason: entry.key);
        expect(GlyphService.instance.pinned, entry.value, reason: entry.key);
      }

      // 'auto' clears the pin after one was set.
      await provider.updateGamepadGlyphStyle('auto');
      expect(provider.config.gamepadGlyphStyle, 'auto');
      expect(GlyphService.instance.pinned, isNull);
    });

    test('an unknown value stores auto and leaves the pin null', () async {
      for (final value in ['switch', '', 'XBOX']) {
        await provider.updateGamepadGlyphStyle(value);
        expect(
          provider.config.gamepadGlyphStyle,
          'auto',
          reason: "unknown '$value'",
        );
        expect(GlyphService.instance.pinned, isNull, reason: value);
        final stored = await SqliteService.getUserConfig();
        expect(
          stored?['gamepad_glyph_style'].toString(),
          'auto',
          reason: value,
        );
      }
    });

    test('the service notifies once per pin change, not on no-change', () {
      var serviceNotifications = 0;
      GlyphService.instance.addListener(() => serviceNotifications++);

      GlyphService.instance.setPinned(GlyphStyle.nintendo);
      expect(serviceNotifications, 1);
      GlyphService.instance.setPinned(GlyphStyle.nintendo);
      expect(serviceNotifications, 1, reason: 'same value: no notification');
    });

    test('detection loses to the pin', () async {
      GlyphService.instance.setDetected(GlyphStyle.nintendo);

      await provider.updateGamepadGlyphStyle('playstation');
      expect(GlyphService.instance.activeStyle, GlyphStyle.playstation);

      // Clearing the pin returns to the detected style.
      await provider.updateGamepadGlyphStyle('auto');
      expect(GlyphService.instance.pinned, isNull);
      expect(GlyphService.instance.activeStyle, GlyphStyle.nintendo);
    });
  });
}
