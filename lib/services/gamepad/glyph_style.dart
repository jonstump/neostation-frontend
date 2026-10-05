// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"

/// The glyph look a hint is drawn with.
///
/// `auto` is not a style: the detector (`GlyphStyleDetector`) picks one of
/// these, and a user pin overrides it (SPEC-0022 REQ "Auto Style With A Pin").
enum GlyphStyle {
  /// The shipped Xbox asset set, what every hint uses today.
  xbox,

  /// Nintendo layout and naming; asset set filled by #275.
  nintendo,

  /// PlayStation shapes and naming; asset set filled by #275.
  playstation,

  /// A drawn diamond with the pressed position lit; no letters at all.
  positional,
}

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"

/// The four positions of the face-button diamond, for the `positional` style.
enum GlyphSlot {
  /// The bottom position (B on a Nintendo pad).
  bottom,

  /// The right position (A on a Nintendo pad).
  right,

  /// The left position (Y on a Nintendo pad).
  left,

  /// The top position (X on a Nintendo pad).
  top,
}
