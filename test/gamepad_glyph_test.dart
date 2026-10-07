import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/glyph_service.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/utils/gamepad_action.dart';
import 'package:neostation/widgets/gamepad_glyph.dart';
import 'package:neostation/widgets/positional_diamond_painter.dart';

/// The GamepadGlyph widget: draws the asset or the positional diamond the
/// service resolves for the active style, tints it, excludes semantics, and
/// redraws on a service notification without being recreated.
///
/// Literal expected values only; nothing is read from the service's tables.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Actions Not Buttons"
void main() {
  const assetByAction = <GamepadAction, String>{
    GamepadAction.confirm: 'assets/images/gamepad/Xbox_A_button.png',
    GamepadAction.back: 'assets/images/gamepad/Xbox_B_button.png',
    GamepadAction.start: 'assets/images/gamepad/Xbox_Menu_button.png',
    GamepadAction.leftStick: 'assets/images/gamepad/Left Stick.png',
  };

  Future<({GlyphService svc, List<String> warnings})> pumpWith(
    WidgetTester tester, {
    required GamepadAction action,
    GlyphStyle detected = GlyphStyle.xbox,
    GlyphStyle? pinned,
    double? size,
    Color? color,
    GlyphService? service,
    ThemeMode themeMode = ThemeMode.dark,
  }) async {
    final warnings = <String>[];
    final svc =
        service ??
        GlyphService(
          detected: detected,
          pinned: pinned,
          onWarning: warnings.add,
        );
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1280, 720)),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, child) => MaterialApp(
            theme: ThemeData(
              brightness: themeMode == ThemeMode.dark
                  ? Brightness.dark
                  : Brightness.light,
              colorScheme: const ColorScheme.dark().copyWith(
                onSurface: const Color(0xFF112233),
              ),
            ),
            home: Scaffold(
              body: Center(
                child: GamepadGlyph(
                  action,
                  size: size,
                  color: color,
                  service: svc,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (svc: svc, warnings: warnings);
  }

  group('xbox', () {
    testWidgets('confirm draws the A asset at the default size', (
      tester,
    ) async {
      await pumpWith(tester, action: GamepadAction.confirm);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect(
        (image.image as AssetImage).assetName,
        assetByAction[GamepadAction.confirm],
      );
      expect(image.width, 18.r);
      expect(image.height, 18.r);
    });

    testWidgets('start and leftStick draw their literal assets', (
      tester,
    ) async {
      for (final action in [GamepadAction.start, GamepadAction.leftStick]) {
        await pumpWith(tester, action: action);
        final image = tester.widget<Image>(find.byType(Image));
        expect(
          (image.image as AssetImage).assetName,
          assetByAction[action],
          reason: action.name,
        );
      }
    });

    testWidgets('a given size is honored', (tester) async {
      await pumpWith(tester, action: GamepadAction.confirm, size: 30);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 30);
      expect(image.height, 30);
    });
  });

  group('tint', () {
    testWidgets('default tint is the theme onSurface', (tester) async {
      await pumpWith(tester, action: GamepadAction.confirm);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, const Color(0xFF112233));
      expect(image.colorBlendMode, BlendMode.srcIn);
    });

    testWidgets('a given color is used', (tester) async {
      const tint = Color(0xFFAA00BB);
      await pumpWith(tester, action: GamepadAction.confirm, color: tint);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, tint);
    });
  });

  group('positional', () {
    testWidgets('the four face actions light their slots, no image', (
      tester,
    ) async {
      final slots = {
        GamepadAction.confirm: GlyphSlot.right,
        GamepadAction.back: GlyphSlot.bottom,
        GamepadAction.context: GlyphSlot.top,
        GamepadAction.favourite: GlyphSlot.left,
      };
      for (final entry in slots.entries) {
        await pumpWith(
          tester,
          action: entry.key,
          detected: GlyphStyle.positional,
        );
        expect(find.byType(Image), findsNothing, reason: entry.key.name);
        final painter =
            (tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (w) =>
                            w is CustomPaint &&
                            w.painter is PositionalDiamondPainter,
                      ),
                    )
                    .painter
                as PositionalDiamondPainter);
        expect(painter.slot, entry.value, reason: entry.key.name);
      }
    });

    testWidgets('a non-face action falls back to the Xbox asset, warned once', (
      tester,
    ) async {
      final result = await pumpWith(
        tester,
        action: GamepadAction.start,
        detected: GlyphStyle.positional,
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        assetByAction[GamepadAction.start],
      );
      expect(result.warnings, hasLength(1));
      // Building again (a second resolve) records no second warning.
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(result.warnings, hasLength(1));
    });

    testWidgets('the positional painter uses the tint and its dim alpha', (
      tester,
    ) async {
      const tint = Color(0xFF778899);
      await pumpWith(
        tester,
        action: GamepadAction.back,
        detected: GlyphStyle.positional,
        color: tint,
      );
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is CustomPaint &&
                          w.painter is PositionalDiamondPainter,
                    ),
                  )
                  .painter
              as PositionalDiamondPainter;
      expect(painter.litColor, tint);
      expect(painter.dimColor, tint.withValues(alpha: 0.45));
    });
  });

  group('nintendo (falls back until #275)', () {
    testWidgets('the Xbox glyph is drawn', (tester) async {
      await pumpWith(
        tester,
        action: GamepadAction.confirm,
        detected: GlyphStyle.nintendo,
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        assetByAction[GamepadAction.confirm],
      );
    });
  });

  group('redraw without recreate', () {
    testWidgets('a pin change redraws the same element, no recreate', (
      tester,
    ) async {
      final result = await pumpWith(tester, action: GamepadAction.back);
      final svc = result.svc;
      final glyphElement = tester.element(find.byType(GamepadGlyph));
      expect(find.byType(Image), findsOneWidget);

      svc.setPinned(GlyphStyle.positional);
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
        ),
        findsOneWidget,
      );
      // Same element: not recreated.
      expect(
        identical(tester.element(find.byType(GamepadGlyph)), glyphElement),
        isTrue,
      );

      svc.setPinned(null);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
        ),
        findsNothing,
      );
    });

    testWidgets('setDetected changes the glyph when nothing is pinned', (
      tester,
    ) async {
      final result = await pumpWith(tester, action: GamepadAction.back);
      final svc = result.svc;
      expect(find.byType(Image), findsOneWidget);

      svc.setDetected(GlyphStyle.positional);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
        ),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
    });

    testWidgets(
      'setDetected does NOT change the glyph while a style is pinned',
      (tester) async {
        final result = await pumpWith(
          tester,
          action: GamepadAction.back,
          pinned: GlyphStyle.xbox,
        );
        final svc = result.svc;
        expect(find.byType(Image), findsOneWidget);

        svc.setDetected(GlyphStyle.positional);
        await tester.pump();
        // Pinned xbox wins: still the image, no painter.
        expect(find.byType(Image), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
          ),
          findsNothing,
        );
      },
    );
  });

  group('default service', () {
    testWidgets('the singleton drives the widget', (tester) async {
      // Use the real app-wide instance; reset in tearDown.
      GlyphService.instance.setPinned(GlyphStyle.positional);
      addTearDown(() {
        GlyphService.instance.setPinned(null);
        GlyphService.instance.setDetected(GlyphStyle.xbox);
      });

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1280, 720)),
          child: ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (context, child) => MaterialApp(
              home: Scaffold(
                body: Center(child: GamepadGlyph(GamepadAction.back)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is PositionalDiamondPainter,
        ),
        findsOneWidget,
      );
    });
  });

  group('source guards', () {
    test('no asset path literal in the widget files', () {
      final widget = File('lib/widgets/gamepad_glyph.dart').readAsStringSync();
      final painter = File(
        'lib/widgets/positional_diamond_painter.dart',
      ).readAsStringSync();
      expect(widget, isNot(contains('assets/images/gamepad/')));
      expect(painter, isNot(contains('assets/images/gamepad/')));
    });

    test('the painter draws no text of any kind', () {
      final painter = File(
        'lib/widgets/positional_diamond_painter.dart',
      ).readAsStringSync();
      expect(painter, isNot(contains('TextPainter')));
      expect(painter, isNot(contains('Paragraph')));
      expect(painter, isNot(contains('drawParagraph')));
    });
  });

  group('semantics', () {
    testWidgets('the subtree is wrapped in ExcludeSemantics', (tester) async {
      await pumpWith(tester, action: GamepadAction.confirm);
      // The widget itself is the ancestor of an ExcludeSemantics (the
      // framework adds its own elsewhere; what matters is the glyph mutes
      // its subtree).
      expect(
        find.ancestor(
          of: find.byType(ExcludeSemantics),
          matching: find.byType(GamepadGlyph),
        ),
        findsOneWidget,
      );
    });
  });
}
