import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The fix-up flow's strings, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key
/// set; this pins these keys down by name and checks the `{name}` token the
/// confirmation substitutes — a translation that drops it compiles and
/// analyzes cleanly but asks the user to confirm a write without saying what
/// is about to change, which is the whole point of the confirmation.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Localized User-Facing Text"
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
    AppLocale.rommFixMatchAction,
    AppLocale.rommChangeCoverAction,
    AppLocale.rommFixMatchTitle,
    AppLocale.rommChangeCoverTitle,
    AppLocale.rommFixMatchSearchHint,
    AppLocale.rommFixMatchLoading,
    AppLocale.rommFixMatchNoResults,
    AppLocale.rommFixMatchNoSource,
    AppLocale.rommFixMatchFailed,
    AppLocale.rommFixMatchConfirmTitle,
    AppLocale.rommFixMatchConfirmBody,
    AppLocale.rommChangeCoverConfirmTitle,
    AppLocale.rommChangeCoverConfirmBody,
    AppLocale.rommFixMatchApply,
    AppLocale.rommFixMatchApplying,
    AppLocale.rommFixMatchApplied,
    AppLocale.rommChangeCoverApplied,
    AppLocale.rommFixMatchApplyFailed,
  ];

  final placeholder = RegExp(r'\{[a-zA-Z]+\}');
  Set<String> tokensOf(String value) =>
      placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

  for (final entry in locales.entries) {
    test('${entry.key} translates every fix-up key', () {
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

    test('${entry.key} names what the write will change', () {
      for (final key in [
        AppLocale.rommFixMatchConfirmBody,
        AppLocale.rommChangeCoverConfirmBody,
      ]) {
        expect(
          entry.value[key] as String,
          contains('{name}'),
          reason:
              '$key must name the game in app_locale_${entry.key}.dart: the '
              'confirmation guards a write to the user\'s server',
        );
      }
    });
  }

  test('only the confirmations interpolate anything', () {
    for (final key in keys) {
      final tokens = tokensOf(appLocaleEn[key] as String);
      final expected =
          key == AppLocale.rommFixMatchConfirmBody ||
              key == AppLocale.rommChangeCoverConfirmBody
          ? {'{name}'}
          : <String>{};
      expect(tokens, expected, reason: key);
    }
  });
}
