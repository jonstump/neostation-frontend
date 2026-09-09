import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/notification_bell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A notification's action — Cancel on a running upload, Link now on its
/// summary — as the bell offers it: a pill on the row that fires on a tap,
/// leaves the notification listed, and is gone once an update drops it;
/// the X still dismisses the row.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload
/// Surfaces"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  tearDown(() {
    GlobalNotificationService().notifier.value = [];
    GamepadNavigation.globalSelectTap = null;
  });

  Future<void> pumpBell(WidgetTester tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: ScreenUtilInit(
          designSize: const Size(1920, 1080),
          builder: (context, child) => MaterialApp(
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            theme: ThemeData(
              extensions: <ThemeExtension<dynamic>>[CornerRadii.m()],
            ),
            home: const Scaffold(body: Center(child: NotificationBell())),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    GamepadNavigation.globalSelectTap!();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the action pill fires and the row stays', (tester) async {
    var cancels = 0;
    GlobalNotificationService().show(
      id: 'upload',
      message: 'Uploading a.sfc (1/2)',
      progress: 0.2,
      ongoing: true,
      action: GlobalNotificationAction(
        label: 'Cancel',
        onPressed: () => cancels++,
      ),
    );
    await pumpBell(tester);
    await open(tester);

    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(cancels, 1);
    expect(GlobalNotificationService().notifier.value.single.id, 'upload');
  });

  testWidgets('an update without an action withdraws the pill', (tester) async {
    GlobalNotificationService().show(
      id: 'upload',
      message: 'Uploading',
      ongoing: true,
      action: GlobalNotificationAction(label: 'Cancel', onPressed: () {}),
    );
    await pumpBell(tester);
    await open(tester);
    expect(find.text('Cancel'), findsOneWidget);

    GlobalNotificationService().update(
      id: 'upload',
      message: '1 uploaded, 0 skipped, 0 failed',
      action: GlobalNotificationAction(label: 'Link now', onPressed: () {}),
    );
    await tester.pump();
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Link now'), findsOneWidget);

    GlobalNotificationService().update(id: 'upload', message: 'done');
    await tester.pump();
    expect(find.text('Link now'), findsNothing);
    expect(GlobalNotificationService().notifier.value.single.action, isNull);
  });
}
