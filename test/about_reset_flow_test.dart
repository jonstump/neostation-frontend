import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/about_settings_content.dart';
import 'package:neostation/services/reset_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/reset_confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The About reset row end to end with fakes: confirm, reset, relaunch, exit.
///
/// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Typed Confirmation",
/// REQ "Order And Resilience", REQ "Relaunch"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = GlobalKey<AboutSettingsContentState>();
  late List<String> calls;
  late List<int> exits;
  late Completer<ResetSummary> resetGate;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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

  setUp(() {
    SfxService().setEnabled(false);
    calls = [];
    exits = [];
    resetGate = Completer<ResetSummary>();
    AboutSettingsContentState.resetRunner = () {
      calls.add('reset');
      return resetGate.future;
    };
    AboutSettingsContentState.relaunchRunner = () async {
      calls.add('relaunch');
      return true;
    };
    AboutSettingsContentState.exitRunner = exits.add;
    AboutSettingsContentState.relaunchGrace = const Duration(milliseconds: 300);
  });

  tearDown(() => SfxService().setEnabled(true));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpAbout(
    WidgetTester tester, {
    bool focused = false,
    int index = 0,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: AboutSettingsContent(
                key: key,
                isContentFocused: focused,
                selectedContentIndex: index,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> confirmReset(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'RESET');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reset_confirm_button')));
    await settle(tester);
  }

  testWidgets('the last navigable index opens the reset confirmation', (
    tester,
  ) async {
    await pumpAbout(tester, focused: true, index: 6);
    final last = key.currentState!.getItemCount() - 1;
    expect(last, 6);

    key.currentState!.selectItem(last);
    await settle(tester);

    expect(find.byType(ResetConfirmDialog), findsOneWidget);
  });

  testWidgets('confirm, reset, relaunch, then exit after the grace period', (
    tester,
  ) async {
    await pumpAbout(tester);
    key.currentState!.selectItem(6);
    await settle(tester);

    await confirmReset(tester);
    // Reset is running: busy overlay up, a second trigger is ignored.
    expect(calls, ['reset']);
    expect(find.byKey(const ValueKey('reset_in_progress')), findsOneWidget);
    key.currentState!.selectItem(6);
    await settle(tester);
    expect(find.byType(ResetConfirmDialog), findsNothing);
    expect(calls, ['reset']);

    resetGate.complete(ResetSummary()..cleared.add('credentials'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, ['reset', 'relaunch']);
    expect(exits, isEmpty, reason: 'exit waits for the grace period');

    await tester.pump(const Duration(milliseconds: 300));
    expect(exits, [0]);
  });

  testWidgets('failures are listed in a notice before the relaunch', (
    tester,
  ) async {
    await pumpAbout(tester);
    key.currentState!.selectItem(6);
    await settle(tester);
    await confirmReset(tester);

    resetGate.complete(ResetSummary()..failed['media cache'] = 'locked file');
    await settle(tester);

    expect(find.byType(ResetRestartNoticeDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reset_failure_media cache')),
      findsOneWidget,
    );
    expect(find.textContaining('locked file'), findsOneWidget);
    expect(calls, ['reset'], reason: 'relaunch waits for the notice');

    await tester.tap(find.byType(TextButton));
    await settle(tester);
    expect(calls, ['reset', 'relaunch']);
    await tester.pump(const Duration(milliseconds: 400));
    expect(exits, [0]);
  });

  testWidgets('a refused relaunch shows the notice first, then exits', (
    tester,
  ) async {
    AboutSettingsContentState.relaunchRunner = () async {
      calls.add('relaunch');
      return false;
    };
    await pumpAbout(tester);
    key.currentState!.selectItem(6);
    await settle(tester);
    await confirmReset(tester);

    resetGate.complete(ResetSummary());
    await settle(tester);

    expect(find.byType(ResetRestartNoticeDialog), findsOneWidget);
    expect(exits, isEmpty);

    await tester.tap(find.byType(TextButton));
    await settle(tester);
    expect(exits, [0]);
  });
}
