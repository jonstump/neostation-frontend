import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/services/gamepad/glyph_style_config.dart';

/// The converter between the stored `gamepad_glyph_style` TEXT value and the
/// [GlyphStyle] the UI works with.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"
void main() {
  group('glyphStyleFromConfig', () {
    test('the four style values map to their enum', () {
      expect(glyphStyleFromConfig('xbox'), GlyphStyle.xbox);
      expect(glyphStyleFromConfig('nintendo'), GlyphStyle.nintendo);
      expect(glyphStyleFromConfig('playstation'), GlyphStyle.playstation);
      expect(glyphStyleFromConfig('positional'), GlyphStyle.positional);
    });

    test("'auto', null and '' read as unpinned (null)", () {
      expect(glyphStyleFromConfig('auto'), isNull);
      expect(glyphStyleFromConfig(null), isNull);
      expect(glyphStyleFromConfig(''), isNull);
    });

    test('unknown values degrade to null, never throw', () {
      expect(glyphStyleFromConfig('switch'), isNull);
      expect(glyphStyleFromConfig('garbage'), isNull);
    });

    test('matching is exact lowercase: no case or whitespace tolerance', () {
      expect(glyphStyleFromConfig('AUTO'), isNull);
      expect(glyphStyleFromConfig('Xbox '), isNull);
      expect(glyphStyleFromConfig('Nintendo'), isNull);
      // Whitespace alone does not turn a valid value into a match: the
      // trimming-only mutation survived the earlier tests because 'Xbox '
      // has the wrong case. These catch trim() without the case check.
      expect(glyphStyleFromConfig(' xbox'), isNull);
      expect(glyphStyleFromConfig('xbox '), isNull);
      expect(glyphStyleFromConfig('\nxbox'), isNull);
    });
  });

  group('glyphStyleToConfig', () {
    test('null stores auto', () {
      expect(glyphStyleToConfig(null), 'auto');
    });

    test('each style stores its enum name', () {
      expect(glyphStyleToConfig(GlyphStyle.xbox), 'xbox');
      expect(glyphStyleToConfig(GlyphStyle.nintendo), 'nintendo');
      expect(glyphStyleToConfig(GlyphStyle.playstation), 'playstation');
      expect(glyphStyleToConfig(GlyphStyle.positional), 'positional');
    });
  });

  group('round trip', () {
    test('every GlyphStyle value survives the round trip', () {
      for (final style in GlyphStyle.values) {
        expect(
          glyphStyleFromConfig(glyphStyleToConfig(style)),
          style,
          reason: '${style.name} must round-trip',
        );
      }
    });
  });
}
