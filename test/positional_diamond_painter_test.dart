import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/widgets/positional_diamond_painter.dart';

/// The positional diamond: one filled circle at the lit slot, three stroked
/// outlines at the others, no letters. Asserted against an exact paint
/// sequence on a 100×100 canvas so the centre fractions and radius are plain
/// integers.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"
void main() {
  const lit = Color(0xFFFFFFFF);
  const dim = Color.fromARGB(115, 255, 255, 255);
  const canvasSize = Size(100, 100);

  // Centres and sizes derived from the fractions the painter is specified to
  // use, on a 100×100 canvas: radius 0.16*100=16, stroke 0.06*100=6.
  const top = Offset(50, 18);
  const bottom = Offset(50, 82);
  const left = Offset(18, 50);
  const right = Offset(82, 50);
  const radius = 16.0;
  const strokeWidth = 6.0;

  // The painter draws top, bottom, left, right in that order; whichever slot
  // is lit is filled, the rest are stroked. Build the expected paint sequence
  // for [slot] as a cascade on `paints`.
  PaintPattern seq(GlyphSlot slot) {
    final entries = [
      (GlyphSlot.top, top),
      (GlyphSlot.bottom, bottom),
      (GlyphSlot.left, left),
      (GlyphSlot.right, right),
    ];
    return paints
      ..circle(
        x: entries[0].$2.dx,
        y: entries[0].$2.dy,
        radius: radius,
        color: entries[0].$1 == slot ? lit : dim,
        style: entries[0].$1 == slot
            ? PaintingStyle.fill
            : PaintingStyle.stroke,
        strokeWidth: entries[0].$1 == slot ? null : strokeWidth,
      )
      ..circle(
        x: entries[1].$2.dx,
        y: entries[1].$2.dy,
        radius: radius,
        color: entries[1].$1 == slot ? lit : dim,
        style: entries[1].$1 == slot
            ? PaintingStyle.fill
            : PaintingStyle.stroke,
        strokeWidth: entries[1].$1 == slot ? null : strokeWidth,
      )
      ..circle(
        x: entries[2].$2.dx,
        y: entries[2].$2.dy,
        radius: radius,
        color: entries[2].$1 == slot ? lit : dim,
        style: entries[2].$1 == slot
            ? PaintingStyle.fill
            : PaintingStyle.stroke,
        strokeWidth: entries[2].$1 == slot ? null : strokeWidth,
      )
      ..circle(
        x: entries[3].$2.dx,
        y: entries[3].$2.dy,
        radius: radius,
        color: entries[3].$1 == slot ? lit : dim,
        style: entries[3].$1 == slot
            ? PaintingStyle.fill
            : PaintingStyle.stroke,
        strokeWidth: entries[3].$1 == slot ? null : strokeWidth,
      );
  }

  Widget pump(GlyphSlot slot) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: CustomPaint(
          size: canvasSize,
          painter: PositionalDiamondPainter(
            slot: slot,
            litColor: lit,
            dimColor: dim,
          ),
        ),
      ),
    ),
  );

  for (final slot in GlyphSlot.values) {
    testWidgets('slot $slot paints one filled and three stroked circles', (
      tester,
    ) async {
      await tester.pumpWidget(pump(slot));
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
        ),
        seq(slot),
      );
    });
  }

  group('shouldRepaint', () {
    const p = PositionalDiamondPainter(
      slot: GlyphSlot.bottom,
      litColor: lit,
      dimColor: dim,
    );

    test('false for an equal painter', () {
      const other = PositionalDiamondPainter(
        slot: GlyphSlot.bottom,
        litColor: lit,
        dimColor: dim,
      );
      expect(p.shouldRepaint(other), isFalse);
    });

    test('true when the slot differs', () {
      const other = PositionalDiamondPainter(
        slot: GlyphSlot.top,
        litColor: lit,
        dimColor: dim,
      );
      expect(p.shouldRepaint(other), isTrue);
    });

    test('true when the lit color differs', () {
      const other = PositionalDiamondPainter(
        slot: GlyphSlot.bottom,
        litColor: Color(0xFF000000),
        dimColor: dim,
      );
      expect(p.shouldRepaint(other), isTrue);
    });

    test('true when the dim color differs', () {
      const other = PositionalDiamondPainter(
        slot: GlyphSlot.bottom,
        litColor: lit,
        dimColor: Color(0x00000000),
      );
      expect(p.shouldRepaint(other), isTrue);
    });
  });
}
