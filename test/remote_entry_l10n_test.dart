import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The remote entry strings — badges, the download confirmation, the offline
/// notice, the Play-now prompt, the second screen's state line — in every
/// language, with the `{placeholder}` tokens the code substitutes intact.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Localized
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
    AppLocale.rommRemoteBadge,
    AppLocale.rommRemoteRetryBadge,
    AppLocale.rommRemoteDownloadingBadge,
    AppLocale.rommRemoteDownloadingIndeterminate,
    AppLocale.rommRemoteCancelDownload,
    AppLocale.rommRemoteDownloadConfirmTitle,
    AppLocale.rommRemoteDownloadConfirmBody,
    AppLocale.rommRemoteSizeUnknown,
    AppLocale.rommRemoteCancelConfirmTitle,
    AppLocale.rommRemoteCancelConfirmBody,
    AppLocale.rommRemoteOfflineNotice,
    AppLocale.rommRemotePlayNow,
    AppLocale.rommRemotePlayLater,
    AppLocale.rommRemoteDownloadReadyTitle,
    AppLocale.rommRemoteDownloadReadyBody,
    AppLocale.rommRemoteSecondaryState,
  ];

  const placeholders = <String, List<String>>{
    AppLocale.rommRemoteDownloadingBadge: ['{percent}'],
    AppLocale.rommRemoteDownloadConfirmBody: ['{name}', '{size}', '{folder}'],
    AppLocale.rommRemoteCancelConfirmBody: ['{name}'],
    AppLocale.rommRemoteDownloadReadyBody: ['{name}'],
  };

  test('every language carries every remote entry key', () {
    for (final entry in locales.entries) {
      for (final key in keys) {
        expect(
          entry.value[key],
          isA<String>().having((s) => s.trim(), 'text', isNotEmpty),
          reason: '${entry.key} is missing $key',
        );
      }
    }
  });

  test('every translation keeps the placeholders the code substitutes', () {
    for (final entry in locales.entries) {
      for (final placeholder in placeholders.entries) {
        final text = entry.value[placeholder.key] as String;
        for (final token in placeholder.value) {
          expect(
            text,
            contains(token),
            reason: '${entry.key} ${placeholder.key} lost $token',
          );
        }
      }
    }
  });

  test('the twelve maps share one key set', () {
    final reference = appLocaleEn.keys.toSet();
    for (final entry in locales.entries) {
      expect(
        entry.value.keys.toSet(),
        reference,
        reason: '${entry.key} differs from en',
      );
    }
  });
}
