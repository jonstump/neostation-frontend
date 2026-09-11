import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/library_scope.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/retro_achievements_provider.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/game_details_footer.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/widgets/game_view_footer.dart';

/// PLAY survives a narrow row in both of the footers that carry it.
///
/// It is the last child of its row in each, so it is the one that runs off the
/// right edge when the row's other items come to more than the row is wide —
/// and in the details card's footer the row is inside a `ClipRRect`, so the
/// surplus was cut off silently rather than striped. Issue #238.
///
/// The details card is an `Expanded` beside a fixed 200-unit sidebar, so its
/// width follows the *panel's* aspect ratio and nothing else — in particular
/// not the selected game's box art, which is a `Positioned.fill` panel in the
/// same stack as the footer and cannot move this row by a pixel. The grid and
/// carousel footer spans the whole screen instead, which is why it takes a
/// squarer panel and a longer language to reach the same edge there.
///
/// The widths below are the ones real panels give each footer; the sweeps
/// cover everything between and beyond them.
class _RaProvider extends RetroAchievementsProvider {
  _RaProvider(this._connected);

  final bool _connected;

  @override
  bool get isConnected => _connected;
}

SystemModel _system() => const SystemModel(
  folderName: 'psx',
  realName: 'Sony PlayStation',
  iconImage: '',
  color: '#FFFFFF',
);

GameModel _game({double rating = 18.0}) => GameModel(
  romname: 'A Game (USA).chd',
  realname: 'A Game',
  name: 'A Game',
  year: '1999',
  developer: '',
  publisher: 'Sony',
  genre: 'RPG',
  players: '1',
  rating: rating,
  playTime: 3671,
  isFavorite: false,
  showRomFileNameSubtitle: true,
);

/// What the details card is left, in the footer's own design units, once the
/// 200-unit sidebar and its margin have come off a panel of each shape.
/// `.r` scales off the shorter side, so a squarer panel yields a *narrower*
/// card in these units even though it has the same pixel count.
const double _card4x3 = 428;
const double _card16x10 = 556;
const double _card16x9 = 641;

