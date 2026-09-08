import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/app_locale_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [resolveAppLocale] reads the map for whatever language the app is showing,
/// keyed the way `main.dart` registers it. The `zh_Hant` entry is the one that
/// depends on [FlutterLocalization] keeping the underscore in `languageCode`;
/// this pins it, and the English fallback for a code no map holds.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Localized
/// User-Facing Text"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = AppLocale.rommFavoritesCollectionName;

  /// A key whose Traditional and Simplified values differ (the favourites
  /// name is the same two characters in both), so a wrong map is visible.
  const scriptKey = AppLocale.rommPushPlayState;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [
        MapLocale('en', AppLocale.en),
        MapLocale('es', AppLocale.es),
        MapLocale('pt', AppLocale.pt),
        MapLocale('ru', AppLocale.ru),
        MapLocale('zh', AppLocale.zh),
        MapLocale('zh_Hant', AppLocale.zhHant),
        MapLocale('fr', AppLocale.fr),
        MapLocale('de', AppLocale.de),
        MapLocale('it', AppLocale.it),
        MapLocale('id', AppLocale.id),
        MapLocale('ja', AppLocale.ja),
        MapLocale('ko', AppLocale.ko),
        // A language the package accepts but no resolver map holds, so the
        // English fallback is reachable ([FlutterLocalization.translate]
        // refuses a code that was never registered).
        const MapLocale('xx', <String, dynamic>{}),
      ],
      initLanguageCode: 'en',
    );
  });

  test('zh_Hant resolves to the Traditional map, not the Simplified one', () {
    FlutterLocalization.instance.translate('zh_Hant', save: false);
    expect(FlutterLocalization.instance.currentLocale?.languageCode, 'zh_Hant');
    expect(resolveAppLocale(key), appLocaleZhHant[key]);
    expect(resolveAppLocale(scriptKey), appLocaleZhHant[scriptKey]);
    expect(resolveAppLocale(scriptKey), isNot(appLocaleZh[scriptKey]));
  });

  test('zh resolves to the Simplified map', () {
    FlutterLocalization.instance.translate('zh', save: false);
    expect(resolveAppLocale(scriptKey), appLocaleZh[scriptKey]);
  });

  test('a language the resolver has no map for falls back to English', () {
    FlutterLocalization.instance.translate('xx', save: false);
    expect(FlutterLocalization.instance.currentLocale?.languageCode, 'xx');
    expect(resolveAppLocale(key), appLocaleEn[key]);
    expect(resolveAppLocale('no_such_key'), 'no_such_key');
  });
}
