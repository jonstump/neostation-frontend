import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_firmware.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/bios_destination_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/romm_firmware_panel.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The BIOS panel as the user meets it.
///
/// The panel shipped with no widget test at all, which is how `_canChooseFolder`
/// — hiding "Choose BIOS folder" whenever RetroArch supplied the destination —
/// got merged without anything noticing that it left no in-app way to set
/// `user_config.bios_directory` at all. SPEC-0012 REQ "BIOS Destination" now
/// says the panel MUST always offer to pick a folder and that an explicit
/// choice outranks the RetroArch default, so that is what this pins:
///
/// * the picker is offered in every destination state;
/// * a pick survives reopening the panel, over a RetroArch directory that is
///   perfectly usable;
/// * the footer index stays in range as "Download all missing" comes and goes
///   around the always-present picker;
/// * the gamepad contract — layer pushed with the navigator and popped on
///   dispose, B cancelling a running download before it closes anything, and
///   every action reachable with the D-pad rather than only a tap.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "BIOS Destination", REQ "Firmware Panel"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Navigation and activation play SFX through SoLoud's FFI bindings, which
    // are not loadable in a test process; the failed init surfaces as an
    // unhandled error on the very key press being exercised.
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

  tearDown(() {
    GlobalNotificationService().notifier.value = [];
  });

  const psx = SystemModel(
    id: 'psx',
    folderName: 'psx',
    realName: 'PlayStation',
    iconImage: '',
    color: '#000000',
    folders: ['psx'],
  );

  const bios = RommFirmware(
    id: 11,
    platformId: 7,
    fileName: 'scph5501.bin',
    fileSizeBytes: 8,
  );

  // ── Fakes ──────────────────────────────────────────────────────────────────

  /// A destination the panel reads and writes through, backed by a mutable
  /// store so a pick made in one panel is visible to the next one — which is
  /// the whole of the "survives reopening" scenario.
  ///
  /// Existence is answered from the real filesystem (cheap, synchronous) and
  /// writability is granted: the probe's own behaviour has its own tests.
  BiosDestinationService destinations({
    String? retroArch,
    String? stored,
    List<String>? picks,
  }) {
    var current = stored;
    return BiosDestinationService(
      retroArchSystemDirectory: () async => retroArch,
      storedBiosDirectory: () async => current,
      persistBiosDirectory: (d) async {
        current = d;
        picks?.add(d);
      },
      directoryExists: (d) async => Directory(d).existsSync(),
      directoryIsWritable: (d) async => true,
    );
  }

  // ── Harness ────────────────────────────────────────────────────────────────

  late BuildContext host;

  /// Hands control back to the real event loop, twice.
  ///
  /// `testWidgets` runs in a fake-async zone where `dart:io` futures never
  /// complete, and the panel stats every row against the destination on load
  /// and after every pick. A frame has to be pumped first so the work is
  /// actually in flight, then the real loop gets a turn, and the second round
  /// covers the `setState` that follows the one before it. The [ms] pause also
  /// clears the navigator's 150 ms reactivation grace, so a key press that
  /// follows one is not swallowed.
  ///
  /// Pass [animating] while a transfer is in flight: the row's progress bar has
  /// no value then, and an indeterminate `LinearProgressIndicator` never lets
  /// `pumpAndSettle` finish.
  Future<void> settle(
    WidgetTester tester, {
    int ms = 60,
    bool animating = false,
  }) async {
    Future<void> flush() async {
      if (!animating) {
        await tester.pumpAndSettle();
        return;
      }
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await flush();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await flush();
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
            // The app wraps everything in a FocusTraversalGroup whose
            // NoFocusTraversalPolicy hands focus to nothing (main.dart), so no
            // widget is ever focused and Flutter's default Enter-activates-the-
            // focused-widget shortcut can never fire. Without stripping the
            // defaults here the harness would be *more* permissive than the
            // app: the first InkWell takes focus and every A press would both
            // run the panel's action and re-select whatever holds focus.
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

  /// Opens the panel on a real route, so B can actually pop it.
  Future<void> openPanel(
    WidgetTester tester, {
    required RommService service,
    required BiosDestinationService destination,
    Future<String?> Function(BuildContext context)? folderPicker,
  }) async {
    unawaited(
      showDialog<void>(
        context: host,
        barrierDismissible: false,
        builder: (_) => RommFirmwarePanel(
          system: psx,
          platformId: 7,
          service: service,
          destinationService: destination,
          folderPicker: folderPicker,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool animating = false,
  }) async {
    await settle(tester, ms: 200, animating: animating);
    await tester.sendKeyEvent(key);
    await settle(tester, animating: animating);
  }

  final panelTitle = find.text('BIOS files for PlayStation');
  final picker = find.text('Choose BIOS folder');
  final downloadAll = find.text('Download all missing');

  // ── The picker is always offered ──────────────────────────────────────────

  group('the folder picker', () {
    testWidgets('is offered while RetroArch supplies the destination', (
      tester,
    ) async {
      // Governing: SPEC-0012 REQ "BIOS Destination" scenario "RetroArch known,
      // nothing chosen" — "the panel says so while still offering the picker".
      final ra = Directory.systemTemp.createTempSync('bios_ra');
      addTearDown(() => ra.deleteSync(recursive: true));

      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(retroArch: ra.path),
      );

      expect(
        find.text('Destination (from RetroArch): ${ra.path}'),
        findsOneWidget,
      );
      expect(picker, findsOneWidget);
    });

    testWidgets('is offered while a chosen folder supplies the destination', (
      tester,
    ) async {
      final chosen = Directory.systemTemp.createTempSync('bios_chosen');
      addTearDown(() => chosen.deleteSync(recursive: true));

      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(stored: chosen.path),
      );

      expect(find.text('Destination: ${chosen.path}'), findsOneWidget);
      expect(picker, findsOneWidget);
    });

    testWidgets('is offered when there is no destination at all', (
      tester,
    ) async {
      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(),
      );

      expect(
        find.text('Choose a BIOS folder before downloading'),
        findsOneWidget,
      );
      expect(picker, findsOneWidget);
      // Nothing to download into, so the only footer action is the picker.
      expect(downloadAll, findsNothing);
    });
  });

  // ── An explicit choice outranks RetroArch ─────────────────────────────────

  testWidgets('a picked folder outranks RetroArch and survives reopening', (
    tester,
  ) async {
    // Governing: SPEC-0012 REQ "BIOS Destination" scenario "An explicit choice
    // outranks RetroArch". Both directories are perfectly usable — the point is
    // which one wins, this open and the next.
    final ra = Directory.systemTemp.createTempSync('bios_ra');
    final chosen = Directory.systemTemp.createTempSync('bios_chosen');
    addTearDown(() => ra.deleteSync(recursive: true));
    addTearDown(() => chosen.deleteSync(recursive: true));

    final picks = <String>[];
    final destination = destinations(retroArch: ra.path, picks: picks);

    await pumpApp(tester);
    await openPanel(
      tester,
      service: _FakeRommService(firmware: const [bios]),
      destination: destination,
      folderPicker: (_) async => chosen.path,
    );
    expect(
      find.text('Destination (from RetroArch): ${ra.path}'),
      findsOneWidget,
    );

    await tester.tap(picker);
    await settle(tester);

    expect(picks, [chosen.path]);
    expect(find.text('Destination: ${chosen.path}'), findsOneWidget);

    // Reopen: the panel resolves from scratch, and RetroArch must not win it
    // back. This is exactly what the old ordering got wrong — a pick applied
    // for one session and was silently dropped on the next.
    await press(tester, LogicalKeyboardKey.backspace);
    expect(panelTitle, findsNothing);

    await openPanel(
      tester,
      service: _FakeRommService(firmware: const [bios]),
      destination: destination,
    );

    expect(find.text('Destination: ${chosen.path}'), findsOneWidget);
    expect(picker, findsOneWidget);
  });

  // ── Footer bounds as the action list changes length ───────────────────────

  group('the footer index', () {
    testWidgets('stays on the picker when Download all missing appears', (
      tester,
    ) async {
      // Setting a destination inserts an action *ahead* of the picker, so the
      // index the user is sitting on has to be recomputed, not kept.
      final chosen = Directory.systemTemp.createTempSync('bios_grow');
      addTearDown(() => chosen.deleteSync(recursive: true));

      var picks = 0;
      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(),
        folderPicker: (_) async {
          picks++;
          return chosen.path;
        },
      );

      expect(downloadAll, findsNothing);

      // Row, then the only footer action.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      expect(picks, 1);
      expect(downloadAll, findsOneWidget, reason: 'the footer list grew');
      expect(picker, findsOneWidget);

      // The cursor must still be on the picker, one slot further down than it
      // was, rather than on the newly inserted download action.
      await press(tester, LogicalKeyboardKey.enter);
      expect(picks, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays on the picker when Download all missing disappears', (
      tester,
    ) async {
      // The mirror case: picking a folder that already holds every file drops
      // an action from ahead of the picker, so the index must shrink with it.
      final empty = Directory.systemTemp.createTempSync('bios_empty');
      final full = Directory.systemTemp.createTempSync('bios_full');
      File(
        p.join(full.path, bios.fileName),
      ).writeAsBytesSync(List<int>.filled(bios.fileSizeBytes, 0));
      addTearDown(() => empty.deleteSync(recursive: true));
      addTearDown(() => full.deleteSync(recursive: true));

      var picks = 0;
      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(stored: empty.path),
        folderPicker: (_) async {
          picks++;
          return full.path;
        },
      );

      expect(downloadAll, findsOneWidget);

      // Row, download-all, picker.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      expect(picks, 1);
      // The row's second line is "<size> · <state>", one Text.
      expect(find.textContaining('Present'), findsOneWidget);
      expect(downloadAll, findsNothing, reason: 'nothing left to fetch');
      expect(picker, findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);
      expect(picks, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty listing still activates safely', (tester) async {
      // The range guard on an empty row list: the picker is the only item, so
      // an index that used to run past the end has nowhere to go.
      await pumpApp(tester);
      var picks = 0;
      await openPanel(
        tester,
        service: _FakeRommService(),
        destination: destinations(),
        folderPicker: (_) async {
          picks++;
          return null;
        },
      );

      expect(
        find.text('RomM has no BIOS files for this platform'),
        findsOneWidget,
      );
      expect(picker, findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter);
      expect(picks, 1);
      expect(tester.takeException(), isNull);
    });
  });

  // ── Gamepad contract ──────────────────────────────────────────────────────

  group('gamepad discipline', () {
    testWidgets('takes the controller from below and hands it back', (
      tester,
    ) async {
      // The layer goes up in the same post-frame callback as the navigator: a
      // navigator without a registered layer is invisible to the manager, and
      // the screen underneath would answer the same button press.
      final events = <String>[];
      GamepadNavigationManager.pushLayer(
        'test_settings_dialog',
        onActivate: () => events.add('+below'),
        onDeactivate: () => events.add('-below'),
      );
      addTearDown(
        () => GamepadNavigationManager.popLayer('test_settings_dialog'),
      );

      await pumpApp(tester);
      events.clear();

      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(),
      );
      expect(events, ['-below'], reason: 'the panel must own the controller');

      await press(tester, LogicalKeyboardKey.backspace);
      expect(panelTitle, findsNothing);
      expect(events, [
        '-below',
        '+below',
      ], reason: 'dispose must pop the layer it pushed');
    });

    testWidgets('every action is reachable with the D-pad, not just a tap', (
      tester,
    ) async {
      final chosen = Directory.systemTemp.createTempSync('bios_dpad');
      addTearDown(() => chosen.deleteSync(recursive: true));

      var picks = 0;
      await pumpApp(tester);
      await openPanel(
        tester,
        service: _FakeRommService(firmware: const [bios]),
        destination: destinations(stored: chosen.path),
        folderPicker: (_) async {
          picks++;
          return null;
        },
      );

      // Row, download-all, picker — the last item in the list, and the one a
      // controller-only user could not otherwise get to.
      expect(downloadAll, findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.enter);

      expect(picks, 1);
    });

    testWidgets('B cancels a running download before it closes anything', (
      tester,
    ) async {
      final chosen = Directory.systemTemp.createTempSync('bios_cancel');
      addTearDown(() => chosen.deleteSync(recursive: true));

      final gate = Completer<void>();
      final service = _FakeRommService(
        firmware: const [bios],
        onDownload: (_, shouldCancel) async {
          await gate.future;
          if (shouldCancel?.call() ?? false) throw RommCancelledException();
        },
      );

      await pumpApp(tester);
      await openPanel(
        tester,
        service: service,
        destination: destinations(stored: chosen.path),
      );

      await tester.tap(downloadAll);
      await tester.pump();
      // Both the footer action and the close hint read "Cancel" while a
      // transfer is in flight.
      expect(find.text('Cancel'), findsNWidgets(2));

      await press(tester, LogicalKeyboardKey.backspace, animating: true);
      expect(
        panelTitle,
        findsOneWidget,
        reason: 'B must stop the transfer, not abandon it half-written',
      );

      gate.complete();
      await settle(tester);

      expect(
        GlobalNotificationService().notifier.value.last.message,
        startsWith('BIOS download stopped'),
      );
      expect(panelTitle, findsOneWidget);

      // Idle now, so the next B is the close it always was.
      await press(tester, LogicalKeyboardKey.backspace);
      expect(panelTitle, findsNothing);
    });
  });
}

/// A RomM connection that answers from memory.
///
/// [RommService] is a plain class with no injectable transport for these two
/// calls, so the panel's collaborator is a subclass rather than a mock; nothing
/// it inherits is exercised.
class _FakeRommService extends RommService {
  _FakeRommService({this.firmware = const [], this.onDownload});

  final List<RommFirmware> firmware;

  /// Stands in for the transfer. Throw [RommCancelledException] to model a
  /// stopped download, or return normally for one that landed.
  final Future<void> Function(
    String destFilePath,
    bool Function()? shouldCancel,
  )?
  onDownload;

  @override
  Future<List<RommFirmware>> listFirmware(int platformId) async => firmware;

  @override
  Future<void> downloadFirmware(
    RommFirmware firmware, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final handler = onDownload;
    if (handler == null) return;
    await handler(destFilePath, shouldCancel);
  }
}
