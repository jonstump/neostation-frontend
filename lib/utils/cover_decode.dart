import 'dart:math' as math;

/// Decode width, in physical pixels, for a cover drawn [logicalWidth] logical
/// pixels wide on a display with [devicePixelRatio].
///
/// Rounded up so the decoded bitmap is never smaller than what is painted
/// (which would blur), and never larger than needed (which is what made a
/// 500-ROM platform decode every cover at its native size). Never below 1, so
/// a not-yet-laid-out or degenerate width still yields a valid `cacheWidth`.
int coverDecodeWidth({
  required double logicalWidth,
  required double devicePixelRatio,
}) => _decodePixels(logicalWidth, devicePixelRatio);

/// Decode height, in physical pixels, for a cover drawn [logicalHeight]
/// logical pixels tall. The width's counterpart, with the same rounding and
/// the same floor of 1.
int coverDecodeHeight({
  required double logicalHeight,
  required double devicePixelRatio,
}) => _decodePixels(logicalHeight, devicePixelRatio);

int _decodePixels(double logical, double devicePixelRatio) {
  final px = logical * devicePixelRatio;
  if (px.isNaN || px.isInfinite) return 1;
  return math.max(1, px.ceil());
}

/// The `cacheWidth` / `cacheHeight` pair for a cover painted with
/// [BoxFit.cover] into a box of [logicalWidth] x [logicalHeight].
///
/// Only ever one of the two: `cacheWidth` and `cacheHeight` together make
/// Flutter resize to exactly that rectangle, which distorts the art. So the
/// question is which axis to pin, and cover answers it — for a box W x H and a
/// source of aspect `a` (width/height), cover paints
/// `max(W, H * a)` wide by `max(H, W / a)` tall. A source with `a >= W / H`
/// fills the box's height exactly and overflows its width; a narrower one
/// fills the width exactly and overflows the height. Pinning the *smaller*
/// axis therefore caps the bitmap below what is painted for everything on the
/// other side of that ratio.
///
/// So pin the box's longer axis. On the browse grid, whose tile is taller than
/// it is wide, that is the height: a 1000x500 cover in a 200-logical-pixel
/// cell (283 tall) is painted 567 wide, and hinting the 200px cell width used
/// to upsample it about 2.8x. The height hint is exact for it, exact for the
/// 264x374 IGDB shape the grid is built around, and exact for everything
/// between — and decodes no more pixels than the cell width did for an IGDB
/// cover. Only a source *taller* than the tile is capped, by the ratio it
/// exceeds the tile's by, which for real cover art is a fraction rather than
/// the multiple a banner used to be off by.
///
/// A square box (the list row's thumbnail) has no longer axis; it keeps the
/// width, since cover art is portrait far more often than landscape.
({int? cacheWidth, int? cacheHeight}) coverDecodeHint({
  required double? logicalWidth,
  required double? logicalHeight,
  required double devicePixelRatio,
}) {
  if (logicalHeight != null &&
      (logicalWidth == null || logicalHeight > logicalWidth)) {
    return (
      cacheWidth: null,
      cacheHeight: coverDecodeHeight(
        logicalHeight: logicalHeight,
        devicePixelRatio: devicePixelRatio,
      ),
    );
  }
  if (logicalWidth == null) return (cacheWidth: null, cacheHeight: null);
  return (
    cacheWidth: coverDecodeWidth(
      logicalWidth: logicalWidth,
      devicePixelRatio: devicePixelRatio,
    ),
    cacheHeight: null,
  );
}
