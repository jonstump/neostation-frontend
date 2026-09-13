import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show CacheExtentStyle;
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/romm_screen/romm_rom_card.dart';
import 'package:neostation/screens/romm_screen/romm_rom_grid.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/cover_decode.dart';
import 'package:shared_preferences/shared_preferences.dart';

RommService _service({String serverUrl = 'https://romm.local'}) {
  final s = RommService();
  s.configure(serverUrl: serverUrl, username: 'testuser', password: 's3cret');
  return s;
}

RommRom _rom({
  String? urlCover,
  String? pathCoverLarge,
  String? pathCoverSmall,
  int id = 1,
}) => RommRom(
  id: id,
  name: 'Game',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'game.sfc',
  fsNameNoExt: 'game',
  fsExtension: 'sfc',
  urlCover: urlCover,
  pathCoverLarge: pathCoverLarge,
  pathCoverSmall: pathCoverSmall,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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

  group('RommService.tileCoverUrlCandidates', () {
    test('orders cached small, then cached large, then the provider URL', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          urlCover: 'https://cdn.igdb/cover.png',
          pathCoverLarge: '/assets/big.png',
          pathCoverSmall: '/assets/small.png',
        ),
      );
      expect(urls, [
        'https://romm.local/assets/small.png',
        'https://romm.local/assets/big.png',
        'https://cdn.igdb/cover.png',
      ]);
    });

    test('is the reverse of the large-cover order', () {
      final rom = _rom(
        urlCover: 'https://cdn.igdb/cover.png',
        pathCoverLarge: '/assets/big.png',
        pathCoverSmall: '/assets/small.png',
      );
      final s = _service();
      expect(
        s.tileCoverUrlCandidates(rom),
        s.coverUrlCandidates(rom).reversed.toList(),
      );
    });

    test('requests only the provider URL when that is all the ROM has', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(urlCover: 'https://cdn.igdb/cover.png'),
      );
      expect(urls, ['https://cdn.igdb/cover.png']);
    });

    test('requests only the small file when that is all the ROM has', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(pathCoverSmall: '/assets/small.png'),
      );
      expect(urls, ['https://romm.local/assets/small.png']);
    });

    test('skips sources the server left empty', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          urlCover: '',
          pathCoverLarge: '/assets/big.png',
          pathCoverSmall: '',
        ),
      );
      expect(urls, ['https://romm.local/assets/big.png']);
    });

    test('is empty when the ROM has no cover at all', () {
      expect(_service().tileCoverUrlCandidates(_rom()), isEmpty);
    });

    test('joins server-relative paths with and without a leading slash', () {
      final s = _service(serverUrl: 'http://10.0.0.5:8080');
      expect(
        s.tileCoverUrlCandidates(_rom(pathCoverSmall: '/assets/small.png')),
        ['http://10.0.0.5:8080/assets/small.png'],
      );
      expect(
        s.tileCoverUrlCandidates(_rom(pathCoverSmall: 'assets/small.png')),
        ['http://10.0.0.5:8080/assets/small.png'],
      );
    });

    test('passes absolute http(s) URLs through untouched', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          pathCoverSmall: 'http://other.host/small.png',
          urlCover: 'https://cdn.igdb/cover.png',
        ),
      );
      expect(urls, [
        'http://other.host/small.png',
        'https://cdn.igdb/cover.png',
      ]);
    });

    test('keeps auth headers for server files and withholds them for CDNs', () {
      final s = RommService();
      s.configure(
        serverUrl: 'https://romm.local',
        username: 'u',
        password: 'p',
        accessToken: 'tok',
      );
      final urls = s.tileCoverUrlCandidates(
        _rom(
          pathCoverSmall: '/assets/small.png',
          urlCover: 'https://cdn.igdb/cover.png',
        ),
      );
      expect(s.imageHeadersFor(urls[0]), isNotEmpty);
      expect(s.imageHeadersFor(urls[1]), isEmpty);
    });
  });

  group('coverDecodeWidth', () {
    test('120 logical px at 2.0 decodes at 240', () {
      expect(coverDecodeWidth(logicalWidth: 120, devicePixelRatio: 2.0), 240);
    });

    test('the 72 px list thumbnail at 2.625 decodes at 189', () {
      expect(coverDecodeWidth(logicalWidth: 72, devicePixelRatio: 2.625), 189);
    });

    test('rounds a fractional result up, never down', () {
      expect(coverDecodeWidth(logicalWidth: 100.4, devicePixelRatio: 1.0), 101);
      expect(coverDecodeWidth(logicalWidth: 100.01, devicePixelRatio: 1), 101);
    });

    test('never returns less than 1', () {
      expect(coverDecodeWidth(logicalWidth: 0, devicePixelRatio: 2), 1);
      expect(coverDecodeWidth(logicalWidth: -50, devicePixelRatio: 2), 1);
    });

    test('guards NaN and infinity', () {
      expect(
        coverDecodeWidth(logicalWidth: double.nan, devicePixelRatio: 2),
        1,
      );
      expect(
        coverDecodeWidth(logicalWidth: double.infinity, devicePixelRatio: 2),
        1,
      );
    });
  });

  group('coverDecodeHint', () {
    // The grid's tile: a cell [w] wide is [RommRomGrid.tileRatio] times that
    // tall, and the cover is painted into it with BoxFit.cover.
    ({double w, double h}) tile(double w) =>
        (w: w, h: RommRomGrid.rowHeightFor(w));

    /// Width, in logical pixels, that BoxFit.cover actually paints a source of
    /// [srcW] x [srcH] at inside a [box].
    double paintedWidth(({double w, double h}) box, double srcW, double srcH) {
      final scale = math.max(box.w / srcW, box.h / srcH);
      return srcW * scale;
    }

    /// Width the hint lets the bitmap decode to, for that same source.
    double decodedWidth(
      ({int? cacheWidth, int? cacheHeight}) hint,
      double srcW,
      double srcH,
      double dpr,
    ) {
      if (hint.cacheWidth != null) return hint.cacheWidth! / dpr;
      return (hint.cacheHeight! / dpr) * (srcW / srcH);
    }

    test('a taller-than-wide tile pins the height, which is the axis cover '
        'fills for anything at least as wide as the tile', () {
      final hint = coverDecodeHint(
        logicalWidth: 200,
        logicalHeight: RommRomGrid.rowHeightFor(200),
        devicePixelRatio: 1,
      );
      expect(hint.cacheWidth, isNull);
      expect(hint.cacheHeight, 284); // 283.4, rounded up.
    });

    test('the 1000x500 banner in a 200px cell decodes at the width it is '
        'painted, not at the cell width', () {
      final box = tile(200);
      final hint = coverDecodeHint(
        logicalWidth: box.w,
        logicalHeight: box.h,
        devicePixelRatio: 1,
      );
      final painted = paintedWidth(box, 1000, 500);
      expect(painted, closeTo(566.8, 0.1));
      // The cell-width hint capped this at 200 and upsampled ~2.8x.
      expect(
        decodedWidth(hint, 1000, 500, 1),
        greaterThanOrEqualTo(painted - 1),
      );
    });

    test('no off-ratio cover from square up is decoded below its painted '
        'width', () {
      final box = tile(180);
      final hint = coverDecodeHint(
        logicalWidth: box.w,
        logicalHeight: box.h,
        devicePixelRatio: 2,
      );
      // Aspect 0.706 is the IGDB shape the grid assumes; everything above it
      // is a cover wider than the tile, which is what used to be capped.
      for (final aspect in [0.706, 0.8, 1.0, 1.5, 2.0, 3.0]) {
        final srcH = 600.0;
        final srcW = srcH * aspect;
        expect(
          decodedWidth(hint, srcW, srcH, 2),
          greaterThanOrEqualTo(paintedWidth(box, srcW, srcH) - 1),
          reason: 'aspect $aspect was capped below its painted width',
        );
      }
    });

    test('an IGDB-shaped cover decodes no more pixels than the cell width '
        'used to ask for', () {
      final box = tile(200);
      final hint = coverDecodeHint(
        logicalWidth: box.w,
        logicalHeight: box.h,
        devicePixelRatio: 1,
      );
      // 264x374 painted in a 1.417 tile fills it exactly, so the height hint
      // asks for the same bitmap the cell-width hint did.
      expect(decodedWidth(hint, 264, 374, 1), closeTo(box.w, 1.0));
    });

    test('a square box keeps the width, where portrait art is the common '
        'case', () {
      final hint = coverDecodeHint(
        logicalWidth: 72,
        logicalHeight: 72,
        devicePixelRatio: 2,
      );
      expect(hint.cacheWidth, 144);
      expect(hint.cacheHeight, isNull);
    });

    test('an unbounded axis falls back to the one that is known', () {
      expect(
        coverDecodeHint(
          logicalWidth: 120,
          logicalHeight: null,
          devicePixelRatio: 1,
        ),
        (cacheWidth: 120, cacheHeight: null),
      );
      expect(
        coverDecodeHint(
          logicalWidth: null,
          logicalHeight: 120,
          devicePixelRatio: 1,
        ),
        (cacheWidth: null, cacheHeight: 120),
      );
    });

    test(
      'an unbounded parent hints nothing rather than decoding to a pixel',
      () {
        expect(
          coverDecodeHint(
            logicalWidth: null,
            logicalHeight: null,
            devicePixelRatio: 2,
          ),
          (cacheWidth: null, cacheHeight: null),
        );
      },
    );

    test('never sets both axes, which would resize the art to a rectangle '
        'and distort it', () {
      for (final size in [(100.0, 200.0), (200.0, 100.0), (150.0, 150.0)]) {
        final hint = coverDecodeHint(
          logicalWidth: size.$1,
          logicalHeight: size.$2,
          devicePixelRatio: 1.5,
        );
        expect(
          hint.cacheWidth == null || hint.cacheHeight == null,
          isTrue,
          reason: 'both axes hinted for $size',
        );
      }
    });
  });

  group('RommRomGrid.cacheExtentFor', () {
    test('keeps two rows past each edge, in pixels', () {
      final extent = RommRomGrid.cacheExtentFor(200);
      expect(extent.style, CacheExtentStyle.pixel);
      expect(extent.value, closeTo(RommRomGrid.rowHeightFor(200) * 2, 1e-9));
    });

    test('does not scale with the viewport, so a taller screen does not keep '
        'proportionally more live covers', () {
      expect(
        RommRomGrid.cacheExtentFor(200).style,
        isNot(CacheExtentStyle.viewport),
      );
    });

    test('stays far below a viewport of rows on a handheld-sized grid', () {
      // 1280x720 landscape, six columns: a viewport-scaled extent would keep
      // 720px past each edge; two rows is a fraction of that.
      const cellWidth = 1280 / 6;
      expect(RommRomGrid.cacheExtentFor(cellWidth).value, lessThan(720));
    });

    test('falls back to the Flutter default before the first layout pass', () {
      expect(RommRomGrid.cacheExtentFor(0).value, 250);
      expect(RommRomGrid.cacheExtentFor(double.nan).value, 250);
    });
  });

  group('the tile wires the hint through to the decode', () {
    /// The card drawn at [layout], with the grid's cell size where it has one.
    Future<ResizeImage> pumpCard(
      WidgetTester tester, {
      required RommRomLayout layout,
    }) async {
      final provider = RommProvider();
      provider.service.configure(
        serverUrl: 'https://romm.local',
        apiKey: 'test-key',
      );
      addTearDown(provider.dispose);
      const cellWidth = 200.0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 720),
            devicePixelRatio: 2,
          ),
          child: ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (context, child) => MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: cellWidth,
                    height: RommRomGrid.rowHeightFor(cellWidth),
                    child: RommRomCard(
                      rom: _rom(pathCoverSmall: '/assets/small.png'),
                      provider: provider,
                      romFolders: const [],
                      isFocused: false,
                      layout: layout,
                      tileWidth: layout == RommRomLayout.grid
                          ? cellWidth
                          : null,
                      tileHeight: layout == RommRomLayout.grid
                          ? RommRomGrid.rowHeightFor(cellWidth)
                          : null,
                      onDownload: () {},
                      onCancel: () {},
                      onTap: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image).first);
      return image.image as ResizeImage;
    }

    testWidgets('the grid tile bounds the decode by its height', (
      tester,
    ) async {
      final resize = await pumpCard(tester, layout: RommRomLayout.grid);
      expect(resize.height, isNotNull);
      expect(resize.width, isNull);
      // 200 wide cell -> 283.4 tall tile, at a devicePixelRatio of 2.
      expect(resize.height, 567);
    });

    testWidgets('the list row bounds its square thumbnail by width', (
      tester,
    ) async {
      final resize = await pumpCard(tester, layout: RommRomLayout.list);
      expect(resize.width, isNotNull);
      expect(resize.height, isNull);
    });
  });

  group('the grid wires its own geometry through', () {
    Future<void> pumpGrid(WidgetTester tester) async {
      final provider = RommProvider();
      provider.service.configure(
        serverUrl: 'https://romm.local',
        apiKey: 'test-key',
      );
      addTearDown(provider.dispose);
      final roms = [
        for (var i = 1; i <= 24; i++)
          _rom(pathCoverSmall: '/assets/small$i.png', id: i),
      ];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 720),
            devicePixelRatio: 2,
          ),
          child: ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (context, child) => MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              home: Scaffold(
                body: RommRomGrid(
                  provider: provider,
                  roms: roms,
                  romFolders: const [],
                  initialIndex: 0,
                  onIndexChanged: (_) {},
                  onConfirm: (_) {},
                  onCancel: (_) {},
                  onBack: () {},
                  onToggleView: () {},
                  onSyncAll: () {},
                  footerBuilder: (_) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the scroll view keeps a bounded pixel cache extent, not a '
        'viewport-scaled one', (tester) async {
      await pumpGrid(tester);
      final scrollView = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      final extent = scrollView.scrollCacheExtent;
      expect(extent, isNotNull);
      expect(extent!.style, CacheExtentStyle.pixel);
      // The grid lays 24 cards out across a 1280-wide viewport.
      expect(extent.value, lessThan(720));
    });

    testWidgets('every tile is told the height it is painted at, not just its '
        'width', (tester) async {
      await pumpGrid(tester);
      final card = tester.widget<RommRomCard>(find.byType(RommRomCard).first);
      expect(card.tileWidth, isNotNull);
      expect(
        card.tileHeight,
        closeTo(RommRomGrid.rowHeightFor(card.tileWidth!), 1e-6),
      );
    });
  });

  group('RommRomGrid fixed tile ratio', () {
    test('tileRatio is the IGDB cover ratio the grid used to fall back to', () {
      expect(RommRomGrid.tileRatio, 1.417);
    });

    test('row height is the cell width times the ratio, for any width', () {
      for (final w in [50.0, 120.0, 133.7, 240.0]) {
        expect(RommRomGrid.rowHeightFor(w), closeTo(w * 1.417, 1e-9));
      }
    });

    test('row height depends on width only, so rebuilding is a no-op', () {
      final first = RommRomGrid.rowHeightFor(120);
      final again = RommRomGrid.rowHeightFor(120);
      expect(again, first);
    });
  });
}
