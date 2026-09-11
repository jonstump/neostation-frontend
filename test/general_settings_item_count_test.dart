import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/general_settings_content.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/romm_settings_content.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/widgets/setting_row.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `getItemCount()` must equal the number of rows General actually draws.
///
/// It is what `_getContentItemCount()` in `new_settings_screen.dart` bounds
/// gamepad navigation on, so a count lower than the row count makes the tail of
/// the section unreachable — the rows still draw, D-pad traversal just stops
/// short of them, and on a gamepad UI there is no scrollbar to drag as a
/// workaround.
///
/// That is exactly what happened: the unified library's three rows (show the
/// library, default scope, cover cache size) were rendered and dispatched
/// unconditionally but never counted, so the count sat three low and the last
/// three rows of the section could not be reached. Nothing failed loudly —
/// which is why this test compares the two numbers rather than asserting a
/// fixed total that would need updating with every new row. Issue #239. Those
/// three rows have since moved to the RomM section, which this file covers the
/// same way.
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

  final key = GlobalKey<GeneralSettingsContentState>();

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(1920, 1080)),
      child: ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (context, child) => MaterialApp(
          localizationsDelegates:
              FlutterLocalization.instance.localizationsDelegates,
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          home: ChangeNotifierProvider<SqliteConfigProvider>(
            create: (_) => SqliteConfigProvider(),
            child: Scaffold(
              body: GeneralSettingsContent(
                key: key,
                isContentFocused: false,
                selectedContentIndex: 0,
                onFullscreenToggle: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('getItemCount matches the rows General draws', (tester) async {
    await pump(tester);
    await tester.pump();

    final drawn = tester.widgetList<SettingRow>(find.byType(SettingRow)).length;
    final counted = key.currentState!.getItemCount();

    expect(
      counted,
      drawn,
      reason:
          'getItemCount bounds D-pad traversal; a count below the row count '
          'makes the tail of the section unreachable',
    );
  });

  testWidgets('the unified library rows have left General', (tester) async {
    await pump(tester);
    await tester.pump();

    // They moved to their own section. Named explicitly rather than trusting
    // the count: a move that dropped them entirely would satisfy the count
    // test above by making both numbers agree at the wrong value, and the
    // matching assertion in the RomM group below is what catches that.
    for (final k in [
      AppLocale.rommShowLibrary,
      AppLocale.rommLibraryDefaultScope,
      AppLocale.rommCoverCacheSize,
    ]) {
      expect(
        find.text(k.getString(tester.element(find.byType(Scaffold)))),
        findsNothing,
        reason: '$k belongs to the RomM section now',
      );
    }
  });

  group('the RomM section', () {
    final rommKey = GlobalKey<RommSettingsContentState>();

    Future<void> pumpRomm(WidgetTester tester) => tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: ChangeNotifierProvider<SqliteConfigProvider>(
              create: (_) => SqliteConfigProvider(),
              child: Scaffold(
                body: RommSettingsContent(
                  key: rommKey,
                  isContentFocused: false,
                  selectedContentIndex: 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('getItemCount matches the rows it draws', (tester) async {
      await pumpRomm(tester);
      await tester.pump();

      final drawn = tester
          .widgetList<SettingRow>(find.byType(SettingRow))
          .length;

      expect(
        rommKey.currentState!.getItemCount(),
        drawn,
        reason: 'the same invariant General drifted on — pinned from the start',
      );
    });

    testWidgets('it draws the three rows that left General', (tester) async {
      await pumpRomm(tester);
      await tester.pump();

      for (final k in [
        AppLocale.rommShowLibrary,
        AppLocale.rommLibraryDefaultScope,
        AppLocale.rommCoverCacheSize,
      ]) {
        expect(
          find.text(k.getString(tester.element(find.byType(Scaffold)))),
          findsOneWidget,
          reason: '$k should have moved here, not been dropped',
        );
      }
    });
  });
}
