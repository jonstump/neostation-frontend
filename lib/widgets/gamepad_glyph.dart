import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../services/gamepad/glyph_service.dart';
import '../utils/gamepad_action.dart';
import 'positional_diamond_painter.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Actions Not Buttons"

/// A single button hint drawn from the active glyph style.
///
/// The screen says what it does ([action]); the [GlyphService] resolves it to
/// an asset path or a positional slot for the active style, and this widget
/// draws that. It rebuilds when the service notifies — a pin or a
/// detected-style change redraws an already-mounted hint without recreating
/// it (SPEC-0022 REQ "Auto Style With A Pin").
///
/// Resolution is synchronous and does no I/O, no async, no `FutureBuilder`
/// (SPEC-0022 REQ "Concurrency Safety"). The spoken name is not shown yet: it
/// is an English-only constant until the slice that localizes it, so the
/// subtree is wrapped in [ExcludeSemantics] and the label comes with that
/// slice (SPEC-0022 REQ "Text Follows The Style").
///
/// This file deliberately does not name the gamepad asset folder: only
/// `GlyphService` may (SPEC-0022 REQ "Actions Not Buttons"). The path comes
/// from [GlyphResolution.assetPath], never from a literal here.
class GamepadGlyph extends StatelessWidget {
  const GamepadGlyph(
    this.action, {
    super.key,
    this.size,
    this.color,
    this.service,
  });

  /// Which action this hint is for.
  final GamepadAction action;

  /// Square side; defaults to what `GamepadControl` uses (`18.r`).
  final double? size;

  /// Tint; defaults to the theme's `colorScheme.onSurface`.
  final Color? color;

  /// The service to resolve through; defaults to [GlyphService.instance].
  /// A constructor argument so tests can inject one, not a production seam.
  final GlyphService? service;

  @override
  Widget build(BuildContext context) {
    final svc = service ?? GlyphService.instance;
    final dimension = size ?? 18.r;
    final tint = color ?? Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      // The spoken name is English-only until the localization slice; no
      // semantic label is exposed yet. The label comes with that slice
      // (SPEC-0022 REQ "Text Follows The Style").
      child: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          final resolution = svc.resolve(action);
          return SizedBox(
            width: dimension,
            height: dimension,
            child: resolution.assetPath != null
                ? Image.asset(
                    resolution.assetPath!,
                    width: dimension,
                    height: dimension,
                    color: tint,
                    colorBlendMode: BlendMode.srcIn,
                  )
                : CustomPaint(
                    size: Size.square(dimension),
                    painter: PositionalDiamondPainter(
                      slot: resolution.slot!,
                      litColor: tint,
                      dimColor: tint.withValues(alpha: 0.45),
                    ),
                  ),
          );
        },
      ),
    );
  }
}
