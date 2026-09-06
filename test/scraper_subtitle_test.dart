import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/scraper_subtitle.dart';

/// The Scraping pane's subtitle names the sources that are set up (SPEC-0006
/// "Entry Point Consistency"): ScreenScraper alone, RomM alone, or both.

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

void main() {
  test('names the sources that are set up', () {
    expect(
      scraperSubtitleKeyFor(rommConnected: false, screenScraperLoggedIn: true),
      AppLocale.scraperSubtitle,
    );
    expect(
      scraperSubtitleKeyFor(rommConnected: true, screenScraperLoggedIn: false),
      AppLocale.scraperSubtitleRomm,
    );
    expect(
      scraperSubtitleKeyFor(rommConnected: true, screenScraperLoggedIn: true),
      AppLocale.scraperSubtitleBoth,
    );
    expect(
      scraperSubtitleKeyFor(rommConnected: false, screenScraperLoggedIn: false),
      AppLocale.scraperSubtitle,
    );
  });

  test('keys exist in every language', () {
    for (final entry in _allLanguages.entries) {
      for (final key in [
        AppLocale.scraperSubtitleRomm,
        AppLocale.scraperSubtitleBoth,
      ]) {
        expect(entry.value[key], isNotEmpty, reason: '${entry.key}: $key');
      }
    }
  });
}
