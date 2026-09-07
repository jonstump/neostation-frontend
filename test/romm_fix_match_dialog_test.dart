import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_search_result.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_controller.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_dialog.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fix-up dialog as the user meets it on a controller.
///
/// `applyRomMatch` rewrites a library entry for every client of the server and
/// the replace-mode fetch behind it overwrites the local row, so what this
/// pins is the protection around that write: the confirmation names the game,
/// it starts on *Cancel* so the A press that opened it cannot write, and B
/// leaves without sending anything. It also covers the gamepad contract — the
/// rows are reachable with the D-pad rather than only a tap, and B pops the
/// dialog — and the "this server has no metadata source" wording.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Fix Match In The Picker", REQ "Error Handling Standards"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Navigation SFX go through SoLoud's FFI bindings, which are not loadable
    // in a test process.
    SfxService().setEnabled(false);
    // No gamepads: GamepadNavigation.initialize() must find a platform channel
    // that answers rather than a missing one that throws.
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
            // The app installs a NoFocusTraversalPolicy so nothing ever holds
            // focus; without stripping the default shortcuts the harness would
            // be more permissive than the app.
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

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await settle(tester, ms: 200);
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  RommFixCandidate candidate(String name) => RommFixCandidate(
    name: name,
    detail: 'igdb 123',
    match: RommSearchResult(providerIds: const {'igdb_id': 123}, name: name),
  );

  /// Opens the dialog on a real route so B can pop it, and hands back the
  /// counters the controller's seams write into.
  Future<({List<String> applied, List<int> refreshes, Completer<bool?> popped})>
  openDialog(
    WidgetTester tester, {
    Future<List<RommFixCandidate>> Function(String term)? search,
    Future<bool> Function(RommFixCandidate c)? apply,
    RommFixMode mode = RommFixMode.match,
  }) async {
    final applied = <String>[];
    final refreshes = <int>[];
    final popped = Completer<bool?>();

    final controller = RommFixMatchController(
      mode: mode,
      romId: 42,
      search:
          search ??
          (term) async => [
            candidate('Chrono Trigger'),
            candidate('Chrono Cross'),
          ],
      applyCandidate: (c) async {
        applied.add(c.name);
        return apply == null ? true : apply(c);
      },
      refreshLocal: () async => refreshes.add(1),
    );

    unawaited(
      RommFixMatchDialog.show(
        host,
        controller: controller,
        gameName: 'Chrono Trigger',
        imageHeaders: (_) => const {},
      ).then(popped.complete),
    );
    await settle(tester);
    return (applied: applied, refreshes: refreshes, popped: popped);
  }

  testWidgets('lists what the server answered for the prefilled name', (
    tester,
  ) async {
    await pumpApp(tester);
    await openDialog(tester);

    expect(find.text('Fix match on RomM'), findsOneWidget);
    expect(find.text('Chrono Cross'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Chrono Trigger',
    );
  });

  testWidgets(
    'the confirmation starts on Cancel, so a stray A writes nothing',
    (tester) async {
      await pumpApp(tester);
      final run = await openDialog(tester);

      // Down onto the first candidate, A to act on it.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      expect(find.text('Apply this match?'), findsOneWidget);
      // The confirmation names what will change.
      expect(
        find.textContaining('Chrono Trigger', findRichText: true),
        findsWidgets,
      );

      // A again — the press that a repeated or duplicated button event would
      // produce — takes the default, which is Cancel.
      await press(tester, LogicalKeyboardKey.enter);

      expect(find.text('Apply this match?'), findsNothing);
      expect(run.applied, isEmpty);
      expect(run.refreshes, isEmpty);
    },
  );

  testWidgets('moving to Apply and confirming writes once and refreshes once', (
    tester,
  ) async {
    await pumpApp(tester);
    final run = await openDialog(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.enter);

    expect(run.applied, ['Chrono Trigger']);
    expect(run.refreshes, hasLength(1));
    expect(await run.popped.future, isTrue);
  });

  testWidgets('B backs out of the confirmation and then out of the dialog', (
    tester,
  ) async {
    await pumpApp(tester);
    final run = await openDialog(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.backspace);

    expect(find.text('Apply this match?'), findsNothing);
    expect(find.text('Fix match on RomM'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.backspace);

    expect(await run.popped.future, isFalse);
    expect(run.applied, isEmpty);
  });

  testWidgets('a server with no provider says so instead of offering a retry', (
    tester,
  ) async {
    await pumpApp(tester);
    await openDialog(
      tester,
      search: (_) async => throw RommException(
        'RomM metadata search failed (/api/search/roms, 500)',
        statusCode: 500,
        kind: RommErrorKind.noMetadataSource,
      ),
    );

    expect(
      find.text('This RomM server has no metadata source enabled'),
      findsOneWidget,
    );
    expect(
      find.text('The RomM search failed — select to try again'),
      findsNothing,
    );
  });

  testWidgets('a failed search offers a retry row', (tester) async {
    await pumpApp(tester);
    await openDialog(
      tester,
      search: (_) async =>
          throw RommException('Request failed (502)', statusCode: 502),
    );

    expect(
      find.text('The RomM search failed — select to try again'),
      findsOneWidget,
    );
  });

  testWidgets('cover mode names the local game in its confirmation', (
    tester,
  ) async {
    await pumpApp(tester);
    await openDialog(
      tester,
      mode: RommFixMode.cover,
      search: (_) async => [
        RommFixCandidate.fromCover(
          const RommCoverResult(name: 'Chrono Trigger', url: 'x'),
        ),
      ],
    );

    expect(find.text('Change cover on RomM'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.text('Apply this cover?'), findsOneWidget);
  });
}
