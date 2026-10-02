import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/romm_screen/romm_connect_content.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/custom_toggle_switch.dart';
import 'package:neostation/widgets/setup_wizard/romm_step.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

// Governing: ADR-0021 (RomM in first-run setup), SPEC-0020 REQ "Step
// Placement", REQ "Connected State", REQ "Shared Connect Form"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
    // The switch plays a sound the test host has no audio library for.
    SfxService().setEnabled(false);
  });

  setUp(() async {
    await dbHelper.setUp();
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  Future<({_FakeRomm romm, SqliteConfigProvider config, List<bool> active})>
  pumpStep(WidgetTester tester, {required bool connected}) async {
    final romm = _FakeRomm(connected: connected);
    final config = SqliteConfigProvider();
    final active = <bool>[];
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<RommProvider>.value(value: romm),
                ChangeNotifierProvider<SqliteConfigProvider>.value(
                  value: config,
                ),
                ChangeNotifierProvider<AuthService>(
                  create: (_) => AuthService(),
                ),
              ],
              child: Scaffold(
                body: RommSetupStep(
                  onSkip: () {},
                  onFormActive: active.add,
                  onBusyChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (romm: romm, config: config, active: active);
  }

  String en(String key) => AppLocale.en[key] as String;

  testWidgets('disconnected, the step hosts the RomM tab\'s own form', (
    tester,
  ) async {
    final h = await pumpStep(tester, connected: false);

    expect(find.text(en(AppLocale.wizardRommStepTitle)), findsOneWidget);
    expect(find.text(en(AppLocale.wizardRommStepDesc)), findsOneWidget);
    final form = tester.widget<RommConnectContent>(
      find.byType(RommConnectContent),
    );
    expect(form.tabNavigation, isFalse, reason: 'the wizard has no tabs');
    expect(form.embedded, isTrue);
    expect(form.onExit, isNotNull, reason: 'B with no field focused is Skip');
    expect(h.active, [true], reason: 'the wizard is told the form holds input');
  });

  testWidgets('connected, the form is gone and the server is named', (
    tester,
  ) async {
    final h = await pumpStep(tester, connected: true);

    expect(find.byType(RommConnectContent), findsNothing);
    expect(
      find.text(en(AppLocale.wizardRommStepConnectedDesc)),
      findsOneWidget,
    );
    expect(find.text('https://romm.example'), findsOneWidget);
    expect(find.text('Server version 5.0.0'), findsOneWidget);
    expect(find.text(en(AppLocale.rommShowLibrary)), findsOneWidget);
    expect(h.active, [false]);
  });

  testWidgets('the library switch starts off and writes the setting', (
    tester,
  ) async {
    final h = await pumpStep(tester, connected: true);
    expect(h.config.config.rommShowLibrary, isFalse);
    expect(
      tester.widget<CustomToggleSwitch>(find.byType(CustomToggleSwitch)).value,
      isFalse,
    );

    await tester.runAsync(
      () => RommSetupStep.toggleLibrary(
        tester.element(find.byType(RommSetupStep)),
      ),
    );
    await tester.pump();

    expect(h.config.config.rommShowLibrary, isTrue);
    expect(
      tester.widget<CustomToggleSwitch>(find.byType(CustomToggleSwitch)).value,
      isTrue,
    );
  });

  testWidgets('connecting takes the form down and tells the wizard', (
    tester,
  ) async {
    final h = await pumpStep(tester, connected: false);

    h.romm.setConnected(true);
    await tester.pump();
    await tester.pump();

    expect(find.byType(RommConnectContent), findsNothing);
    expect(h.active, [true, false]);
  });

  testWidgets('leaving the step while the form is up hands input back', (
    tester,
  ) async {
    final h = await pumpStep(tester, connected: false);

    await tester.pumpWidget(const SizedBox());

    expect(h.active, [true, false]);
  });
}

class _FakeRomm extends RommProvider {
  _FakeRomm({required bool connected}) : _connected = connected;

  bool _connected;

  void setConnected(bool value) {
    _connected = value;
    notifyListeners();
  }

  @override
  bool get isConnected => _connected;

  @override
  String get serverUrl => 'https://romm.example';

  @override
  RommServerVersion? get serverVersion =>
      _connected ? const RommServerVersion(5, 0, 0) : null;
}
