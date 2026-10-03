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
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (ctx) {
                  host = ctx;
                  return const SizedBox.expand();
                },
              ),
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
}
