/// Which screen the scraper tab should show.
enum ScraperEntry { options, login }

/// Decides between the scraper options and the ScreenScraper login screen.
///
/// ScreenScraper credentials always open the options. Without them, a
/// connected RomM server is a scrape source on its own (ADR-0006), so the
/// options open too, unless the user explicitly asked for the ScreenScraper
/// login from the Account pane. With neither, only the login makes sense.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
ScraperEntry scraperEntryFor({
  required bool hasScreenscraperCredentials,
  required bool rommConnected,
  required bool loginRequested,
}) {
  if (hasScreenscraperCredentials) return ScraperEntry.options;
  if (rommConnected && !loginRequested) return ScraperEntry.options;
  return ScraperEntry.login;
}
