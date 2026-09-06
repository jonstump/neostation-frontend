import '../l10n/app_locale.dart';

/// Which "download game metadata from …" line the Scraping pane shows.
///
/// The scrape tries RomM first and falls back to ScreenScraper (ADR-0006), so
/// the subtitle names whichever sources are actually set up rather than always
/// crediting ScreenScraper.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
String scraperSubtitleKeyFor({
  required bool rommConnected,
  required bool screenScraperLoggedIn,
}) {
  if (rommConnected && screenScraperLoggedIn) {
    return AppLocale.scraperSubtitleBoth;
  }
  if (rommConnected) return AppLocale.scraperSubtitleRomm;
  return AppLocale.scraperSubtitle;
}
