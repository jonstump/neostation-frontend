import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_collection.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// The browse screen's three load failures ("Failed to load platforms /
/// collections / ROMs") are sentences [RommProvider] words itself, so — like
/// every other message it authors — they must reach the user through an
/// `AppLocale` key rather than as the English kept in [RommProvider.lastError]
/// for the logs.
///
/// The second group pins the invariant the whole mechanism rests on: recording
/// a plain message *clears* the localized form, so a translated sentence can
/// never outlive the failure it described. A fresh provider satisfies that
/// assertion trivially, so it is exercised here on one instance that has
/// already carried a localized error.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Localized
/// User-Facing Text"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const favourites = RommCollection(id: '3', name: 'Favourites', romCount: 1);

  /// Answers every read endpoint with [respond]; anything else is a 404.
  void serve(http.Response Function(String path) respond) {
    RommService.debugUseHttpClient(
      MockClient((request) async => respond(request.url.path)),
    );
  }

  /// A 200 whose body is not JSON: the decode throws a [FormatException],
  /// which is exactly the non-[RommException] failure the provider has to word
  /// itself. A [RommException] carries a server-authored message instead.
  http.Response garbage() => http.Response('<html>nope</html>', 200);

  RommProvider provider() {
    final p = RommProvider();
    p.service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
    return p;
  }

  tearDown(() => RommService.debugUseHttpClient(null));

  group('a load failure the provider words itself is translatable', () {
    test(
      'loadPlatforms records the key and the raw error as its detail',
      () async {
        serve((_) => garbage());
        final p = provider();

        await p.loadPlatforms();

        expect(
          p.lastErrorLocalized?.localeKey,
          AppLocale.rommLoadPlatformsFailedDetail,
        );
        expect(p.lastErrorLocalized?.detail, isNotNull);
        expect(
          p.lastError,
          startsWith('Failed to load platforms:'),
          reason: 'the English sentence stays behind for the log',
        );
        // The widget layer's substitution, without a BuildContext.
        expect(
          p.lastErrorLocalized!.format(
            'Échec du chargement des plateformes : {error}',
          ),
          startsWith('Échec du chargement des plateformes : '),
        );
      },
    );

    test('loadCollections records its own key', () async {
      serve((_) => garbage());
      final p = provider();

      await p.loadCollections();

      expect(
        p.lastErrorLocalized?.localeKey,
        AppLocale.rommLoadCollectionsFailedDetail,
      );
      expect(p.lastError, startsWith('Failed to load collections:'));
    });

    test('a ROM page records its own key', () async {
      serve((_) => garbage());
      final p = provider();

      await p.selectCollection(favourites);

      expect(
        p.lastErrorLocalized?.localeKey,
        AppLocale.rommLoadRomsFailedDetail,
      );
      expect(p.lastError, startsWith('Failed to load ROMs:'));
    });

    test(
      'a RommException keeps the server\'s own message untranslated',
      () async {
        serve((_) => http.Response('boom', 500));
        final p = provider();

        await p.loadPlatforms();

        expect(p.lastError, 'Request failed (500)');
        expect(
          p.lastErrorLocalized,
          isNull,
          reason: 'RommException.message is already user-facing',
        );
      },
    );
  });

  group('lastError and lastErrorLocalized never describe two failures', () {
    test('a plain message recorded after a localized one clears it', () async {
      // One provider, two failures in sequence, and deliberately a second
      // failure whose handler does *not* reset the error first: [surpriseMe]
      // assigns [RommException.message] straight onto the last-error pair.
      // The clear therefore has to come from the setter itself — which is the
      // invariant. Swap that assignment for a direct `_lastErrorMessage =`
      // and this test fails with the ROM-load translation still attached to a
      // surprise-pick failure, which is the silent, user-visible regression
      // it exists to catch.
      var body = garbage();
      serve((_) => body);
      final p = provider();

      // A localized error, and a current collection for the pick to run in.
      await p.selectCollection(favourites);
      expect(
        p.lastErrorLocalized?.localeKey,
        AppLocale.rommLoadRomsFailedDetail,
        reason: 'precondition: a translatable error is attached',
      );

      body = http.Response('boom', 500);
      await p.surpriseMe();

      expect(p.lastError, 'Request failed (500)');
      expect(
        p.lastErrorLocalized,
        isNull,
        reason: 'the stale translation must not outlive the error it described',
      );
    });
  });
}
