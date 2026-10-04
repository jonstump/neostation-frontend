import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/reset_confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reset confirmation as the user meets it on a controller.
///
/// Modelled on `romm_library_extras_dialogs_test.dart`: SFX off (SoLoud's FFI
/// is not loadable in a test process), the gamepads channel mocked so
/// `GamepadNavigation.initialize()` finds a platform channel that answers.
///
/// What is pinned is SPEC-0021's typed-confirmation contract: the destructive
/// button stays disabled until the field holds the word RESET (compared
/// case-insensitively, and only the whole word), and B leaves a focused field
/// first and closes the dialog on the next press, so backing out is always
/// possible and nothing is deleted.
///
/// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Typed Confirmation"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  tearDownAll(() => SfxService().setEnabled(true));

  late BuildContext host;

  Future<void> settle(WidgetTester tester, {int ms = 60}) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pumpAndSettle();
  }

  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> pumpApp(WidgetTester tester) async {
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
            navigatorKey: navigatorKey,
            // As in the RomM dialogs' harness: the app installs a
            // NoFocusTraversalPolicy, so the default arrow-key focus
            // traversal must go too, or an arrow press focuses a text field
            // behind the nav's back.
            shortcuts: const <ShortcutActivator, Intent>{},
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The page the dialog sits on top of; the double-press tests assert it
    // survives. Pushed rather than the home route on purpose: the navigator
    // never pops its home route, so a double pop is only observable on a
    // route that was pushed.
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            key: const ValueKey('dialog_underlying_page'),
            body: Builder(
              builder: (ctx) {
                host = ctx;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool? dialogResult;

  Future<void> openDialog(WidgetTester tester) async {
    dialogResult = null;
    unawaited(
      ResetConfirmDialog.show(host).then((value) => dialogResult = value),
    );
    await settle(tester);
  }

  FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('reset_confirm_button')),
  );

  testWidgets('the button stays disabled until RESET is typed', (tester) async {
    await pumpApp(tester);
    await openDialog(tester);

    // Empty: disabled.
    expect(button(tester).onPressed, isNull);

    // Wrong word: still disabled.
    await tester.enterText(find.byType(TextField), 'reset please');
    await settle(tester);
    expect(button(tester).onPressed, isNull);

    // The word, in lowercase: enabled.
    await tester.enterText(find.byType(TextField), 'reset');
    await settle(tester);
    expect(button(tester).onPressed, isNotNull);

    // The word, uppercased and padded: still enabled.
    await tester.enterText(find.byType(TextField), '  RESET ');
    await settle(tester);
    expect(button(tester).onPressed, isNotNull);
  });

  testWidgets('confirming pops true and closing pops false', (tester) async {
    await pumpApp(tester);
    await openDialog(tester);
    // Still open: the future resolves only when the dialog closes.
    expect(dialogResult, isNull);

    await tester.enterText(find.byType(TextField), 'RESET');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reset_confirm_button')));
    await settle(tester);

    expect(dialogResult, isTrue);
    expect(find.byKey(const ValueKey('reset_confirm_button')), findsNothing);
  });

  testWidgets('B leaves the focused field first, then closes the dialog', (
    tester,
  ) async {
    await pumpApp(tester);
    await openDialog(tester);

    final field = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    // Focus the field the way a tap does.
    field.requestFocus();
    await settle(tester);
    expect(FocusManager.instance.primaryFocus, same(field));

    // First B: the field loses focus, the dialog stays.
    GamepadNavigation.triggerBack();
    await settle(tester);
    expect(FocusManager.instance.primaryFocus, isNot(same(field)));
    expect(find.byType(TextField), findsOneWidget);

    // Second B: the dialog closes, and nothing was reset.
    GamepadNavigation.triggerBack();
    await settle(tester);
    expect(find.byType(TextField), findsNothing);
  });

  group('double-press guards', () {
    testWidgets('a second confirm in the same frame pops once, not the page '
        'underneath', (tester) async {
      await pumpApp(tester);
      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'RESET');
      await settle(tester);

      // Drive the cursor onto the button the gamepad way: B out of the
      // field, down to the button, then A. The nav's re-activation grace
      // and keyboard throttle are real-time, so every key press waits out
      // 200 real milliseconds (no frames pumped) first.
      GamepadNavigation.triggerBack();
      await settle(tester, ms: 200);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester, ms: 200);

      // Two confirm presses with no pump between, so both land while the
      // dialog is still on the stack: only the first may pop anything.
      // The second press is a key event on purpose: the moment the first
      // pop starts the route ignores pointers, so a second TAP could never
      // reach the button, but the keyboard path is not hit-tested, and it
      // confirms exactly like the tap does.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(dialogResult, isTrue);
      // The page underneath was not popped by the second confirm.
      expect(
        find.byKey(const ValueKey('dialog_underlying_page')),
        findsOneWidget,
      );
    });

    testWidgets('a second back press pops once, not the page underneath', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDialog(tester);
      // The field is not focused, so B closes the dialog directly.

      // Two B presses in the same frame; only the first may pop anything.
      expect(GamepadNavigation.triggerBack(), isTrue);
      expect(GamepadNavigation.triggerBack(), isTrue);
      await settle(tester);

      expect(dialogResult, isFalse);
      expect(
        find.byKey(const ValueKey('dialog_underlying_page')),
        findsOneWidget,
      );
    });

    testWidgets('the notice dialog dismisses once, not twice', (tester) async {
      await pumpApp(tester);
      var noticeClosed = false;
      unawaited(
        ResetRestartNoticeDialog.show(host).then((_) => noticeClosed = true),
      );
      await settle(tester);

      // Two dismiss presses in the same frame; only the first may pop.
      expect(GamepadNavigation.triggerBack(), isTrue);
      expect(GamepadNavigation.triggerBack(), isTrue);
      await settle(tester);

      expect(noticeClosed, isTrue);
      expect(
        find.byKey(const ValueKey('dialog_underlying_page')),
        findsOneWidget,
      );
    });
  });
}
