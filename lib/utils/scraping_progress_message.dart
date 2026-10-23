import '../l10n/app_locale.dart';

/// The text of the global "scraping in progress" notification.
///
/// "Scraping in progress 12 / 48", and when RomM takes part in the run the
/// per-source tally is appended: "… · RomM 5 · ScreenScraper 7", so it is
/// visible where the user already looks without opening the Scraper page.
/// Without RomM the text is exactly what it was before RomM was a source.
/// [t] resolves an `AppLocale` key, so the choice is testable without widgets.
String scrapingProgressText({
  required String Function(String key) t,
  required int processed,
  required int total,
  required bool rommInPlay,
  required int rommGames,
  required int screenscraperGames,
}) {
  final base = total > 0
      ? '${t(AppLocale.scrapingInProgress)} $processed / $total'
      : t(AppLocale.scrapingInProgress);
  if (!rommInPlay) return base;
  final tally = t(AppLocale.scrapingProgressSources)
      .replaceFirst('{romm}', '$rommGames')
      .replaceFirst('{screenscraper}', '$screenscraperGames');
  return '$base · $tally';
}