/// The same three panels, for the grid and carousel footer, which spans the
/// screen rather than the card.
const double _screen4x3 = 640;
const double _screen16x10 = 768;
const double _screen16x9 = 853;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SfxService().setEnabled(false);
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [
        MapLocale('en', AppLocale.en),
        // The longest scope label of the twelve ("Heruntergeladen"), which is
        // what decides how wide the pill wants to be.
        MapLocale('de', AppLocale.de),
      ],
      initLanguageCode: 'en',
    );
  });

  tearDown(() => FlutterLocalization.instance.translate('en'));

  Future<void> pumpFooter(
    WidgetTester tester, {
    required double width,
    LibraryScope? scope = LibraryScope.downloaded,
    double rating = 18.0,
    bool showsPill = true,
    bool canRandom = true,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _RaProvider(showsPill),
        child: ScreenUtilInit(
          // 1:1 with the design size, so every number in this file is in the
          // footer's own units.
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              extensions: [ChromeSurface.standard()],
            ),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 360,
                  child: Stack(
                    children: [
                      GameDetailsFooter(
                        system: _system(),
                        game: _game(rating: rating),
                        isMusicSystem: false,
                        hasScreenScraper: false,
                        isSecondaryScreenActive: false,
                        onShowAchievements: () {},
                        onShowGameInfo: () {},
                        hasRetroAchievements: showsPill,
                        // Loading is the cheapest state that renders the pill
                        // without a fixture of achievement data.
                        isLoadingAchievements: showsPill,
                        onPlayGame: () {},
                        onShowRandomGame: canRandom ? () {} : null,
                        onToggleFavorite: () {},
                        onOpenGameSettings: () {},
                        libraryScope: scope,
                        onToggleLibraryScope: scope == null ? null : () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// PLAY's own box — the green container, not its label, which the button's
  /// `FittedBox` can shrink independently.
  Rect playButton(WidgetTester tester) {
    final element = find.byType(Container).evaluate().firstWhere((e) {
      final decoration = (e.widget as Container).decoration;
      return decoration is BoxDecoration &&
          decoration.color == const Color(0xFF2ECC71);
    });
    final box = element.renderObject! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The action row's own box: what PLAY has to stay inside of. The footer
  /// clips to it, so anything past its right edge is simply not drawn.
  Rect actionRow(WidgetTester tester) =>
      tester.getRect(find.byType(ExcludeFocus));

  /// The grid/carousel footer at [width], with every optional pill it can show
  /// short of the mute hint (which reads the config provider).
  Future<void> pumpGameViewFooter(
    WidgetTester tester, {
    required double width,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<RetroAchievementsProvider>.value(
        value: _RaProvider(true),
        child: ScreenUtilInit(
          designSize: const Size(1280, 720),
          builder: (context, _) => MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              extensions: [ChromeSurface.standard()],
            ),
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: GameViewFooter(
                    game: _game(),
                    onPlay: () {},
                    hasRetroAchievements: true,
                    isLoadingAchievements: true,
                    onShowAchievements: () {},
                    libraryScope: LibraryScope.downloaded,
                    onToggleLibraryScope: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Two frames: the title's marquee arms itself in a post-frame callback,
    // and an unarmed one leaves a timer pending past the end of the test.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// That footer's PLAY button, measured through its ancestors' transforms —
  /// the group is inside a scale-down `FittedBox`, so its own `size` is the
  /// unscaled one and says nothing about where it lands on screen.
  Rect gridPlayButton(WidgetTester tester) {
    final box =
        find.byType(AnimatedContainer).evaluate().first.renderObject!
            as RenderBox;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  testWidgets('PLAY stays inside the card at every width a panel gives it', (
    tester,
  ) async {
    // The failure is a Row overflow, so it is width-continuous: there is a
    // threshold and everything under it is broken. Sweeping rather than
    // sampling is what makes this a claim about the row and not about three
    // lucky numbers.
    for (final lang in ['en', 'de']) {
      FlutterLocalization.instance.translate(lang);
      for (double width = 320; width <= 720; width += 4) {
        await pumpFooter(tester, width: width);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the row overflowed at $width ($lang)',
        );
        expect(
          playButton(tester).right,
          lessThanOrEqualTo(actionRow(tester).right),
          reason: 'PLAY is cut off by the card edge at $width ($lang)',
        );
      }
    }
  });

  testWidgets('a 4:3 panel keeps PLAY whole and sheds readouts instead', (
    tester,
  ) async {
    // The shape that broke it: a scope pill, a score chip and the dice came to
    // more than a 4:3 card is wide, and the row's one Expanded had already
    // given everything it had.
    await pumpFooter(tester, width: _card4x3);

    final play = playButton(tester);
    expect(play.right, lessThanOrEqualTo(actionRow(tester).right));
    expect(play.width, greaterThan(0));

    // The scope pill is the last thing dropped, because its chord is the only
    // hint the pad user gets for the toggle — it ellipsizes instead.
    expect(find.byIcon(Symbols.download_done_rounded), findsOneWidget);

    // The row's own guarantee: the two toggles never go either.
    expect(find.byIcon(Symbols.favorite_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.settings_rounded), findsOneWidget);
  });

  testWidgets('a wider panel spends the extra on the readouts, not on PLAY', (
    tester,
  ) async {
    // The budget only ever *removes* things: nothing on the row grows with the
    // card except the achievements pill, up to its own cap.
    final playWidths = <double>{};
    for (final card in [_card4x3, _card16x10, _card16x9]) {
      await pumpFooter(tester, width: card);
      playWidths.add(playButton(tester).width);
    }
    expect(
      playWidths,
      hasLength(1),
      reason: 'one PLAY footprint, got $playWidths',
    );

    // And on the cards that can afford it, the score comes back.
    await pumpFooter(tester, width: _card16x9);
    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.emoji_events_rounded), findsOneWidget);
  });

  testWidgets('the row still fits with no scope pill on it', (tester) async {
    // The pre-RomM shape, which is what most installs still see: the row has
    // room to spare and nothing should be shed.
    await pumpFooter(tester, width: _card4x3, scope: null);

    expect(
      playButton(tester).right,
      lessThanOrEqualTo(actionRow(tester).right),
    );
    expect(find.byIcon(Symbols.star_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.casino_rounded), findsOneWidget);
  });

  testWidgets('the grid and carousel footer keeps PLAY inside its row too', (
    tester,
  ) async {
    // The same mechanism in the other footer's shape: every item in its action
    // group is laid out at its natural width and the title column beside it is
    // the row's only Expanded, so once the title had collapsed the group ran
    // off the right edge and PLAY went with it. That footer gets the whole
    // screen rather than the details card, which is the only reason it was
    // further from the edge — not far enough to leave alone.
    for (final lang in ['en', 'de']) {
      FlutterLocalization.instance.translate(lang);
      for (final width in [
        320.0,
        480.0,
        _screen4x3,
        _screen16x10,
        _screen16x9,
      ]) {
        await pumpGameViewFooter(tester, width: width);

        expect(
          gridPlayButton(tester).right,
          lessThanOrEqualTo(width + 0.01),
          reason: 'PLAY runs past the footer edge at $width ($lang)',
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'layout error at $width ($lang)',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }
    }
  });

  testWidgets('the achievements pill is as wide as the row it holds', (
    tester,
  ) async {
    // The pill is a fixed-width box, and both its border and its padding
    // deflate the row inside it before the row gets a constraint. Its width
    // has to cover all three or the row overflows by the shortfall — which is
    // what it did: the box was 101 design units, the row needed 102, and every
    // frame that drew the pill reported a 1.00-pixel overflow.
    //
    // Asserting on the numbers directly would just restate them. A Row that
    // overflows is laid out at its *constraint*, while its children still take
    // the width they asked for, so the two agree only when the box is big
    // enough. That comparison holds whatever the terms are later changed to.
    await pumpGameViewFooter(tester, width: _screen4x3);

    final row = tester.renderObject<RenderFlex>(
      find
          .ancestor(
            of: find.byIcon(Symbols.emoji_events_rounded),
            matching: find.byType(Row),
          )
          .first,
    );

    var content = 0.0;
    row.visitChildren((child) => content += (child as RenderBox).size.width);

    expect(
      row.size.width,
      greaterThanOrEqualTo(content),
      reason:
          'the pill gives its row ${row.size.width} units for $content units '
          'of children — widen the pill or trim what it reserves',
    );
    expect(tester.takeException(), isNull);
  });
}
