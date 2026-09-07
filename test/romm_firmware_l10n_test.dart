import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The firmware panel's strings, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key set;
/// this pins the panel's own keys down by name and checks that each
/// translation kept the `{placeholder}` tokens the code substitutes — a
/// translation that drops `{file}` or renames `{system}` compiles and analyzes
/// cleanly but renders a line with a value missing from it.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Localized User-Facing Text"
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
    AppLocale.rommFirmwareRowTitle,
    AppLocale.rommFirmwareRowSubtitle,
    AppLocale.rommFirmwareRowRequiresConnection,
    AppLocale.rommFirmwarePanelTitle,
    AppLocale.rommFirmwareLoading,
    AppLocale.rommFirmwareEmpty,
    AppLocale.rommFirmwareScopeDenied,
    AppLocale.rommFirmwareListFailed,
    AppLocale.rommFirmwareStatePresent,
    AppLocale.rommFirmwareStateMissing,
    AppLocale.rommFirmwareStateServerMissing,
    AppLocale.rommFirmwareStateNoFolder,
    AppLocale.rommFirmwareVerifiedByServer,
    AppLocale.rommFirmwareVerifyChecking,
    AppLocale.rommFirmwareVerifyMatch,
    AppLocale.rommFirmwareVerifyMismatch,
    AppLocale.rommFirmwareVerifyUnreadable,
    AppLocale.rommFirmwareActionDownload,
    AppLocale.rommFirmwareActionVerify,
    AppLocale.rommFirmwareActionDownloadAll,
    AppLocale.rommFirmwareActionChooseFolder,
    AppLocale.rommFirmwareDestination,
    AppLocale.rommFirmwareDestinationMissing,
    AppLocale.rommFirmwareDestinationRetroArch,
    AppLocale.rommFirmwareFolderFailed,
    AppLocale.rommFirmwareDownloadProgress,
    AppLocale.rommFirmwareDownloadSummary,
    AppLocale.rommFirmwareDownloadCancelled,
    AppLocale.rommFirmwareDownloadFailedFile,
  ];

  final placeholder = RegExp(r'\{[a-zA-Z]+\}');
  Set<String> tokensOf(String value) =>
      placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

  for (final entry in locales.entries) {
    test('${entry.key} translates every firmware key', () {
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
  }

  test('the strings the panel interpolates carry their placeholders', () {
    expect(appLocaleEn[AppLocale.rommFirmwarePanelTitle], contains('{system}'));
    expect(appLocaleEn[AppLocale.rommFirmwareDestination], contains('{path}'));
    expect(
      appLocaleEn[AppLocale.rommFirmwareDestinationRetroArch],
      contains('{path}'),
    );
    expect(appLocaleEn[AppLocale.rommFirmwareListFailed], contains('{error}'));
    expect(
      tokensOf(appLocaleEn[AppLocale.rommFirmwareDownloadProgress] as String),
      {'{file}', '{done}', '{total}'},
    );
    expect(
      tokensOf(appLocaleEn[AppLocale.rommFirmwareDownloadSummary] as String),
      {'{downloaded}', '{failed}'},
    );
    expect(
      appLocaleEn[AppLocale.rommFirmwareDownloadCancelled],
      contains('{summary}'),
    );
    expect(
      appLocaleEn[AppLocale.rommFirmwareDownloadFailedFile],
      contains('{file}'),
    );
  });
}
