import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';

/// The unified library's settings, scope names, footer, notices, actions and
/// the remote-only system label, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key
/// set; this pins SPEC-0019's own keys down by name, checks nothing was left
/// as the English string, and checks each interpolated string kept its
/// `{scope}`, `{size}`, `{count}`, `{platforms}` and `{time}` tokens.
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
    AppLocale.rommShowLibrary,
    AppLocale.rommShowLibrarySubtitle,
    AppLocale.rommLibraryDefaultScope,
    AppLocale.rommLibraryDefaultScopeSubtitle,
    AppLocale.rommCoverCacheSize,
    AppLocale.rommCoverCacheSizeSubtitle,
    AppLocale.rommCoverCacheSizeValue,
    AppLocale.libraryScopeAll,
    AppLocale.libraryScopeDownloaded,
    AppLocale.libraryScopeFooter,
    AppLocale.libraryScopeToggle,
    AppLocale.libraryOfflineCached,
    AppLocale.rommRemoteOnlySystemLabel,
    AppLocale.rommRefreshLibraryNow,
    AppLocale.rommRefreshLibraryRunning,
    AppLocale.rommRefreshLibraryDone,
    AppLocale.rommRefreshLibraryFailed,
    AppLocale.rommRefreshLibraryUnavailable,
    AppLocale.rommClearCachedLibrary,
    AppLocale.rommClearCachedLibraryDone,
    AppLocale.rommCatalogAsOf,
    AppLocale.rommCatalogNeverRefreshed,
    AppLocale.rommRemoteNotDownloaded,
  ];

  final placeholder = RegExp(r'\{[a-zA-Z]+\}');
  Set<String> tokensOf(String value) =>
      placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

  test('English carries the placeholders the code substitutes', () {
    expect(tokensOf(appLocaleEn[AppLocale.libraryScopeFooter]), {'{scope}'});
    expect(tokensOf(appLocaleEn[AppLocale.rommCoverCacheSizeValue]), {
      '{size}',
    });
    expect(tokensOf(appLocaleEn[AppLocale.rommRefreshLibraryDone]), {
      '{count}',
      '{platforms}',
    });
    expect(tokensOf(appLocaleEn[AppLocale.rommCatalogAsOf]), {'{time}'});
  });

  for (final entry in locales.entries) {
    test('${entry.key} translates every SPEC-0019 key', () {
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

    if (entry.key != 'en') {
      test('${entry.key} is not a copy of the English sentences', () {
        final copied = [
          for (final key in keys)
            if ((appLocaleEn[key] as String).split(' ').length > 3 &&
                entry.value[key] == appLocaleEn[key])
              key,
        ];
        expect(
          copied,
          isEmpty,
          reason: 'untranslated English in app_locale_${entry.key}.dart',
        );
      });
    }
  }
}
