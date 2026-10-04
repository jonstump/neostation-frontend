import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/about_settings_content.dart';
import 'package:neostation/services/relaunch_service.dart';
import 'package:neostation/services/reset_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/reset_confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts navigator pops, so tests can assert that nothing was popped.
class _CountingObserver extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route route, Route? previousRoute) => pops++;
}

/// The About reset row end to end with fakes: confirm, reset, relaunch, exit.
///
/// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Typed Confirmation",
/// REQ "Order And Resilience", REQ "Relaunch"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = GlobalKey<AboutSettingsContentState>();
  final navigatorKey = GlobalKey<NavigatorState>();
  final observer = _CountingObserver();
  late List<String> calls;
  late List<int> exits;
  late Completer<ResetSummary> resetGate;
  late MaterialPageRoute<void> aboutRoute;

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
    observer.pops = 0;
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

  tearDown(() {
    // The fakes are statics; hand the production defaults back.
    AboutSettingsContentState.resetRunner = ResetService.resetAll;
    AboutSettingsContentState.relaunchRunner = RelaunchService.relaunch;
    AboutSettingsContentState.exitRunner = exit;
    AboutSettingsContentState.relaunchGrace = const Duration(milliseconds: 300);
    SfxService().setEnabled(true);
  });

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
            navigatorKey: navigatorKey,
            navigatorObservers: [observer],
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );
    await settle(tester);

    // The About screen is a pushed route, not the home, so "nothing was
    // popped" is observable: the navigator never pops its home route.
    aboutRoute = MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: AboutSettingsContent(
          key: key,
          isContentFocused: focused,
          selectedContentIndex: index,
        ),
      ),
    );
    unawaited(navigatorKey.currentState!.push(aboutRoute));
    await settle(tester);
  }

  /// Removes the About route without touching whatever sits on top of it.
  void removeAboutScreen() =>
      navigatorKey.currentState!.removeRoute(aboutRoute);

  /// Pumps until [done], bounding the wait: the busy overlay's spinner is an
  /// infinite animation, so `pumpAndSettle` can never be used while a reset
  /// is pending.
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 12 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
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

  group('guards', () {
    // Pins the three _isResetting checks together: this test fails only when
    // ALL of them are removed. The tests below pin the individual checks
    // where that is possible at all.
    testWidgets('a second trigger while the reset runs does not reset again', (
      tester,
    ) async {
      await pumpAbout(tester);
      key.currentState!.selectItem(6);
      await settle(tester);
      await confirmReset(tester);
      expect(calls, ['reset']);

      // A second trigger through the row's public entry points while the
      // fake reset is still pending. The busy overlay absorbs a tap on the
      // row itself; the direct selectItem call bypasses hit testing, which
      // is exactly the path the _isResetting guard exists for.
      final rowTitle = AppLocale.resetNeoStation.getString(key.currentContext!);
      await tester.tap(find.text(rowTitle), warnIfMissed: false);
      key.currentState!.selectItem(6);
      await settle(tester);

      // With the guard broken, a second confirm dialog opens on top; confirm
      // it so the second reset would actually start.
      if (find.byType(ResetConfirmDialog).evaluate().isNotEmpty) {
        await tester.enterText(find.byType(TextField).last, 'RESET');
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('reset_confirm_button')).last,
          warnIfMissed: false,
        );
        await settle(tester);
      }

      expect(calls, [
        'reset',
      ], reason: 'a second trigger must not start a second reset');
    });

    testWidgets(
      'the busy layer is on top while the reset runs and gone after',
      (tester) async {
        AboutSettingsContentState.relaunchRunner = () async {
          calls.add('relaunch');
          return false;
        };
        await pumpAbout(tester);
        key.currentState!.selectItem(6);
        await settle(tester);
        await confirmReset(tester);
        final popsAfterConfirm = observer.pops;

        // While the fake reset is still pending: the busy overlay is up, the
        // busy layer is the active top layer, and its no-op back swallows the
        // press without closing anything or starting anything. The no-new-pops
        // and still-mounted assertions are what make this a no-op contract:
        // an onBack that called Navigator.maybePop would pop the About route
        // and fail them.
        expect(find.byKey(const ValueKey('reset_in_progress')), findsOneWidget);
        expect(
          GamepadNavigation.triggerBack(),
          isTrue,
          reason: 'the busy layer is the active layer, swallowing back',
        );
        await settle(tester);
        expect(
          observer.pops,
          popsAfterConfirm,
          reason: 'back on the busy layer is a no-op',
        );
        expect(find.byType(AboutSettingsContent), findsOneWidget);
        key.currentState!.selectItem(6);
        await settle(tester);
        expect(calls, ['reset']);
        expect(find.byType(ResetRestartNoticeDialog), findsNothing);
        expect(find.byKey(const ValueKey('reset_in_progress')), findsOneWidget);

        resetGate.complete(ResetSummary());
        await settle(tester);
        expect(find.byType(ResetRestartNoticeDialog), findsOneWidget);
        await tester.tap(find.byType(TextButton));
        await settle(tester);
        expect(exits, [0]);

        // The busy layer was popped: nothing answers back anymore. The
        // manager's stack is private (no public inspector), so this is the
        // behavioural proof: with no active layer, triggerBack is false.
        expect(GamepadNavigation.triggerBack(), isFalse);
      },
    );

    testWidgets('re-triggering the row while the reset runs opens no second '
        'dialog', (tester) async {
      await pumpAbout(tester);
      key.currentState!.selectItem(6);
      await settle(tester);
      await confirmReset(tester);
      expect(calls, ['reset']);

      // Second trigger while the fake reset is still pending. Pins the entry
      // guards (selectItem's check and _resetNeoStation's first line) as a
      // pair: they are observationally identical, and this test fails only
      // when BOTH are gone, because the post-confirmation check still holds
      // the line after a second dialog is confirmed.
      final rowTitle = AppLocale.resetNeoStation.getString(key.currentContext!);
      await tester.tap(find.text(rowTitle), warnIfMissed: false);
      key.currentState!.selectItem(6);
      await settle(tester);

      expect(find.byType(ResetConfirmDialog), findsNothing);
      expect(calls, ['reset']);
    });

    testWidgets('two confirm dialogs opened back to back reset only once', (
      tester,
    ) async {
      await pumpAbout(tester);

      // Open the first dialog; while it is open the flag is still false, so
      // the entry checks let a second dialog stack on top.
      key.currentState!.selectItem(6);
      await settle(tester);
      key.currentState!.selectItem(6);
      await settle(tester);
      expect(find.byType(ResetConfirmDialog), findsNWidgets(2));

      // Confirm the FIRST dialog. It is covered by the second one, so a tap
      // cannot reach it; its own field is still focusable, and the IME done
      // action submits it without any hit testing.
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode!
          .requestFocus();
      await tester.enterText(find.byType(TextField).first, 'RESET');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      // The flag flipped true and the reset started; the second dialog is
      // now the only one left.
      expect(calls, ['reset']);
      expect(find.byType(ResetConfirmDialog), findsOneWidget);

      // Confirming the second must be refused by the post-confirmation
      // check alone — the entry checks already passed for this invocation.
      await confirmReset(tester);

      expect(calls, ['reset'], reason: 'the second dialog must not reset');
    });

    group('mounted early returns', () {
      testWidgets('unmounting mid-reset still relaunches and exits', (
        tester,
      ) async {
        await pumpAbout(tester);
        key.currentState!.selectItem(6);
        await settle(tester);
        await confirmReset(tester);

        // The user leaves the screen (navigation, theme change) while the
        // reset runs.
        navigatorKey.currentState!.pop();
        await pumpUntil(
          tester,
          () => find.byType(AboutSettingsContent).evaluate().isEmpty,
        );
        expect(find.byType(AboutSettingsContent), findsNothing);

        resetGate.complete(ResetSummary());
        await settle(tester);

        // Today's behavior: the reset state is global, so the relaunch and
        // the exit run anyway, and nothing throws. Two pops happened: the
        // confirm dialog and the About route.
        expect(observer.pops, 2);
        expect(calls, ['reset', 'relaunch']);
        await tester.pump(const Duration(milliseconds: 400));
        expect(exits, [0]);
        // dispose popped the busy layer: nothing answers back.
        expect(GamepadNavigation.triggerBack(), isFalse);
      });

      testWidgets(
        'unmounted mid-reset with failures: no failure notice, the app just '
        'exits (today\'s behavior)',
        (tester) async {
          await pumpAbout(tester);
          key.currentState!.selectItem(6);
          await settle(tester);
          await confirmReset(tester);

          navigatorKey.currentState!.pop();
          await pumpUntil(
            tester,
            () => find.byType(AboutSettingsContent).evaluate().isEmpty,
          );

          resetGate.complete(
            ResetSummary()..failed['media cache'] = 'locked file',
          );
          await settle(tester);

          // Today's behavior: the failure notice is behind `if (mounted)`, so
          // an unmounted screen means the user never learns the reset was
          // partial. The relaunch still runs and the process still exits.
          expect(find.byType(ResetRestartNoticeDialog), findsNothing);
          expect(calls, ['reset', 'relaunch']);
          await tester.pump(const Duration(milliseconds: 400));
          expect(exits, [0]);
        },
      );

      testWidgets(
        'unmounted before a refused relaunch: no notice, the app just exits '
        "(today's behavior)",
        (tester) async {
          AboutSettingsContentState.relaunchRunner = () async {
            calls.add('relaunch');
            return false;
          };
          await pumpAbout(tester);
          key.currentState!.selectItem(6);
          await settle(tester);
          await confirmReset(tester);

          navigatorKey.currentState!.pop();
          await pumpUntil(
            tester,
            () => find.byType(AboutSettingsContent).evaluate().isEmpty,
          );

          resetGate.complete(ResetSummary());
          await settle(tester);

          // Today's behavior: the refused-relaunch notice is behind
          // `if (mounted)`, so the user is not told to start the app again.
          expect(find.byType(ResetRestartNoticeDialog), findsNothing);
          expect(calls, ['reset', 'relaunch']);
          expect(exits, [0]);
        },
      );

      testWidgets('confirming after the screen was removed starts nothing', (
        tester,
      ) async {
        await pumpAbout(tester);
        key.currentState!.selectItem(6);
        await settle(tester);

        // The screen goes away while its confirm dialog is still open (the
        // dialog lives on the root navigator and survives).
        removeAboutScreen();
        await settle(tester);
        expect(find.byType(ResetConfirmDialog), findsOneWidget);

        await confirmReset(tester);

        // Today's behavior: the post-confirmation mounted check refuses the
        // reset, so nothing runs and nothing throws.
        expect(calls, isEmpty, reason: 'a disposed screen must not reset');
        expect(exits, isEmpty);
        expect(observer.pops, 1, reason: 'only the About route was removed');
      });
    });
  });
}
