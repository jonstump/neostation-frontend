import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_rom_filters.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/romm_filter_menu_dialog.dart';
import 'package:neostation/widgets/romm_maintenance_menu_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two SPEC-0018 menus as the user meets them on a controller.
///
/// Modelled on `romm_firmware_panel_test.dart`: SFX off (SoLoud's FFI is not
/// loadable in a test process), the gamepads channel mocked so
/// `GamepadNavigation.initialize()` finds a platform channel that answers, and
/// Flutter's default shortcuts stripped so Enter reaches the navigator rather
/// than activating a focused widget.
///
/// What is pinned is the gamepad contract both dialogs owe: every row reachable
/// with the D-pad rather than only a tap, A doing the row's thing, B closing,
/// the layer taken from whatever is below and handed back on dispose — and, for
/// the filter menu, that a look-and-leave returns null so the grid is not
/// re-paged for nothing.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Filter Menu And Chips", REQ "Maintenance Tasks"
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
            // As in the firmware panel's harness: the app installs a
            // NoFocusTraversalPolicy, so nothing is ever focused and Enter must
            // not activate a focused widget behind the navigator's back.
            shortcuts: const <ShortcutActivator, Intent>{},
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

  /// The navigator ignores input for 150 ms after a reactivation, so every
  /// press waits that out first.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await settle(tester, ms: 200);
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  group('filter menu', () {
    testWidgets('every filter has a row and A ticks the focused one', (
      tester,
    ) async {
      await pumpApp(tester);
      RommRomFilters? result;
      var done = false;
      unawaited(
        RommFilterMenuDialog.show(host, filters: RommRomFilters.none).then((
          value,
        ) {
          result = value;
          done = true;
        }),
      );
      await settle(tester);

      for (final filter in RommRomFilter.values) {
        expect(
          find.text(RommFilterMenuDialog.labelKeyFor(filter).getString(host)),
          findsOneWidget,
          reason: '${filter.name} has no row',
        );
      }

      // Down twice, then A: the third filter is ticked and nothing else is.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);

      expect(done, isTrue);
      expect(result, isNotNull);
      expect(result!.active, [RommRomFilter.values[2]]);
    });

    testWidgets('B with nothing changed returns null', (tester) async {
      await pumpApp(tester);
      Object? result = 'unset';
      unawaited(
        RommFilterMenuDialog.show(
          host,
          filters: const RommRomFilters(hasSaves: true),
        ).then((value) => result = value),
      );
      await settle(tester);
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);
      expect(result, isNull);
    });

    testWidgets('toggling a filter off hands back the emptied set', (
      tester,
    ) async {
      await pumpApp(tester);
      RommRomFilters? result;
      unawaited(
        RommFilterMenuDialog.show(
          host,
          filters: const RommRomFilters(favorite: true),
        ).then((value) => result = value),
      );
      await settle(tester);
      // The cursor opens on the first row, which is `favorite`.
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);
      expect(result, RommRomFilters.none);
    });

    // The chip row's "Clear filters" chip is a tap target; this row is its
    // D-pad twin, so a controller user reaches the same outcome in one press.
    // Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips"
    testWidgets('"Clear all" is a D-pad row that unticks everything', (
      tester,
    ) async {
      await pumpApp(tester);
      RommRomFilters? result;
      unawaited(
        RommFilterMenuDialog.show(
          host,
          filters: const RommRomFilters(favorite: true, hasRa: true),
        ).then((value) => result = value),
      );
      await settle(tester);
      expect(
        find.text(AppLocale.rommFilterClearAll.getString(host)),
        findsOneWidget,
        reason: 'the menu has no "Clear all" row',
      );

      // Up from the first row wraps onto the last one, which is "Clear all".
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.enter);
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);
      expect(result, RommRomFilters.none);
    });

    testWidgets('takes the controller from below and hands it back', (
      tester,
    ) async {
      await pumpApp(tester);
      final events = <String>[];
      GamepadNavigationManager.pushLayer(
        'test_below_filter_menu',
        onActivate: () => events.add('+below'),
        onDeactivate: () => events.add('-below'),
      );
      addTearDown(
        () => GamepadNavigationManager.popLayer('test_below_filter_menu'),
      );
      events.clear();

      unawaited(RommFilterMenuDialog.show(host, filters: RommRomFilters.none));
      await settle(tester);
      expect(
        events,
        contains('-below'),
        reason: 'the menu did not take the controller from the layer below',
      );

      events.clear();
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);
      expect(
        events,
        contains('+below'),
        reason: 'the layer below was not woken when the menu closed',
      );
    });
  });

  group('maintenance menu', () {
    testWidgets('offers exactly the three tasks', (tester) async {
      await pumpApp(tester);
      unawaited(RommMaintenanceMenuDialog.show(host));
      await settle(tester);
      for (final task in RommMaintenanceTask.values) {
        expect(
          find.text(task.labelKey.getString(host)),
          findsOneWidget,
          reason: '${task.taskName} has no row',
        );
      }
      await press(tester, LogicalKeyboardKey.backspace);
    });

    testWidgets('A on a row picked with the D-pad returns that task', (
      tester,
    ) async {
      await pumpApp(tester);
      RommMaintenanceTask? picked;
      unawaited(
        RommMaintenanceMenuDialog.show(host).then((value) => picked = value),
      );
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);
      await settle(tester);
      expect(picked, RommMaintenanceTask.syncFolderScan);
      expect(picked!.taskName, 'sync_folder_scan');
    });

    testWidgets('B cancels without picking anything', (tester) async {
      await pumpApp(tester);
      Object? picked = 'unset';
      unawaited(
        RommMaintenanceMenuDialog.show(host).then((value) => picked = value),
      );
      await settle(tester);
      await press(tester, LogicalKeyboardKey.backspace);
      await settle(tester);
      expect(picked, isNull);
    });

    testWidgets('the task names are RomM\'s registry names', (tester) async {
      // Wire contract, not UI: a typo here is a 404 the user reads as
      // "the task could not be started".
      expect(RommMaintenanceTask.values.map((t) => t.taskName), [
        'scan_library',
        'sync_folder_scan',
        'cleanup_missing_roms',
      ]);
    });
  });
}
