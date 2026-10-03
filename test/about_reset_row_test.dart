import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/about_settings_content.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The About section must end with the reset row.
///
/// It is what `_getContentItemCount()` in `new_settings_screen.dart` bounds
/// D-pad navigation on, so a count lower than the row count makes the tail of
/// the section unreachable — the same failure the general section had
/// (issue #239). The reset row in particular must be the last one and always
/// drawn: it is the way out of a broken install, so it may not depend on the
/// database having opened.
///
/// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Reset Entry Point"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SfxService().setEnabled(false);
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  tearDownAll(() => SfxService().setEnabled(true));

  final key = GlobalKey<AboutSettingsContentState>();

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
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
              isContentFocused: false,
              selectedContentIndex: 0,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the reset row is drawn last, below Export logs', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pump(tester);
    await tester.pumpAndSettle();

    // The navigation count covers every drawn row, including the reset row.
    expect(key.currentState?.getItemCount(), 7);

    final resetTitle = AppLocale.resetNeoStation.getString(
      tester.element(find.byType(AboutSettingsContent)),
    );
    final exportTitle = AppLocale.exportLogs.getString(
      tester.element(find.byType(AboutSettingsContent)),
    );

    final resetRect = tester.getRect(find.text(resetTitle));
    final exportRect = tester.getRect(find.text(exportTitle));
    expect(resetRect.top, greaterThan(exportRect.top));
  });
}
