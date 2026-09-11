import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The ROM upload strings, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key
/// set; this pins the upload's own keys down by name and checks that each
/// translation kept the `{placeholder}` tokens the code substitutes — a
/// translation that drops `{size}` or renames `{name}` compiles and analyzes
/// cleanly but renders a line with a value missing from it.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Localized
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
    AppLocale.rommUploadMenuItem,
    AppLocale.rommUploadTitle,
    AppLocale.rommUploadSystemRowTitle,
    AppLocale.rommUploadSystemRowSubtitle,
    AppLocale.rommUploadSystemRowRunning,
    AppLocale.rommUploadConfirmBody,
    AppLocale.rommUploadConfirmAction,
    AppLocale.rommUploadPreparing,
    AppLocale.rommUploadProgress,
    AppLocale.rommUploadNoPlatform,
    AppLocale.rommUploadUnknownSystem,
    AppLocale.rommUploadAmbiguousPlatform,
    AppLocale.rommUploadNothingToUpload,
    AppLocale.rommUploadAlreadyLinked,
    AppLocale.rommUploadBusy,
    AppLocale.rommUploadNotOffered,
    AppLocale.rommUploadSummary,
    AppLocale.rommUploadSummaryCancelled,
    AppLocale.rommUploadSummaryDisconnected,
    AppLocale.rommUploadScanRequested,
    AppLocale.rommUploadScanPending,
    AppLocale.rommUploadLinkNow,
    AppLocale.rommUploadLinkNowResult,
    AppLocale.rommUploadLinkNowNothing,
    AppLocale.rommUploadMetadataPushed,
    AppLocale.rommUploadSkippedLine,
    AppLocale.rommUploadFailedLine,
    AppLocale.rommUploadMore,
    AppLocale.rommUploadSkipMultiFile,
    AppLocale.rommUploadSkipDiscContainer,
    AppLocale.rommUploadSkipMissing,
    AppLocale.rommUploadSkipEmpty,
    AppLocale.rommUploadSkipUnsendableName,
    AppLocale.rommUploadSkipAlreadyExists,
    AppLocale.rommUploadFailScopeDenied,
    AppLocale.rommUploadFailCancelled,
    AppLocale.rommUploadFailBusy,
    AppLocale.rommUploadFailGated,
    AppLocale.rommUploadFailOther,
  ];

  /// The placeholders the code substitutes into each templated string.
  const placeholders = <String, List<String>>{
    AppLocale.rommUploadSystemRowRunning: ['{name}', '{current}', '{total}'],
    AppLocale.rommUploadConfirmBody: ['{count}', '{size}'],
    AppLocale.rommUploadProgress: ['{name}', '{current}', '{total}'],
    AppLocale.rommUploadNoPlatform: ['{system}'],
    AppLocale.rommUploadUnknownSystem: ['{system}'],
    AppLocale.rommUploadAmbiguousPlatform: ['{system}', '{platforms}'],
    AppLocale.rommUploadNothingToUpload: ['{system}'],
    AppLocale.rommUploadSummary: ['{uploaded}', '{skipped}', '{failed}'],
    AppLocale.rommUploadSummaryCancelled: ['{summary}'],
    AppLocale.rommUploadSummaryDisconnected: ['{summary}'],
    AppLocale.rommUploadLinkNowResult: ['{count}'],
    AppLocale.rommUploadMetadataPushed: ['{count}'],
    AppLocale.rommUploadSkippedLine: ['{name}', '{reason}'],
    AppLocale.rommUploadFailedLine: ['{name}', '{reason}'],
    AppLocale.rommUploadMore: ['{count}'],
  };

  test('every language has every upload key, non-empty', () {
    for (final entry in locales.entries) {
      for (final key in keys) {
        final value = entry.value[key];
        expect(value, isA<String>(), reason: '${entry.key} lacks $key');
        expect(
          (value as String).trim(),
          isNotEmpty,
          reason: '${entry.key} $key',
        );
      }
    }
  });

  test('every translation keeps the placeholders the code substitutes', () {
    for (final entry in locales.entries) {
      for (final template in placeholders.entries) {
        final value = entry.value[template.key] as String;
        for (final token in template.value) {
          expect(
            value,
            contains(token),
            reason: '${entry.key} ${template.key} dropped $token',
          );
        }
      }
    }
  });

  test(
    'the two-sentence keys are distinct where the code needs them to be',
    () {
      // The menu item and the notification title may read the same, but the
      // per-file reasons must not collide with each other in any language.
      for (final entry in locales.entries) {
        final reasons = <String>{
          for (final key in const [
            AppLocale.rommUploadSkipMultiFile,
            AppLocale.rommUploadSkipDiscContainer,
            AppLocale.rommUploadSkipMissing,
            AppLocale.rommUploadSkipEmpty,
            AppLocale.rommUploadSkipUnsendableName,
            AppLocale.rommUploadSkipAlreadyExists,
          ])
            entry.value[key] as String,
        };
        expect(
          reasons.length,
          6,
          reason: '${entry.key} has a duplicate reason',
        );
      }
    },
  );

  // Governing: SPEC-0014 REQ "Localized User-Facing Text"; issue #235
  test('the three platform refusals read differently in every language', () {
    // One message for "the server has no platform", "this install has no
    // such system" and "several platforms fold onto one" is the bug #235
    // reported: the remedies differ, so the lines must too.
    for (final entry in locales.entries) {
      final refusals = <String>{
        for (final key in const [
          AppLocale.rommUploadNoPlatform,
          AppLocale.rommUploadUnknownSystem,
          AppLocale.rommUploadAmbiguousPlatform,
        ])
          entry.value[key] as String,
      };
      expect(
        refusals.length,
        3,
        reason: '${entry.key} repeats a platform refusal',
      );
    }
  });
}
