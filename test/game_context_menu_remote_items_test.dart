import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/widgets/context_menu/game_context_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The context menu's remote entry items: Download while the entry is
/// downloadable (Retry after a failure, by the label the host passes),
/// Cancel download while one runs, and neither for a local game.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The
/// Library"
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

  testWidgets('a remote entry offers Download, and it fires', (tester) async {
    final ctx = await pumpHost(tester);
    var downloads = 0;
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: null,
      onDownload: () => downloads++,
      downloadLabel: label(ctx, AppLocale.download),
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.download)), findsOneWidget);
    expect(
      find.text(label(ctx, AppLocale.rommRemoteCancelDownload)),
      findsNothing,
    );
    // The per-game rows a remote entry has no local row for stay out.
    expect(find.text(label(ctx, AppLocale.gameSettings)), findsNothing);

    await tester.tap(find.text(label(ctx, AppLocale.download)));
    await tester.pumpAndSettle();
    expect(downloads, 1);
  });

  testWidgets('the menu does not offer library scope', (tester) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: null,
      onViewMode: () {},
      onRandom: () {},
    );
    await tester.pumpAndSettle();

    // Scope is a view-level filter and lives on the footer pill, which shows
    // the chord and the current scope and is tappable without a pad. On a
    // per-game menu it read as acting on the highlighted game. Issue #234.
    expect(
      find.text(label(ctx, AppLocale.libraryScopeToggle)),
      findsNothing,
      reason: 'library scope was removed from the game context menu',
    );
    // The neighbours it sat between are still there, so this is not an
    // empty menu passing by accident.
    expect(find.text(label(ctx, AppLocale.viewMode)), findsOneWidget);
    expect(find.text(label(ctx, AppLocale.randomGame)), findsOneWidget);
  });

  testWidgets('a failed download offers Retry under the host\'s label', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: null,
      onDownload: () {},
      downloadLabel: label(ctx, AppLocale.retry),
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.retry)), findsOneWidget);
    expect(find.text(label(ctx, AppLocale.download)), findsNothing);
  });

  testWidgets('a running download offers Cancel download, and it fires', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    var cancels = 0;
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: null,
      onCancelDownload: () => cancels++,
    );
    await tester.pumpAndSettle();

    final cancel = find.text(label(ctx, AppLocale.rommRemoteCancelDownload));
    expect(cancel, findsOneWidget);
    expect(find.text(label(ctx, AppLocale.download)), findsNothing);

    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(cancels, 1);
  });

  testWidgets('a local game has neither', (tester) async {
    final ctx = await pumpHost(tester);
    // ignore: unawaited_futures
    showGameContextMenu(
      context: ctx,
      targets: const [],
      onSettings: () {},
      onViewMode: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text(label(ctx, AppLocale.gameSettings)), findsOneWidget);
    expect(find.text(label(ctx, AppLocale.download)), findsNothing);
    expect(
      find.text(label(ctx, AppLocale.rommRemoteCancelDownload)),
      findsNothing,
    );
  });
}
