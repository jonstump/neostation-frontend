import 'dart:math' as math;

/// Decode width, in physical pixels, for a cover drawn [logicalWidth] logical
/// pixels wide on a display with [devicePixelRatio].
///
/// Rounded up so the decoded bitmap is never smaller than what is painted
/// (which would blur), and never larger than needed (which is what made a
/// 500-ROM platform decode every cover at its native size). Never below 1, so
/// a not-yet-laid-out or degenerate width still yields a valid `cacheWidth`.
// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Decode At Tile Size"
int coverDecodeWidth({
  required double logicalWidth,
  required double devicePixelRatio,
}) {
  final px = logicalWidth * devicePixelRatio;
  if (px.isNaN || px.isInfinite) return 1;
  return math.max(1, px.ceil());
}
