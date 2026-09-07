import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_manual.dart';
import 'package:neostation/models/romm_rom.dart';

/// Model parse, manual typing, and the localized strings the manual flow uses.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
void main() {
  Map<String, dynamic> romJson({
    Object? pathManual = 'roms/snes/Chrono Trigger/manual.pdf',
    Object? hasManual = true,
  }) => {
    'id': 42,
    'name': 'Chrono Trigger',
    'platform_id': 3,
    'platform_slug': 'snes',
    'fs_name': 'Chrono Trigger.sfc',
    'fs_name_no_ext': 'Chrono Trigger',
    'fs_extension': 'sfc',
    'path_manual': pathManual,
    'has_manual': hasManual,
  };

  group('RommRom manual parsing', () {
    test('parses path_manual and has_manual', () {
      final rom = RommRom.fromJson(romJson());

      expect(rom.pathManual, 'roms/snes/Chrono Trigger/manual.pdf');
      expect(rom.hasManual, isTrue);
      expect(rom.manual, isNotNull);
      expect(rom.manual!.extension, 'pdf');
      expect(rom.manual!.kind, RommManualKind.pdf);
    });

    test('a ROM without a manual has none', () {
      final rom = RommRom.fromJson(romJson(pathManual: null, hasManual: false));

      expect(rom.pathManual, isNull);
      expect(rom.hasManual, isFalse);
      expect(rom.manual, isNull);
    });

    test('an empty path_manual is no manual, not an empty one', () {
      final rom = RommRom.fromJson(romJson(pathManual: '   '));

      expect(rom.pathManual, isNull);
      expect(rom.manual, isNull);
    });

    test('has_manual without a path is still nothing to fetch', () {
      final rom = RommRom.fromJson(romJson(pathManual: null));

      expect(rom.hasManual, isTrue);
      expect(rom.manual, isNull);
    });

    test('older list rows without the fields parse unchanged', () {
      final json = romJson()
        ..remove('path_manual')
        ..remove('has_manual');
      final rom = RommRom.fromJson(json);

      expect(rom.id, 42);
      expect(rom.pathManual, isNull);
      expect(rom.hasManual, isFalse);
    });
  });

  group('RommManual', () {
    test('strips a leading slash so the path is server-relative', () {
      expect(RommManual.fromPath('/manuals/a.pdf')!.path, 'manuals/a.pdf');
    });

    test('types the three accepted extensions', () {
      expect(RommManual.fromPath('a.pdf')!.kind, RommManualKind.pdf);
      expect(RommManual.fromPath('a.txt')!.kind, RommManualKind.text);
      expect(RommManual.fromPath('a.md')!.kind, RommManualKind.markdown);
    });

    test('is case-insensitive about the extension', () {
      final manual = RommManual.fromPath('manuals/Manual.PDF')!;
      expect(manual.extension, 'pdf');
      expect(manual.isSupported, isTrue);
    });

    test('refuses anything else', () {
      final manual = RommManual.fromPath('manuals/manual.docx')!;
      expect(manual.kind, RommManualKind.unsupported);
      expect(manual.isSupported, isFalse);
    });

    test('a dotted directory does not lend its suffix to the file', () {
      final manual = RommManual.fromPath('manuals.v2/README')!;
      expect(manual.extension, '');
      expect(manual.isSupported, isFalse);
    });

    test('caches under the rom id, not the remote file name', () {
      final manual = RommManual.fromPath('some/where/scan_final.pdf')!;
      expect(manual.cacheFileName(42), '42.pdf');
    });

    test('null and blank paths mean no manual', () {
      expect(RommManual.fromPath(null), isNull);
      expect(RommManual.fromPath(''), isNull);
      expect(RommManual.fromPath('/'), isNull);
    });
  });

  group('manual strings', () {
    const maps = <String, Map<String, dynamic>>{
      'en': AppLocale.en,
      'es': AppLocale.es,
      'ru': AppLocale.ru,
      'zh': AppLocale.zh,
      'zh_Hant': AppLocale.zhHant,
      'pt': AppLocale.pt,
      'fr': AppLocale.fr,
      'de': AppLocale.de,
      'it': AppLocale.it,
      'id': AppLocale.id,
      'ja': AppLocale.ja,
      'ko': AppLocale.ko,
    };

    const keys = [
      AppLocale.manual,
      AppLocale.manualRefresh,
      AppLocale.manualDownloading,
      AppLocale.manualNotAvailable,
      AppLocale.manualUnsupportedType,
      AppLocale.manualOpenExternally,
      AppLocale.manualPageIndicator,
      AppLocale.manualRenderFailed,
      AppLocale.manualOpenExternallyFailed,
    ];

    for (final entry in maps.entries) {
      test('${entry.key} defines every manual string, non-empty', () {
        for (final key in keys) {
          final value = entry.value[key];
          expect(value, isA<String>(), reason: '$key missing in ${entry.key}');
          expect(
            (value as String).trim(),
            isNotEmpty,
            reason: '$key empty in ${entry.key}',
          );
        }
      });

      test('${entry.key} keeps the manual placeholders', () {
        expect(
          entry.value[AppLocale.manualPageIndicator],
          allOf(contains('{page}'), contains('{total}')),
          reason: 'page indicator placeholders in ${entry.key}',
        );
        expect(
          entry.value[AppLocale.manualUnsupportedType],
          contains('{extension}'),
          reason: 'extension placeholder in ${entry.key}',
        );
      });
    }

    test('the page indicator interpolates to 4/10', () {
      final label = (AppLocale.en[AppLocale.manualPageIndicator] as String)
          .replaceFirst('{page}', '4')
          .replaceFirst('{total}', '10');
      expect(label, '4/10');
    });
  });
}
