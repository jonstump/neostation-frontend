import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/general_settings_content.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/widgets/setting_row.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `getItemCount()` must equal the number of rows General actually draws.
///
/// It is what `new_settings_screen.dart:408` bounds gamepad navigation on, so a
/// count lower than the row count makes the tail of the section unreachable —
/// the rows still draw, D-pad traversal just stops short of them, and on a
/// gamepad UI there is no scrollbar to drag as a workaround.
///
/// That is exactly what happened: the unified library's three rows (show the
/// library, default scope, cover cache size) are rendered and dispatched
/// unconditionally, between the RetroAchievements row and the nav-tab block,
/// but were never counted. The count sat three low and the last three rows of
/// the section could not be reached. Nothing failed loudly — which is why this
/// test compares the two numbers rather than asserting a fixed total that would
/// need updating with every new row. Issue #239.
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

  testWidgets('the unified library rows are among them', (tester) async {
    await pump(tester);
    await tester.pump();

    // Named explicitly: these are the three that were drawn but uncounted, and
    // a regression that dropped them from the list entirely would otherwise
    // satisfy the count test above by making both numbers agree at the wrong
    // value.
    for (final k in [
      AppLocale.rommShowLibrary,
      AppLocale.rommLibraryDefaultScope,
      AppLocale.rommCoverCacheSize,
    ]) {
      expect(
        find.text(k.getString(tester.element(find.byType(Scaffold)))),
        findsOneWidget,
        reason: '$k should be one of the rows General draws',
      );
    }
  });
}
