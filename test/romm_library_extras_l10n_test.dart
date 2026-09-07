import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_rom_filters.dart';
import 'package:neostation/widgets/romm_filter_menu_dialog.dart';
import 'package:neostation/widgets/romm_maintenance_menu_dialog.dart';

/// The filter menu, "Surprise me" and the maintenance menu, in every language.
///
/// `app_locale_test.dart` already proves the twelve maps hold the same key set;
/// this pins SPEC-0018's own keys down by name, checks nothing was left as the
/// English string, and checks the one interpolated string kept its `{name}`
/// token. It also walks the two enums, so a filter or a task added later
/// without a label fails here rather than rendering a raw key on the device.
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
    AppLocale.rommFilterMenuTitle,
    AppLocale.rommFilterMenuAction,
    AppLocale.rommFilterFavorites,
    AppLocale.rommFilterHasSaves,
    AppLocale.rommFilterHasStates,
    AppLocale.rommFilterHasAchievements,
    AppLocale.rommFilterPlayable,
    AppLocale.rommFilterDuplicates,
    AppLocale.rommFilterMissing,
    AppLocale.rommFilterChipsLabel,
    AppLocale.rommFilterClearAll,
    AppLocale.rommFilterNoMatches,
    AppLocale.rommSurpriseMe,
    AppLocale.rommSurpriseMeEmpty,
    AppLocale.rommSurpriseMeUnsupported,
    AppLocale.rommSurpriseMeFailed,
    AppLocale.rommSurpriseMePicked,
    AppLocale.rommMaintenanceTitle,
    AppLocale.rommMaintenanceRescan,
    AppLocale.rommMaintenanceRescanConfirm,
    AppLocale.rommMaintenanceSyncFolders,
    AppLocale.rommMaintenanceSyncFoldersConfirm,
    AppLocale.rommMaintenanceCleanup,
    AppLocale.rommMaintenanceCleanupConfirm,
    AppLocale.rommMaintenanceRun,
    AppLocale.rommMaintenanceQueued,
    AppLocale.rommMaintenanceBusy,
    AppLocale.rommMaintenanceFailed,
  ];

  final placeholder = RegExp(r'\{[a-zA-Z]+\}');
  Set<String> tokensOf(String value) =>
      placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

  for (final entry in locales.entries) {
    test('${entry.key} translates every SPEC-0018 key', () {
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
        // The multi-word sentences are the ones a copy-paste would show up in;
        // a one-word label can legitimately be identical (e.g. "Filter" in de).
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

  test('every filter has a label key', () {
    for (final filter in RommRomFilter.values) {
      final key = RommFilterMenuDialog.labelKeyFor(filter);
      expect(keys, contains(key), reason: '${filter.name} label is not pinned');
      expect(appLocaleEn[key], isA<String>());
    }
  });

  test('every maintenance task has a label and a confirmation body', () {
    for (final task in RommMaintenanceTask.values) {
      expect(appLocaleEn[task.labelKey], isA<String>(), reason: task.name);
      expect(
        appLocaleEn[task.confirmBodyKey],
        isA<String>(),
        reason: task.name,
      );
    }
  });

  test('the picked-ROM toast carries its {name} placeholder', () {
    expect(appLocaleEn[AppLocale.rommSurpriseMePicked], contains('{name}'));
  });
}
