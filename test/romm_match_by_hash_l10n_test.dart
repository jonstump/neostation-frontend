import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The "Match by hash" strings, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key
/// set; this pins these keys down by name and checks the `{reason}` token the
/// skip line substitutes — a translation that drops it compiles and analyzes
/// cleanly but tells the user their file could not be hashed without saying
/// why.
///
/// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Localized
/// User-Facing Text"
void main() {
  const locales = <String, Map<String, dynamic>>{
    'en': appLocaleEn,
    'es': appLocaleEs,
    'pt': appLocalePt,
    'ru': appLocaleRu,
    'zh': appLocaleZh,
    'zh_Hant': appLocaleZhHant,
    'fr': appLocaleFr,
    'de': appLocaleDe,
    'it': appLocaleIt,
    'id': appLocaleId,
    'ja': appLocaleJa,
    'ko': appLocaleKo,
  };

  const keys = <String>[
    AppLocale.rommMatchByHash,
    AppLocale.rommMatchByHashBusy,
    AppLocale.rommMatchByHashNoMatch,
    AppLocale.rommMatchByHashSkipped,
    AppLocale.rommMatchByHashFailed,
    AppLocale.rommMatchByHashReasonDisc,
    AppLocale.rommMatchByHashReasonOversize,
    AppLocale.rommMatchByHashReasonMissing,
    AppLocale.rommMatchByHashReasonExtractFailed,
    AppLocale.rommMatchByHashReasonError,
  ];

  final placeholder = RegExp(r'\{[a-zA-Z]+\}');
  Set<String> tokensOf(String value) =>
      placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

  for (final entry in locales.entries) {
    test('${entry.key} translates every match-by-hash key', () {
      for (final key in keys) {
        final value = entry.value[key];
        expect(
          value,
          isA<String>(),
          reason: '$key is missing from app_locale_${entry.key}.dart',
        );
        expect(
          (value as String).trim(),
          isNotEmpty,
          reason: '$key is blank in app_locale_${entry.key}.dart',
        );
      }
    });

    test('${entry.key} keeps every placeholder', () {
      for (final key in keys) {
        expect(
          tokensOf(entry.value[key] as String),
          tokensOf(appLocaleEn[key] as String),
          reason:
              '$key has drifted placeholders in app_locale_${entry.key}.dart',
        );
      }
    });

    test('${entry.key} says why the file could not be hashed', () {
      expect(
        entry.value[AppLocale.rommMatchByHashSkipped] as String,
        contains('{reason}'),
      );
    });
  }
}
