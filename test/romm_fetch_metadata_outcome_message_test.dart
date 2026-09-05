import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/utils/romm_fetch_metadata_message.dart';

/// The Manage tab's outcome-to-notification choice for "Fetch metadata from
/// RomM" (SPEC-0005 "Per-Game Fetch Action"), as a pure function: every
/// outcome kind maps to one `AppLocale` key, the right placeholders, and a
/// tone, and `format` resolves and substitutes them.

// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-Game Fetch Action"

void main() {
  group('rommFetchMetadataMessageFor', () {
    test('filled with counts reports what was filled as a success', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.filled,
          columnsWritten: 3,
          mediaWritten: 2,
          mediaSkipped: 1,
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataFilled);
      expect(message.placeholders, {'count': '3', 'media': '2'});
      expect(message.tone, RommFetchMetadataTone.success);
    });

    test('filled with nothing written reads as nothing to fill', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.filled,
          mediaSkipped: 4,
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataNothingToFill);
      expect(message.placeholders, isEmpty);
      expect(message.tone, RommFetchMetadataTone.info);
    });

    test('filled with only media written is still a fill', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.filled,
          mediaWritten: 1,
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataFilled);
      expect(message.placeholders, {'count': '0', 'media': '1'});
    });

    test('replaced reports its counts as a success, even when zero', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.replaced,
          columnsWritten: 7,
          mediaWritten: 0,
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataReplaced);
      expect(message.placeholders, {'count': '7', 'media': '0'});
      expect(message.tone, RommFetchMetadataTone.success);
    });

    test('not found is an error with no placeholders', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome.notFound(),
      );
      expect(message.key, AppLocale.rommFetchMetadataNotFound);
      expect(message.placeholders, isEmpty);
      expect(message.tone, RommFetchMetadataTone.error);
    });

    test('partial names the columns written and the media that failed', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.partial,
          columnsWritten: 5,
          mediaWritten: 1,
          mediaFailed: 2,
          error: 'boom',
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataPartial);
      expect(message.placeholders, {'count': '5', 'media': '2'});
      expect(message.tone, RommFetchMetadataTone.info);
    });

    test('failed is an error with no placeholders', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome.failed('server down'),
      );
      expect(message.key, AppLocale.rommFetchMetadataFailed);
      expect(message.placeholders, isEmpty);
      expect(message.tone, RommFetchMetadataTone.error);
    });

    test('a not-linked failure is reported as failed, not as not found', () {
      final message = rommFetchMetadataMessageFor(
        const RommMetadataOutcome.failed(
          RommMetadataFetchException.notLinked('a.sfc'),
        ),
      );
      expect(message.key, AppLocale.rommFetchMetadataFailed);
    });
  });

  group('RommFetchMetadataMessage.format', () {
    test('resolves the key and substitutes every placeholder', () {
      const message = RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataFilled,
        placeholders: {'count': '3', 'media': '2'},
        tone: RommFetchMetadataTone.success,
      );
      final text = message.format((key) => AppLocale.en[key] as String);
      expect(text, 'Filled 3 fields and 2 artwork from RomM');
      expect(text, isNot(contains('{')));
    });

    test('every outcome key resolves in every language', () {
      final keys = {
        AppLocale.rommFetchMetadataFilled,
        AppLocale.rommFetchMetadataReplaced,
        AppLocale.rommFetchMetadataNothingToFill,
        AppLocale.rommFetchMetadataNotFound,
        AppLocale.rommFetchMetadataPartial,
        AppLocale.rommFetchMetadataFailed,
      };
      final maps = {
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
      for (final entry in maps.entries) {
        for (final key in keys) {
          expect(
            entry.value[key],
            isA<String>().having((s) => s.isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
        }
        // The counted messages keep both placeholders in every language.
        for (final key in [
          AppLocale.rommFetchMetadataFilled,
          AppLocale.rommFetchMetadataReplaced,
          AppLocale.rommFetchMetadataPartial,
        ]) {
          expect(entry.value[key], contains('{count}'), reason: entry.key);
          expect(entry.value[key], contains('{media}'), reason: entry.key);
        }
      }
    });
  });
}
