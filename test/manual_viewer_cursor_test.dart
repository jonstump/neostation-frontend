import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/manual_viewer/manual_viewer_cursor.dart';

/// The manual viewer's gamepad mapping, tested without a PDF, a renderer or a
/// device — which is the whole point of keeping it a pure helper.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
void main() {
  group('pages', () {
    test('R1 on page 3 of 10 shows page 4 and the indicator reads 4/10', () {
      final cursor = ManualViewerCursor(pageCount: 10, page: 3);

      expect(cursor.nextPage(), isTrue);

      expect(cursor.page, 4);
      expect(cursor.pageLabel, '4');
      expect(cursor.pageCountLabel, '10');
    });

    test('L1 walks back a page', () {
      final cursor = ManualViewerCursor(pageCount: 10, page: 4);

      expect(cursor.previousPage(), isTrue);
      expect(cursor.page, 3);
    });

    test('the ends are edges, not a wrap', () {
      final last = ManualViewerCursor(pageCount: 3, page: 3);
      expect(last.nextPage(), isFalse);
      expect(last.page, 3);

      final first = ManualViewerCursor(pageCount: 3);
      expect(first.previousPage(), isFalse);
      expect(first.page, 1);
    });

    test('opens on page 1 and reports at least one page', () {
      final cursor = ManualViewerCursor();
      expect(cursor.page, 1);
      expect(cursor.pageCount, 1);
      expect(cursor.pageCountLabel, '1');
    });

    test('learning the real page count keeps the page inside it', () {
      final cursor = ManualViewerCursor(pageCount: 50, page: 40);

      expect(cursor.setPageCount(12), isTrue);
      expect(cursor.pageCount, 12);
      expect(cursor.page, 12);
      expect(cursor.setPageCount(12), isFalse);
    });

    test('an out-of-range start page is clamped, not accepted', () {
      expect(ManualViewerCursor(pageCount: 5, page: 99).page, 5);
      expect(ManualViewerCursor(pageCount: 5, page: 0).page, 1);
    });

    test('setPage reports whether it actually moved', () {
      final cursor = ManualViewerCursor(pageCount: 10, page: 4);
      expect(cursor.setPage(4), isFalse);
      expect(cursor.setPage(7), isTrue);
      expect(cursor.page, 7);
    });
  });

  group('zoom', () {
    test('cycles the steps and wraps back to fit-to-page', () {
      final cursor = ManualViewerCursor();
      expect(cursor.zoom, ManualViewerCursor.zoomSteps.first);

      for (var i = 1; i < ManualViewerCursor.zoomSteps.length; i++) {
        expect(cursor.cycleZoom(), ManualViewerCursor.zoomSteps[i]);
      }
      expect(cursor.cycleZoom(), ManualViewerCursor.zoomSteps.first);
    });

    test('resetZoom is a no-op at fit-to-page', () {
      final cursor = ManualViewerCursor();
      expect(cursor.resetZoom(), isFalse);
      cursor.cycleZoom();
      expect(cursor.resetZoom(), isTrue);
      expect(cursor.zoom, ManualViewerCursor.zoomSteps.first);
    });
  });

  group('pan', () {
    test('a page that fits has nothing to pan', () {
      final cursor = ManualViewerCursor();
      expect(cursor.canPan, isFalse);
      expect(
        cursor.panStep(
          ManualPanDirection.right,
          viewWidth: 400,
          viewHeight: 300,
        ),
        isNull,
      );
    });

    test('a magnified page pans a quarter of the viewport per press', () {
      final cursor = ManualViewerCursor()..cycleZoom();
      expect(cursor.canPan, isTrue);

      expect(
        cursor.panStep(
          ManualPanDirection.right,
          viewWidth: 400,
          viewHeight: 300,
        ),
        (100.0, 0.0),
      );
      expect(
        cursor.panStep(
          ManualPanDirection.left,
          viewWidth: 400,
          viewHeight: 300,
        ),
        (-100.0, 0.0),
      );
      expect(
        cursor.panStep(
          ManualPanDirection.down,
          viewWidth: 400,
          viewHeight: 300,
        ),
        (0.0, 75.0),
      );
      expect(
        cursor.panStep(ManualPanDirection.up, viewWidth: 400, viewHeight: 300),
        (0.0, -75.0),
      );
    });
  });
}
