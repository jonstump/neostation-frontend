import '../l10n/app_locale.dart';

/// Which "download game metadata from …" line the Scraping pane shows.
///
/// The scrape tries RomM first and falls back to ScreenScraper, so
/// the subtitle names whichever sources are actually set up rather than always
/// crediting ScreenScraper.
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
