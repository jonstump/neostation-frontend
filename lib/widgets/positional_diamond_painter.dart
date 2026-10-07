import 'package:flutter/material.dart';

import '../services/gamepad/glyph_style.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"

/// Draws the four-position face-button diamond for the `positional` glyph
/// style: one filled circle at the lit position and three stroked outlines at
/// the others. No letters and no text of any kind (SPEC-0022 "Positional"):
/// the positions are the whole hint.
class PositionalDiamondPainter extends CustomPainter {
  const PositionalDiamondPainter({
    required this.slot,
    required this.litColor,
    required this.dimColor,
  });

  /// Which of the four positions is lit (the pressed one).
  final GlyphSlot slot;

  /// Fill colour for the lit circle.
  final Color litColor;

  /// Stroke colour for the three unlit circles.
  final Color dimColor;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = 0.16 * size.shortestSide;
    final strokeWidth = 0.06 * size.shortestSide;

    final top = Offset(0.5 * size.width, 0.18 * size.height);
    final bottom = Offset(0.5 * size.width, 0.82 * size.height);
    final left = Offset(0.18 * size.width, 0.5 * size.height);
    final right = Offset(0.82 * size.width, 0.5 * size.height);

    final dim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = dimColor;
    final lit = Paint()
      ..style = PaintingStyle.fill
      ..color = litColor;

    // Drawn in diamond order so the lit one is not always first; the order is
    // not observable to a caller, only that exactly one is filled.
    for (final entry in <MapEntry<GlyphSlot, Offset>>[
      MapEntry(GlyphSlot.top, top),
      MapEntry(GlyphSlot.bottom, bottom),
      MapEntry(GlyphSlot.left, left),
      MapEntry(GlyphSlot.right, right),
    ]) {
      canvas.drawCircle(entry.value, radius, entry.key == slot ? lit : dim);
    }
  }

  @override
  bool shouldRepaint(covariant PositionalDiamondPainter oldDelegate) =>
      slot != oldDelegate.slot ||
      litColor != oldDelegate.litColor ||
      dimColor != oldDelegate.dimColor;
}
