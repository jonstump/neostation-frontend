import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/models/romm_screenshot.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/screens/game_screen/game_details_card/widgets/romm_gallery_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// The details card's RomM gallery strip and the upload toggle behind it.
///
/// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
/// "Gallery Strip", REQ "Upload Toggle", REQ "Localized User-Facing Text"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [const MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  group('gallery strip gating', () {
    // Governing: SPEC-0016 REQ "Gallery Strip"
    test('needs a connection, a link and a server that is not too old', () {
      expect(
        RommProvider.galleryStripVisible(
          connected: true,
          linked: true,
          support: RommFeatureSupport.supported,
        ),
        isTrue,
      );
    });

    test('a disconnected server hides it', () {
      expect(
        RommProvider.galleryStripVisible(
          connected: false,
          linked: true,
          support: RommFeatureSupport.supported,
        ),
        isFalse,
      );
    });

    test('an unlinked game hides it', () {
      expect(
        RommProvider.galleryStripVisible(
          connected: true,
          linked: false,
          support: RommFeatureSupport.supported,
        ),
        isFalse,
      );
    });

    test('a server below 5.0.0 hides it', () {
      expect(
        RommProvider.galleryStripVisible(
          connected: true,
          linked: true,
          support: RommFeatureSupport.unsupported,
        ),
        isFalse,
      );
    });

    test('an unknown version does not hide it', () {
      // ADR-0010: a heartbeat that never landed must not gate. The request
      // degrades on its own if the endpoint really is missing.
      expect(
        RommProvider.galleryStripVisible(
          connected: true,
          linked: true,
          support: RommFeatureSupport.unknown,
        ),
        isTrue,
      );
    });

    test('the feature table places the gallery at 5.0.0', () {
      expect(RommFeature.screenshotGallery.minVersion.major, 5);
      expect(RommFeature.screenshotGallery.minVersion.minor, 0);

      RommFeatureSupport supportAt(String version) =>
          RommServerCapabilities.fromJson({
            'SYSTEM': {'VERSION': version},
          }).supports(RommFeature.screenshotGallery);

      expect(supportAt('5.0.0'), RommFeatureSupport.supported);
      expect(supportAt('5.1.2'), RommFeatureSupport.supported);
      expect(supportAt('4.8.0'), RommFeatureSupport.unsupported);
      // A prerelease of the threshold sorts below it.
      expect(supportAt('5.0.0-beta.1'), RommFeatureSupport.unsupported);
    });
  });

  group('gallery parse', () {
    // Governing: SPEC-0016 REQ "Gallery Strip"
    test('reads user_screenshots newest first', () {
      final shots = RommProvider.parseGallery({
        'id': 7,
        'user_screenshots': [
          {
            'id': 11,
            'file_name': 'Sonic-260906-101500.png',
            'file_size_bytes': 120,
            'download_path': '/api/raw/assets/u/1/Sonic-260906-101500.png',
            'created_at': '2026-09-06T10:15:00',
          },
          {
            'id': 12,
            'file_name': 'Sonic-260906-101800.png',
            'file_size_bytes': 130,
            'download_path': '/api/raw/assets/u/1/Sonic-260906-101800.png',
            'created_at': '2026-09-06T10:18:00',
            'is_gallery': true,
          },
        ],
      });

      expect(shots.map((s) => s.id), [12, 11]);
      expect(shots.first.fileName, 'Sonic-260906-101800.png');
      expect(shots.first.isGallery, isTrue);
      expect(shots.first.downloadPath, isNotNull);
    });

    test('a malformed entry costs only itself', () {
      final shots = RommProvider.parseGallery({
        'user_screenshots': [
          'not an object',
          {'id': 3, 'file_name': 'a.png', 'file_size_bytes': 1},
        ],
      });
      expect(shots, hasLength(1));
      expect(shots.single.id, 3);
    });

    test('a body with no gallery is empty, not an error', () {
      expect(RommProvider.parseGallery(const {}), isEmpty);
      expect(RommProvider.parseGallery(const {'user_screenshots': 5}), isEmpty);
    });

    test('falls back to the id when the server sent no timestamps', () {
      final shots = RommProvider.parseGallery({
        'user_screenshots': [
          {'id': 4, 'file_name': 'b.png', 'file_size_bytes': 1},
          {'id': 9, 'file_name': 'a.png', 'file_size_bytes': 1},
        ],
      });
      expect(shots.map((s) => s.id), [9, 4]);
    });

    test('orders a mixed set the same way whatever order it arrives in', () {
      // The regression: falling through createdAt -> id interleaved two
      // comparison keys, so a set where only some entries carry a timestamp
      // had no total order. These three form a cycle under the old rule —
      // b before a (id), a before c (date), c before b (id) — and List.sort
      // does not detect that, it just returns some arbitrary permutation, so
      // the strip reshuffled between loads.
      final a = RommScreenshot(
        id: 1,
        fileName: 'a.png',
        fileSizeBytes: 1,
        createdAt: DateTime.utc(2026, 9, 6, 10),
      );
      final b = RommScreenshot(id: 2, fileName: 'b.png', fileSizeBytes: 1);
      final c = RommScreenshot(
        id: 3,
        fileName: 'c.png',
        fileSizeBytes: 1,
        createdAt: DateTime.utc(2026, 9, 6, 5),
      );

      const permutations = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
      ];
      final source = [a, b, c];
      for (final order in permutations) {
        final list = [for (final i in order) source[i]]
          ..sort(RommScreenshot.newestFirst);
        expect(
          list.map((s) => s.id),
          // Timestamped newest first, then everything the server dated by id.
          [1, 3, 2],
          reason: 'input order $order',
        );
      }
    });

    test('and to the file name when the ids tie', () {
      final a = RommScreenshot(
        id: 0,
        fileName: 'Game-260906-101500.png',
        fileSizeBytes: 1,
      );
      final b = RommScreenshot(
        id: 0,
        fileName: 'Game-260906-101800.png',
        fileSizeBytes: 1,
      );
      final list = [a, b]..sort(RommScreenshot.newestFirst);
      expect(list.first.fileName, 'Game-260906-101800.png');
    });
  });

  group('RommScreenshot.createdAt', () {
    test('reads created_at, then updated_at, then gives up', () {
      expect(
        RommScreenshot.fromJson(const {
          'id': 1,
          'file_name': 'a.png',
          'created_at': '2026-09-06T10:15:00Z',
          'updated_at': '2026-09-06T12:00:00Z',
        }).createdAt,
        DateTime.parse('2026-09-06T10:15:00Z'),
      );
      expect(
        RommScreenshot.fromJson(const {
          'id': 1,
          'file_name': 'a.png',
          'updated_at': '2026-09-06T12:00:00Z',
        }).createdAt,
        DateTime.parse('2026-09-06T12:00:00Z'),
      );
      expect(
        RommScreenshot.fromJson(const {
          'id': 1,
          'file_name': 'a.png',
          'created_at': 'not a date',
        }).createdAt,
        isNull,
      );
    });
  });

  group('the strip widget', () {
    Future<void> pumpStrip(
      WidgetTester tester, {
      required List<RommScreenshot> shots,
      bool loading = false,
      bool hasError = false,
      int selectedIndex = 0,
      bool isPanelActive = false,
      void Function(int)? onActivate,
    }) async {
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(640, 480),
          builder: (context, _) => MaterialApp(
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            localizationsDelegates:
                FlutterLocalization.instance.localizationsDelegates,
            home: Scaffold(
              body: SizedBox(
                width: 640,
                child: RommGalleryStrip(
                  shots: shots,
                  loading: loading,
                  hasError: hasError,
                  selectedIndex: selectedIndex,
                  isPanelActive: isPanelActive,
                  // No network in a widget test: every entry draws its
                  // placeholder, which is what a null URL means anyway.
                  urlOf: (_) => null,
                  headersOf: (_) => const {},
                  onActivate: onActivate ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    RommScreenshot shot(int id) =>
        RommScreenshot(id: id, fileName: '$id.png', fileSizeBytes: 1);

    // Governing: SPEC-0016 REQ "Gallery Strip" — "three thumbnails render".
    testWidgets('draws one tile per screenshot under the title', (
      tester,
    ) async {
      await pumpStrip(tester, shots: [shot(3), shot(2), shot(1)]);

      expect(
        find.text(AppLocale.en[AppLocale.rommGalleryTitle]),
        findsOneWidget,
      );
      expect(find.byType(GestureDetector), findsNWidgets(3));
      expect(find.text(AppLocale.en[AppLocale.rommGalleryEmpty]), findsNothing);
    });

    testWidgets('confirming a tile reports its index', (tester) async {
      int? activated;
      await pumpStrip(
        tester,
        shots: [shot(3), shot(2)],
        onActivate: (i) => activated = i,
      );
      await tester.tap(find.byType(GestureDetector).at(1));
      expect(activated, 1);
    });

    // Governing: SPEC-0016 REQ "Localized User-Facing Text"
    testWidgets('an empty gallery says so, localized', (tester) async {
      await pumpStrip(tester, shots: const []);
      expect(
        find.text(AppLocale.en[AppLocale.rommGalleryEmpty]),
        findsOneWidget,
      );
    });

    testWidgets('a failed request says something else', (tester) async {
      await pumpStrip(tester, shots: const [], hasError: true);
      expect(
        find.text(AppLocale.en[AppLocale.rommGalleryError]),
        findsOneWidget,
      );
      expect(find.text(AppLocale.en[AppLocale.rommGalleryEmpty]), findsNothing);
    });

    testWidgets('a load in flight shows a spinner, not the empty state', (
      tester,
    ) async {
      await pumpStrip(tester, shots: const [], loading: true);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(AppLocale.en[AppLocale.rommGalleryEmpty]), findsNothing);
    });
  });

  group('the upload toggle', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute('INSERT INTO user_config (id) VALUES (1)');
    });

    tearDown(() async {
      await helper.tearDown();
    });

    // Governing: SPEC-0016 REQ "Upload Toggle" — the gap #111 left open.
    test('is writable, and the read path sees the write', () async {
      expect(await ConfigRepository.getRommUploadScreenshots(), isTrue);

      await ConfigRepository.setRommUploadScreenshots(false);
      expect(await ConfigRepository.getRommUploadScreenshots(), isFalse);

      await ConfigRepository.setRommUploadScreenshots(true);
      expect(await ConfigRepository.getRommUploadScreenshots(), isTrue);
    });

    test('a write leaves the rest of the row alone', () async {
      await adapter.execute("UPDATE user_config SET theme_name = 'neon'");
      await ConfigRepository.setRommUploadScreenshots(false);
      final rows = await adapter.query('user_config');
      expect(rows.single['theme_name'], 'neon');
      expect(rows.single['romm_upload_screenshots'], 0);
    });

    test('the model defaults to on and round-trips', () {
      expect(const ConfigModel().rommUploadScreenshots, isTrue);

      final off = const ConfigModel().copyWith(rommUploadScreenshots: false);
      expect(off.rommUploadScreenshots, isFalse);
      expect(off.toJson()['rommUploadScreenshots'], isFalse);
      expect(ConfigModel.fromJson(off.toJson()).rommUploadScreenshots, isFalse);

      // A database that never reached v163 reads as the shipped default.
      expect(ConfigModel.fromJson(const {}).rommUploadScreenshots, isTrue);
      expect(
        ConfigModel.fromJson(const {
          'romm_upload_screenshots': 0,
        }).rommUploadScreenshots,
        isFalse,
      );
    });
  });

  group('localization', () {
    // Governing: SPEC-0016 REQ "Localized User-Facing Text"
    const keys = [
      AppLocale.rommGalleryTitle,
      AppLocale.rommGalleryEmpty,
      AppLocale.rommGalleryError,
      AppLocale.rommUploadScreenshots,
      AppLocale.rommUploadScreenshotsHint,
    ];

    final locales = <String, Map<String, dynamic>>{
      'en': AppLocale.en,
      'es': AppLocale.es,
      'ru': AppLocale.ru,
      'zh': AppLocale.zh,
      'zh_Hant': AppLocale.zhHant,
      'pt': AppLocale.pt,
      'fr': AppLocale.fr,
      'de': AppLocale.de,
      'it': AppLocale.it,
      'id': AppLocale.id,
      'ja': AppLocale.ja,
      'ko': AppLocale.ko,
    };

    test('every new key has a value in all twelve languages', () {
      expect(locales, hasLength(12));
      for (final entry in locales.entries) {
        for (final key in keys) {
          final value = entry.value[key];
          expect(
            value,
            isA<String>(),
            reason: '$key missing from ${entry.key}',
          );
          expect(
            (value as String).trim(),
            isNotEmpty,
            reason: '$key blank in ${entry.key}',
          );
        }
      }
    });

    test('the translations are not copied English', () {
      // Every language that does not share English's script should differ.
      for (final code in ['es', 'ru', 'zh', 'ja', 'ko', 'de', 'fr', 'it']) {
        for (final key in keys) {
          expect(
            locales[code]![key],
            isNot(AppLocale.en[key]),
            reason: '$key in $code is still the English string',
          );
        }
      }
    });
  });
}
