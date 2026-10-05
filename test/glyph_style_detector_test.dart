import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/services/gamepad/glyph_style_detector.dart';

/// The style detector: vendor id and device model in, style out. Pure
/// function, so these tests need no harness at all.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Auto Style With A Pin"
void main() {
  group('GlyphStyleDetector', () {
    test('Nintendo vendor id picks nintendo', () {
      expect(
        GlyphStyleDetector.detect(
          vendorId: GlyphStyleDetector.nintendoVendorId,
        ),
        GlyphStyle.nintendo,
      );
    });

    test('Sony vendor id picks playstation', () {
      expect(
        GlyphStyleDetector.detect(vendorId: GlyphStyleDetector.sonyVendorId),
        GlyphStyle.playstation,
      );
    });

    test('the Retroid Pocket Nova model picks nintendo', () {
      expect(
        GlyphStyleDetector.detect(deviceModel: 'Retroid Pocket Nova'),
        GlyphStyle.nintendo,
      );
    });

    test('a lower-case, embedded model still matches', () {
      expect(
        GlyphStyleDetector.detect(deviceModel: 'AYN retroid pocket nova 2'),
        GlyphStyle.nintendo,
      );
    });

    test('an unknown vendor and an unknown model pick xbox', () {
      expect(
        GlyphStyleDetector.detect(vendorId: 0x1234, deviceModel: 'RG556'),
        GlyphStyle.xbox,
      );
    });

    test('no inputs at all pick xbox', () {
      expect(GlyphStyleDetector.detect(), GlyphStyle.xbox);
    });

    test('an empty model string does not match', () {
      expect(GlyphStyleDetector.detect(deviceModel: ''), GlyphStyle.xbox);
    });

    test('a Nintendo vendor id wins over a Sony-looking model', () {
      expect(
        GlyphStyleDetector.detect(
          vendorId: GlyphStyleDetector.nintendoVendorId,
          deviceModel: 'PlayStation 5 DualSense',
        ),
        GlyphStyle.nintendo,
      );
    });

    test('a model match beats a Sony vendor id', () {
      expect(
        GlyphStyleDetector.detect(
          vendorId: GlyphStyleDetector.sonyVendorId,
          deviceModel: 'Retroid Pocket Nova',
        ),
        GlyphStyle.nintendo,
      );
    });
  });
}
