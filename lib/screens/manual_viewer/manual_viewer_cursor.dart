/// The directions the D-pad pans a zoomed page in.
enum ManualPanDirection { up, down, left, right }

/// Everything the manual viewer's gamepad mapping decides, with no Flutter or
/// pdfium in it.
///
/// The screen owns the pixels; this owns the answers — which page L1/R1 land
/// on, what the indicator reads, which zoom step a press cycles to, and
/// whether the D-pad pans or is ignored. Keeping it pure is what makes the
/// input mapping testable without a PDF, a renderer, or a device.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
class ManualViewerCursor {
  /// Zoom multipliers over the viewer's fit-to-page scale, cycled by the zoom
  /// button. The first is "the whole page", which is where the viewer opens.
  static const List<double> zoomSteps = [1.0, 1.5, 2.5];

  /// How far one D-pad press moves a zoomed page, as a fraction of the
  /// viewport. A readable step rather than a jump, matching the description
  /// panel's three-lines-per-press feel.
  static const double panFraction = 0.25;

  int _pageCount;
  int _page;
  int _zoomIndex = 0;

  /// Starts on page 1 of [pageCount] (clamped to at least one page, so an
  /// indicator exists before the document reports its length).
  ManualViewerCursor({int pageCount = 1, int page = 1})
    : _pageCount = pageCount < 1 ? 1 : pageCount,
      _page = 1 {
    setPage(page);
  }

  /// Pages in the document; at least 1.
  int get pageCount => _pageCount;

  /// The page being shown, 1-based.
  int get page => _page;

  /// The current zoom multiplier over fit-to-page.
  double get zoom => zoomSteps[_zoomIndex];

  /// Whether the page is magnified, and so whether the D-pad has anywhere to
  /// pan. At fit-to-page there is nothing off screen to reach.
  bool get canPan => _zoomIndex > 0;

  /// Values for the `{page}/{total}` indicator string.
  String get pageLabel => '$_page';
  String get pageCountLabel => '$_pageCount';

  /// Learns the real page count once the document is open, keeping the current
  /// page inside it. Returns whether anything changed.
  bool setPageCount(int count) {
    final next = count < 1 ? 1 : count;
    if (next == _pageCount) return false;
    _pageCount = next;
    if (_page > _pageCount) _page = _pageCount;
    return true;
  }

  /// Moves to [page], clamped to the document. Returns whether it moved.
  bool setPage(int page) {
    final next = page < 1
        ? 1
        : page > _pageCount
        ? _pageCount
        : page;
    if (next == _page) return false;
    _page = next;
    return true;
  }

  /// R1. Returns whether the page changed — false on the last page, where the
  /// press is swallowed rather than wrapping the reader back to the cover.
  bool nextPage() => setPage(_page + 1);

  /// L1. Returns whether the page changed.
  bool previousPage() => setPage(_page - 1);

  /// Cycles to the next zoom step, wrapping back to fit-to-page after the
  /// last, so one button covers the whole range on a pad with no free ones.
  /// Returns the new multiplier.
  double cycleZoom() {
    _zoomIndex = (_zoomIndex + 1) % zoomSteps.length;
    return zoom;
  }

  /// Back to fit-to-page. Used when a page turn lands on a new page, so the
  /// reader is not dropped into the corner of it.
  bool resetZoom() {
    if (_zoomIndex == 0) return false;
    _zoomIndex = 0;
    return true;
  }

  /// The offset one D-pad press pans by inside a [viewWidth] x [viewHeight]
  /// viewport, or null while the page is not magnified.
  ///
  /// Returned as a pair rather than an `Offset` to keep this file free of
  /// Flutter imports; the screen turns it into one.
  (double dx, double dy)? panStep(
    ManualPanDirection direction, {
    required double viewWidth,
    required double viewHeight,
  }) {
    if (!canPan) return null;
    final dx = viewWidth * panFraction;
    final dy = viewHeight * panFraction;
    return switch (direction) {
      ManualPanDirection.left => (-dx, 0.0),
      ManualPanDirection.right => (dx, 0.0),
      ManualPanDirection.up => (0.0, -dy),
      ManualPanDirection.down => (0.0, dy),
    };
  }
}
