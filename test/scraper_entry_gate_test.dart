import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/scraper_entry_gate.dart';

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
void main() {
  group('scraperEntryFor', () {
    test('ScreenScraper credentials always open the options', () {
      for (final romm in [true, false]) {
        for (final asked in [true, false]) {
          expect(
            scraperEntryFor(
              hasScreenscraperCredentials: true,
              rommConnected: romm,
              loginRequested: asked,
            ),
            ScraperEntry.options,
          );
        }
      }
    });

    test('RomM alone opens the options so the bulk scrape is reachable', () {
      expect(
        scraperEntryFor(
          hasScreenscraperCredentials: false,
          rommConnected: true,
          loginRequested: false,
        ),
        ScraperEntry.options,
      );
    });

    test('a RomM-only user can still ask for the ScreenScraper login', () {
      expect(
        scraperEntryFor(
          hasScreenscraperCredentials: false,
          rommConnected: true,
          loginRequested: true,
        ),
        ScraperEntry.login,
      );
    });

    test('with neither source the login is the only sensible screen', () {
      for (final asked in [true, false]) {
        expect(
          scraperEntryFor(
            hasScreenscraperCredentials: false,
            rommConnected: false,
            loginRequested: asked,
          ),
          ScraperEntry.login,
        );
      }
    });
  });
}
