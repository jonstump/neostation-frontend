import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The context menu's "Upload to RomM" row: present and firing when the host
/// binds it, absent when it does not — the host binds it only for an
/// unlinked single-file game while the RomM gate allows.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload
/// Surfaces"
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

  Widget host(Widget child) => ScreenUtilInit(
    designSize: const Size(1920, 1080),
    builder: (context, _) => MaterialApp(
      localizationsDelegates:
          FlutterLocalization.instance.localizationsDelegates,
      supportedLocales: FlutterLocalization.instance.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  String label(BuildContext context, String key) => key.getString(context);

  testWidgets(
    'a bound upload row is listed with the per-game actions and fires',
    (tester) async {
      final ctx = await pumpHost(tester);
      var uploads = 0;
      // ignore: unawaited_futures
      showGameContextMenu(
        context: ctx,
        targets: const [],
        onSettings: () {},
        onScrape: () {},
        onUploadToRomm: () => uploads++,
      );
      await tester.pumpAndSettle();

      final upload = find.text(label(ctx, AppLocale.rommUploadMenuItem));
      expect(upload, findsOneWidget);
      // Below Scrape, above the view-level actions: it acts on this one game.
      final scrapeY = tester
          .getTopLeft(find.text(label(ctx, AppLocale.hintScrape)))
          .dy;
      expect(tester.getTopLeft(upload).dy, greaterThan(scrapeY));

      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(uploads, 1);
    },
  );

  testWidgets('an unbound upload row is absent, not inert', (tester) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: () {},
      onScrape: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.rommUploadMenuItem)), findsNothing);
    expect(find.text(label(ctx, AppLocale.hintScrape)), findsOneWidget);
  });
}
