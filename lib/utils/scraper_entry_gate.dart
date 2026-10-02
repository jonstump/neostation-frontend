/// Whether the scraper settings show their options or only the sign-in.
enum ScraperEntry { options, login }

/// Decides between the scraper options and the lone ScreenScraper sign-in.
///
/// ScreenScraper credentials always open the options. Without them, a
/// connected RomM server is a scrape source on its own (ADR-0006), so the
/// options open too; the account slot above them still offers the
/// ScreenScraper sign-in, so there is no separate "show me the login" request
/// to honour. With neither, only the sign-in makes sense.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
ScraperEntry scraperEntryFor({
  required bool hasScreenscraperCredentials,
  required bool rommConnected,
}) {
  if (hasScreenscraperCredentials || rommConnected) return ScraperEntry.options;
  return ScraperEntry.login;
}
