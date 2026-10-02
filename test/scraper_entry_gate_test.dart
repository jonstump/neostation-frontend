import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/scraper_entry_gate.dart';

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
void main() {
  group('scraperEntryFor', () {
    test('ScreenScraper credentials always open the options', () {
      for (final romm in [true, false]) {
        expect(
          scraperEntryFor(
            hasScreenscraperCredentials: true,
            rommConnected: romm,
          ),
          ScraperEntry.options,
        );
      }
    });

    test('RomM alone opens the options so the bulk scrape is reachable', () {
      expect(
        scraperEntryFor(
          hasScreenscraperCredentials: false,
          rommConnected: true,
        ),
        ScraperEntry.options,
      );
    });

    test('with neither source the sign-in is the only sensible screen', () {
      expect(
        scraperEntryFor(
          hasScreenscraperCredentials: false,
          rommConnected: false,
        ),
        ScraperEntry.login,
      );
    });
  });
}
