import 'glyph_style.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"

/// Converts between the stored `user_config.gamepad_glyph_style` TEXT value
/// and the [GlyphStyle] the UI works with.
///
/// `null` on the config side means "auto": not pinned, the hint style follows
/// the connected pad via the style detector. An unknown stored value (a
/// version skew, a typo in a future value) degrades to auto rather than
/// throwing — a broken preference must not break the settings screen.

/// The [GlyphStyle] the stored value pins, or null for auto/unpinned.
///
/// Exact lowercase match only: 'AUTO' or 'Xbox ' are unknown values and read
/// as auto, as does '' and null.
GlyphStyle? glyphStyleFromConfig(String? value) {
  switch (value) {
    case 'xbox':
      return GlyphStyle.xbox;
    case 'nintendo':
      return GlyphStyle.nintendo;
    case 'playstation':
      return GlyphStyle.playstation;
    case 'positional':
      return GlyphStyle.positional;
    default:
      // 'auto', null, '' and anything unknown: not pinned.
      return null;
  }
}

/// The stored value for [style]; null (unpinned) stores 'auto'.
String glyphStyleToConfig(GlyphStyle? style) =>
    style == null ? 'auto' : style.name;
