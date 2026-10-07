import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';

/// The `gamepadGlyphStyle` field on [ConfigModel]: default, both JSON key
/// spellings, toJson round trip, copyWith.
///
/// Literal expected values throughout.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"
void main() {
  group('ConfigModel.gamepadGlyphStyle', () {
    test("defaults to 'auto'", () {
      expect(const ConfigModel().gamepadGlyphStyle, 'auto');
    });

    test('fromJson reads the camelCase key', () {
      final model = ConfigModel.fromJson(const {
        'gamepadGlyphStyle': 'nintendo',
      });
      expect(model.gamepadGlyphStyle, 'nintendo');
    });

    test('fromJson reads the snake_case key', () {
      final model = ConfigModel.fromJson(const {
        'gamepad_glyph_style': 'positional',
      });
      expect(model.gamepadGlyphStyle, 'positional');
    });

    test('fromJson with a missing key defaults to auto', () {
      expect(ConfigModel.fromJson(const {}).gamepadGlyphStyle, 'auto');
    });

    test('toJson round trip keeps the value', () {
      const model = ConfigModel(gamepadGlyphStyle: 'playstation');
      final json = model.toJson();
      expect(json['gamepadGlyphStyle'], 'playstation');
      expect(ConfigModel.fromJson(json).gamepadGlyphStyle, 'playstation');
    });

    test('copyWith changes only that field', () {
      const model = ConfigModel(
        gamepadGlyphStyle: 'xbox',
        activeSyncProvider: 'neosync',
      );
      final copied = model.copyWith(gamepadGlyphStyle: 'nintendo');
      expect(copied.gamepadGlyphStyle, 'nintendo');
      expect(copied.activeSyncProvider, model.activeSyncProvider);
      // And copyWith(null) keeps it (the field is a String, not nullable, so
      // null means "leave alone").
      expect(model.copyWith().gamepadGlyphStyle, 'xbox');
    });
  });
}
