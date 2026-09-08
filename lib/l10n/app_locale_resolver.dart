import 'package:flutter_localization/flutter_localization.dart';

import 'app_locale.dart';

/// The twelve maps keyed the way `main.dart` registers them with
/// [FlutterLocalization] (`MapLocale('zh_Hant', …)` keeps the underscore as
/// its language code, so the current locale reports it the same way).
const Map<String, Map<String, dynamic>> _mapsByLanguageCode = {
  'en': AppLocale.en,
  'es': AppLocale.es,
  'pt': AppLocale.pt,
  'ru': AppLocale.ru,
  'zh': AppLocale.zh,
  'zh_Hant': AppLocale.zhHant,
  'fr': AppLocale.fr,
  'de': AppLocale.de,
  'it': AppLocale.it,
  'id': AppLocale.id,
  'ja': AppLocale.ja,
  'ko': AppLocale.ko,
};

/// Resolves an [AppLocale] key without a `BuildContext`.
///
/// `AppLocale.<key>.getString(context)` is the rule for UI text, but a few
/// strings are consumed where no widget exists: the name a RomM favourites
/// collection is created with is decided inside a background flush that runs
/// from the provider's connect path. The language the app is showing is a
/// process-wide fact ([FlutterLocalization.currentLocale]), so the matching
/// map is read directly; before the first language is chosen (a unit test, or
/// a call before startup finishes) the English value stands in, and a key no
/// map holds comes back as itself rather than as a crash.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Localized User-Facing Text"
String resolveAppLocale(String key) {
  final code = FlutterLocalization.instance.currentLocale?.languageCode;
  final map = _mapsByLanguageCode[code] ?? AppLocale.en;
  final value = map[key] ?? AppLocale.en[key];
  return value == null ? key : value.toString();
}
