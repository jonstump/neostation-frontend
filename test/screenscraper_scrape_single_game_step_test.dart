import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_scrape_step.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';

import 'database_test_helper.dart';

/// The RomM-first chain in `ScreenScraperService.scrapeSingleGame`
/// (SPEC-0006 "Per-Game Source Chain") with a fake step against the
/// in-memory database, which holds no ScreenScraper credentials.
///
/// That empty credentials table is the seam: any ScreenScraper work would
/// stop at the credentials gate with `scrapeNoCredentials`, so a `romm`
/// success proves the gate was never reached, and a `screenscraper` failure
/// with that message proves the existing flow ran, unchanged, after the step
/// fell through. No network is ever touched.

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Per-Game Source Chain"

void main() {
  final helper = DatabaseTestHelper();
  late List<RommScrapeTarget> calls;
  late List<String> progress;

  RommScrapeStep stepReturning(RommScrapeStepResult result) => (target) async {
    calls.add(target);
    return result;
  };

  Future<Map<String, dynamic>> scrape({
    RommScrapeStep? step,
    bool forceOverwrite = false,
  }) => ScreenScraperService.scrapeSingleGame(
    appSystemId: 'snes',
    romName: 'ct.sfc',
    systemFolder: 'snes',
    romPath: '/roms/snes/ct.sfc',
    forceOverwrite: forceOverwrite,
    onProgress: (status, _) => progress.add(status),
    rommStep: step,
  );

  setUp(() async {
    await helper.setUp();
    calls = [];
    progress = [];
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    await helper.tearDown();
  });

  test('no step: the map is as before plus source and rommAttempted', () async {
    final result = await scrape();

    expect(result, {
      'success': false,
      'message': AppLocale.scrapeNoCredentials,
      'source': ScreenScraperService.scrapeSourceScreenscraper,
      'rommAttempted': false,
    });
    expect(progress.first, AppLocale.checkingCredentials);
    expect(progress, isNot(contains(AppLocale.scrapeFetchingFromRomm)));
  });

  test('step scraped: source romm, no credentials needed', () async {
    final step = stepReturning(
      RommScrapeStepResult.fromOutcome(
        const RommMetadataOutcome(
          kind: RommMetadataOutcomeKind.filled,
          columnsWritten: 2,
          mediaWritten: 1,
        ),
      ),
    );

    final result = await scrape(step: step, forceOverwrite: true);

    expect(result, {
      'success': true,
      'message': AppLocale.scrapeSuccessful,
      'source': ScreenScraperService.scrapeSourceRomm,
      'rommAttempted': true,
    });
    expect(calls, [
      const RommScrapeTarget(
        appSystemId: 'snes',
        filename: 'ct.sfc',
        systemFolder: 'snes',
        forceOverwrite: true,
      ),
    ]);
    expect(progress, [AppLocale.scrapeFetchingFromRomm]);
  });

  test('the target carries the scrape overwrite flag as given', () async {
    final step = stepReturning(const RommScrapeStepResult.notLinked());

    await scrape(step: step);

    expect(calls.single.forceOverwrite, isFalse);
  });

  for (final result in [
    const RommScrapeStepResult.notLinked(),
    RommScrapeStepResult.fromOutcome(const RommMetadataOutcome.notFound()),
    RommScrapeStepResult.fromOutcome(
      const RommMetadataOutcome(kind: RommMetadataOutcomeKind.filled),
    ),
    RommScrapeStepResult.failed(StateError('timeout')),
  ]) {
    test(
      'step ${result.status.name}: falls through to ScreenScraper',
      () async {
        final map = await scrape(step: stepReturning(result));

        expect(map, {
          'success': false,
          'message': AppLocale.scrapeNoCredentials,
          'source': ScreenScraperService.scrapeSourceScreenscraper,
          'rommAttempted': true,
        });
        expect(calls, hasLength(1));
        expect(progress, [
          AppLocale.scrapeFetchingFromRomm,
          AppLocale.checkingCredentials,
        ]);
      },
    );
  }

  test(
    'a failed step is logged with its error before falling through',
    () async {
      await scrape(step: stepReturning(RommScrapeStepResult.failed('boom')));

      final logged = LoggerService.instance
          .takeCapture()
          .where((l) => l.contains('RomM scrape step failed'))
          .toList();
      expect(logged, hasLength(1));
      expect(logged.single, contains('filename=ct.sfc'));
      expect(logged.single, contains('error=boom'));
    },
  );

  test('a throwing step is a failed step, not a scrape error', () async {
    final map = await scrape(
      step: (target) async {
        calls.add(target);
        throw StateError('fake threw');
      },
    );

    expect(map['message'], AppLocale.scrapeNoCredentials);
    expect(map['source'], ScreenScraperService.scrapeSourceScreenscraper);
    expect(map['rommAttempted'], isTrue);
  });
}
