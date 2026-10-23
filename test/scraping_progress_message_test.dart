import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/scraping_progress_message.dart';

/// The global "scraping in progress" notification: unchanged without RomM, with
/// the per-source tally appended when RomM takes part.
void main() {
  String t(String key) => switch (key) {
    AppLocale.scrapingInProgress => 'Scraping in progress',
    AppLocale.scrapingProgressSources =>
      'RomM {romm} · ScreenScraper {screenscraper}',
    _ => key,
  };

  String text({
    int processed = 12,
    int total = 48,
    bool rommInPlay = false,
    int romm = 0,
    int screenscraper = 0,
  }) => scrapingProgressText(
    t: t,
    processed: processed,
    total: total,
    rommInPlay: rommInPlay,
    rommGames: romm,
    screenscraperGames: screenscraper,
  );

  test('without RomM the text is exactly what it was', () {
    expect(text(), 'Scraping in progress 12 / 48');
  });

  test('without RomM the counts are never shown, whatever they hold', () {
    expect(text(romm: 5, screenscraper: 7), 'Scraping in progress 12 / 48');
  });

  test('with RomM the tally follows the progress', () {
    expect(
      text(rommInPlay: true, romm: 5, screenscraper: 7),
      'Scraping in progress 12 / 48 · RomM 5 · ScreenScraper 7',
    );
  });

  test('the tally starts at zero before any game has finished', () {
    expect(
      text(processed: 0, rommInPlay: true),
      'Scraping in progress 0 / 48 · RomM 0 · ScreenScraper 0',
    );
  });

  test('before the total is known only the label shows, plus the tally', () {
    expect(text(total: 0, processed: 0), 'Scraping in progress');
    expect(
      text(total: 0, processed: 0, rommInPlay: true),
      'Scraping in progress · RomM 0 · ScreenScraper 0',
    );
  });
}
