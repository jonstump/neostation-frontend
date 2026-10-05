import 'glyph_style.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Auto Style With A Pin"

/// Picks the glyph style for the connected controller, before any user pin.
///
/// Pure function: no I/O, no platform calls. The caller (a later slice) reads
/// the vendor id from the pad's system info on connect and the device model
/// from the platform, then calls [detect] and feeds the result to
/// `GlyphService.setDetected`. A pinned style always wins over this.
abstract final class GlyphStyleDetector {
  /// Nintendo's USB vendor id (0x057e).
  static const int nintendoVendorId = 0x057e;

  /// Sony's USB vendor id (0x054c).
  static const int sonyVendorId = 0x054c;

  /// Android device models known to carry a Nintendo-layout pad, matched
  /// case-insensitively as a substring. The Retroid Pocket Nova included
  /// (SPEC-0022 scenario "Nova on auto"); extend as reports come in.
  static const List<String> nintendoLayoutModels = ['Retroid Pocket Nova'];

  /// Nintendo when the vendor is Nintendo's or the device model matches the
  /// known Nintendo-layout list; PlayStation when the vendor is Sony's;
  /// Xbox otherwise. Nintendo wins over Sony when both match. Null inputs
  /// are fine and simply do not match.
  static GlyphStyle detect({int? vendorId, String? deviceModel}) {
    final model = deviceModel;
    final modelMatches =
        model != null &&
        model.isNotEmpty &&
        nintendoLayoutModels.any(
          (entry) => model.toLowerCase().contains(entry.toLowerCase()),
        );
    if (vendorId == nintendoVendorId || modelMatches) {
      return GlyphStyle.nintendo;
    }
    if (vendorId == sonyVendorId) {
      return GlyphStyle.playstation;
    }
    return GlyphStyle.xbox;
  }
}
