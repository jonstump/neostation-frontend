import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/utils/scrape_result_message.dart';

/// The per-game entry points' result-to-notification choice (SPEC-0006
/// "Entry Point Consistency"), as a pure function: every combination of
/// `success` / `source` / `rommAttempted` maps to one `AppLocale` key and a
/// tone, a failure carries the service's message as its reason, and `format`
/// resolves and substitutes them.

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"

const _allLanguages = {
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

Map<String, dynamic> _result({
  required bool success,
  required String source,
  required bool rommAttempted,
  String? message,
}) => {
  'success': success,
  'message': ?message,
  'source': source,
  'rommAttempted': rommAttempted,
};

void main() {
  group('scrapeResultMessageFor', () {
    test('a RomM success says the game was scraped from RomM', () {
      final message = scrapeResultMessageFor(
        _result(
          success: true,
          source: ScreenScraperService.scrapeSourceRomm,
          rommAttempted: true,
          message: AppLocale.scrapeSuccessful,
        ),
      );
      expect(message.key, AppLocale.scrapeCompletedFromRomm);
      expect(message.placeholders, isEmpty);
      expect(message.localizedPlaceholders, isEmpty);
      expect(message.tone, ScrapeResultTone.success);
    });

    test('a ScreenScraper success after RomM fell through names both', () {
      final message = scrapeResultMessageFor(
        _result(
          success: true,
          source: ScreenScraperService.scrapeSourceScreenscraper,
          rommAttempted: true,
          message: AppLocale.scrapeSuccessful,
        ),
      );
      expect(message.key, AppLocale.scrapeCompletedFallback);
      expect(message.tone, ScrapeResultTone.success);
    });

    test('a ScreenScraper success without RomM names ScreenScraper', () {
      final message = scrapeResultMessageFor(
        _result(
          success: true,
          source: ScreenScraperService.scrapeSourceScreenscraper,
          rommAttempted: false,
          message: AppLocale.scrapeSuccessful,
        ),
      );
      expect(message.key, AppLocale.scrapeCompletedFromScreenscraper);
      expect(message.tone, ScrapeResultTone.success);
    });

    test('a failure wraps the service message key as the reason', () {
      final message = scrapeResultMessageFor(
        _result(
          success: false,
          source: ScreenScraperService.scrapeSourceScreenscraper,
          rommAttempted: true,
          message: AppLocale.scrapeNoCredentials,
        ),
      );
      expect(message.key, AppLocale.scrapeFailedWithReason);
      expect(message.localizedPlaceholders, {
        'reason': AppLocale.scrapeNoCredentials,
      });
      expect(message.tone, ScrapeResultTone.error);
    });

    test('a failure with no message reads as an unexpected error', () {
      for (final result in [
        _result(
          success: false,
          source: ScreenScraperService.scrapeSourceScreenscraper,
          rommAttempted: false,
        ),
        {'success': false, 'message': ''},
        {'success': false, 'message': null},
      ]) {
        final message = scrapeResultMessageFor(result);
        expect(message.key, AppLocale.scrapeFailedWithReason);
        expect(message.localizedPlaceholders, {
          'reason': AppLocale.scrapeUnexpectedError,
        });
        expect(message.tone, ScrapeResultTone.error);
      }
    });

    test('a success with no source or attempt flag names ScreenScraper', () {
      // The pre-#49 result shape: only `success` and `message`.
      final message = scrapeResultMessageFor({
        'success': true,
        'message': AppLocale.scrapeSuccessful,
      });
      expect(message.key, AppLocale.scrapeCompletedFromScreenscraper);
    });
  });

  group('ScrapeResultMessage.format', () {
    String en(String key) => AppLocale.en[key] as String;

    test('resolves the key and substitutes a localized reason', () {
      final message = scrapeResultMessageFor(
        _result(
          success: false,
          source: ScreenScraperService.scrapeSourceScreenscraper,
          rommAttempted: true,
          message: AppLocale.scrapeNoCredentials,
        ),
      );
      final text = message.format(en);
      expect(
        text,
        'Scraping failed: No ScreenScraper credentials found. Please log in.',
      );
      expect(text, isNot(contains('{')));
    });

    test('substitutes verbatim placeholders before localized ones', () {
      const message = ScrapeResultMessage(
        key: AppLocale.scrapeFailedWithReason,
        placeholders: {'reason': 'disk full'},
        tone: ScrapeResultTone.error,
      );
      expect(message.format(en), 'Scraping failed: disk full');
    });

    test('a success resolves without placeholders in every language', () {
      for (final entry in _allLanguages.entries) {
        for (final source in [
          ScreenScraperService.scrapeSourceRomm,
          ScreenScraperService.scrapeSourceScreenscraper,
        ]) {
          for (final attempted in [true, false]) {
            final message = scrapeResultMessageFor(
              _result(success: true, source: source, rommAttempted: attempted),
            );
            final text = message.format((k) => entry.value[k] as String);
            expect(text, isNotEmpty, reason: '${entry.key} $source');
            expect(text, isNot(contains('{')), reason: entry.key);
          }
        }
      }
    });

    test('every notification key resolves in every language', () {
      final keys = {
        AppLocale.scrapeCompletedFromRomm,
        AppLocale.scrapeCompletedFromScreenscraper,
        AppLocale.scrapeCompletedFallback,
        AppLocale.scrapeFailedWithReason,
        AppLocale.scrapeSystemIdMissing,
      };
      for (final entry in _allLanguages.entries) {
        for (final key in keys) {
          expect(
            entry.value[key],
            isA<String>().having((s) => s.isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
        }
        // The failure message keeps its reason placeholder in every language.
        expect(
          entry.value[AppLocale.scrapeFailedWithReason],
          contains('{reason}'),
          reason: entry.key,
        );
      }
    });
  });
}
