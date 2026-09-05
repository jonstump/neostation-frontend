import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_scrape_step.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/screenscraper_service.dart';

import 'database_test_helper.dart';

/// The RomM-first chain of a bulk run (SPEC-0006 "Bulk Source Chain",
/// "Cooperation With Provenance And Modes", "Concurrency Safety") with a
/// fake step and a fake ScreenScraper worker.
///
/// The per-ROM chain is exercised through `processRomForBulk`, the seam the
/// pipeline itself calls for every ROM, with the ScreenScraper worker
/// replaced by a counting closure. The whole pipeline runs against the
/// in-memory database for the RomM-only, neither-source and cancel cases:
/// that database holds no ScreenScraper credentials, so any ScreenScraper
/// request would have to go through a worker the service never reaches
/// without them — no network is ever touched.

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"

/// The only thing `startMetadataScraping` asks its context is `mounted`,
/// right before the summary dialog; an unmounted context skips the dialog.
class _NoScreenContext implements BuildContext {
  @override
  bool get mounted => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('BuildContext.${invocation.memberName}');
}

const _scraped = RommScrapeStepResult(status: RommScrapeStepStatus.scraped);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // ScrapingProvider toggles the wakelock on start/stop; answer its pigeon
    // channel so the plugin call does not fail the test with no platform.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  final helper = DatabaseTestHelper();
  late dynamic db;
  late List<RommScrapeTarget> stepCalls;
  late int screenscraperCalls;

  setUp(() async {
    db = await helper.setUp();
    stepCalls = [];
    screenscraperCalls = 0;
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    await helper.tearDown();
  });

  /// A step that scrapes every target [linked] says yes to and reports the
  /// rest as not linked. It yields once so concurrent workers interleave.
  RommScrapeStep stepLinkedWhen(bool Function(RommScrapeTarget) linked) =>
      (target) async {
        stepCalls.add(target);
        await Future<void>.delayed(Duration.zero);
        return linked(target)
            ? _scraped
            : const RommScrapeStepResult.notLinked();
      };

  Map<String, dynamic> rom(int i) => {
    'filename': 'game$i.sfc',
    'rom_path': '/roms/snes/game$i.sfc',
  };

  /// Runs [roms] through the per-ROM chain in batches of [threads], the way
  /// the pipeline does, and returns every result.
  Future<List<Map<String, dynamic>>> runChain(
    List<Map<String, dynamic>> roms, {
    required RommScrapeStep? step,
    required bool screenscraperAvailable,
    required ScrapingProvider provider,
    int threads = 4,
    bool forceOverwrite = false,
    bool Function()? shouldCancel,
    void Function(int threadId)? onScreenscraperCall,
  }) async {
    final results = <Map<String, dynamic>>[];
    for (var i = 0; i < roms.length; i += threads) {
      final batch = roms.sublist(
        i,
        i + threads < roms.length ? i + threads : roms.length,
      );
      results.addAll(
        await Future.wait([
          for (var t = 0; t < batch.length; t++)
            ScreenScraperService.processRomForBulk(
              rom: batch[t],
              threadId: t + 1,
              systemName: 'SNES',
              systemFolder: 'snes',
              appSystemId: 'snes',
              forceOverwrite: forceOverwrite,
              screenscraperAvailable: screenscraperAvailable,
              rommStep: step,
              scrapingProvider: provider,
              shouldCancel: shouldCancel,
              scrapeWithScreenscraper: () async {
                screenscraperCalls++;
                onScreenscraperCall?.call(t + 1);
                return {'success': true, 'cancelled': false, 'requests': 1};
              },
            ),
        ]),
      );
    }
    return results;
  }

  ({int romm, int screenscraper, int failed}) tally(
    List<Map<String, dynamic>> results,
  ) {
    var romm = 0, screenscraper = 0, failed = 0;
    for (final r in results) {
      if (r['success'] != true) {
        failed++;
      } else if (r['source'] == ScreenScraperService.scrapeSourceRomm) {
        romm++;
      } else {
        screenscraper++;
      }
    }
    return (romm: romm, screenscraper: screenscraper, failed: failed);
  }

  group('start gate', () {
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
    test('needs credentials or a step; neither refuses', () {
      Future<RommScrapeStepResult> step(RommScrapeTarget _) async => _scraped;
      final creds = {'username': 'u', 'password': 'p'};
      expect(
        ScreenScraperService.canStartBulkScrape(
          credentials: creds,
          rommStep: null,
        ),
        isTrue,
      );
      expect(
        ScreenScraperService.canStartBulkScrape(
          credentials: null,
          rommStep: step,
        ),
        isTrue,
      );
      expect(
        ScreenScraperService.canStartBulkScrape(
          credentials: creds,
          rommStep: step,
        ),
        isTrue,
      );
      expect(
        ScreenScraperService.canStartBulkScrape(
          credentials: null,
          rommStep: null,
        ),
        isFalse,
      );
    });

    test('neither source: startMetadataScraping returns false', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      final started = await ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        provider,
        shouldCancel: () => false,
      );
      expect(started, isFalse);
      expect(provider.processedGames, 0);
    });
  });

  group('per-ROM chain', () {
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
    test(
      'mixed library: 100 linked of 120 → 100 romm, 20 screenscraper',
      () async {
        final provider = ScrapingProvider()..startScraping(maxThreads: 4);
        final roms = List.generate(120, rom);
        final linked = roms.take(100).map((r) => r['filename']).toSet();

        final results = await runChain(
          roms,
          step: stepLinkedWhen((t) => linked.contains(t.filename)),
          screenscraperAvailable: true,
          provider: provider,
        );

        expect(results.length, 120);
        expect(tally(results), (romm: 100, screenscraper: 20, failed: 0));
        expect(stepCalls.length, 120, reason: 'every ROM is offered to RomM');
        expect(screenscraperCalls, 20, reason: 'only the fall-throughs');
        expect(
          results.where((r) => r['source'] == null),
          isEmpty,
          reason: 'every result names its source',
        );
        expect(results.every((r) => r['rommAttempted'] == true), isTrue);
      },
    );

    test('the target carries the run overwrite flag and the system', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      await runChain(
        [rom(0)],
        step: stepLinkedWhen((_) => true),
        screenscraperAvailable: true,
        provider: provider,
        forceOverwrite: true,
      );
      expect(
        stepCalls.single,
        const RommScrapeTarget(
          appSystemId: 'snes',
          filename: 'game0.sfc',
          systemFolder: 'snes',
          forceOverwrite: true,
        ),
      );
    });

    test('the thread names RomM while the step runs', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      ThreadProcessingStep? seenDuringStep;
      Future<RommScrapeStepResult> step(RommScrapeTarget target) async {
        seenDuringStep = provider.threads.first.currentStep;
        return _scraped;
      }

      await runChain(
        [rom(0)],
        step: step,
        screenscraperAvailable: true,
        provider: provider,
      );
      expect(seenDuringStep, ThreadProcessingStep.fetchingFromRomm);
      expect(
        provider.threads.first.currentStep,
        ThreadProcessingStep.completed,
      );
    });

    test('no step: the ScreenScraper worker runs as before', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      final results = await runChain(
        List.generate(3, rom),
        step: null,
        screenscraperAvailable: true,
        provider: provider,
      );
      expect(tally(results), (romm: 0, screenscraper: 3, failed: 0));
      expect(screenscraperCalls, 3);
      expect(results.every((r) => r['rommAttempted'] == false), isTrue);
    });

    test('a throwing step falls through like a failed one', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      final results = await runChain(
        [rom(0)],
        step: (_) async => throw StateError('boom'),
        screenscraperAvailable: true,
        provider: provider,
      );
      expect(tally(results), (romm: 0, screenscraper: 1, failed: 0));
      expect(screenscraperCalls, 1);
    });

    test('RomM only: 8 linked of 10 → 8 romm, 2 failed, no request', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      final roms = List.generate(10, rom);
      final linked = roms.take(8).map((r) => r['filename']).toSet();

      final results = await runChain(
        roms,
        step: stepLinkedWhen((t) => linked.contains(t.filename)),
        screenscraperAvailable: false,
        provider: provider,
      );

      expect(tally(results), (romm: 8, screenscraper: 0, failed: 2));
      expect(screenscraperCalls, 0, reason: 'ScreenScraper is not set up');
      expect(stepCalls.length, 10);
      final log = LoggerService.instance.takeCapture();
      expect(
        log.where((l) => l.contains('counting as failed')).length,
        2,
        reason: 'each unscraped ROM is logged once',
      );
      expect(
        log.where((l) => l.contains('game8.sfc')).length +
            log.where((l) => l.contains('game9.sfc')).length,
        2,
      );
    });

    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Concurrency Safety"
    test(
      'cancellation is checked before the step, as the worker always did',
      () async {
        final provider = ScrapingProvider()..startScraping(maxThreads: 4);
        final results = await runChain(
          List.generate(4, rom),
          step: stepLinkedWhen((_) => true),
          screenscraperAvailable: true,
          provider: provider,
          shouldCancel: () => true,
        );
        expect(results.every((r) => r['cancelled'] == true), isTrue);
        expect(stepCalls, isEmpty);
        expect(screenscraperCalls, 0);
      },
    );

    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Concurrency Safety"
    test('four workers at once each see only their own target', () async {
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      var inFlight = 0, peak = 0;
      Future<RommScrapeStepResult> step(RommScrapeTarget target) async {
        inFlight++;
        peak = peak < inFlight ? inFlight : peak;
        stepCalls.add(target);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return _scraped;
      }

      final results = await runChain(
        List.generate(8, rom),
        step: step,
        screenscraperAvailable: true,
        provider: provider,
      );
      expect(peak, 4, reason: 'the whole batch runs the step concurrently');
      expect(tally(results).romm, 8);
      expect(stepCalls.map((t) => t.filename).toSet().length, 8);
    });
  });

  group('pipeline against the in-memory database', () {
    Future<void> seedSystem() async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('snes', 'snes')",
      );
    }

    Future<void> seedRoms(int count) async {
      for (var i = 0; i < count; i++) {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game$i.sfc', '/roms/snes/game$i.sfc', 'snes')",
        );
      }
    }

    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
    test('RomM only: the run starts without credentials and counts', () async {
      await seedSystem();
      await seedRoms(10);
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);
      final linked = {for (var i = 0; i < 8; i++) 'game$i.sfc'};

      final finished = await ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        provider,
        shouldCancel: () => false,
        rommStep: stepLinkedWhen((t) => linked.contains(t.filename)),
      );

      expect(finished, isTrue);
      expect(provider.processedGames, 10);
      expect(provider.successfulGames, 8);
      expect(provider.failedGames, 2);
      expect(stepCalls.length, 10);
      expect(stepCalls.every((t) => t.appSystemId == 'snes'), isTrue);
      expect(
        stepCalls.every((t) => t.forceOverwrite == false),
        isTrue,
        reason: 'the default scrape mode is new_only, not all',
      );
      final log = LoggerService.instance.takeCapture();
      expect(log.any((l) => l.contains('from RomM only')), isTrue);
      expect(log.where((l) => l.contains('counting as failed')).length, 2);
      expect(log.any((l) => l.contains('romm=8 screenscraper=0')), isTrue);
    });

    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
    test('cancel mid-run stops between batches as before', () async {
      await seedSystem();
      await seedRoms(12);
      final provider = ScrapingProvider()..startScraping(maxThreads: 4);

      final finished = await ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        provider,
        // The first batch of four runs; the check before the second batch
        // sees the cancel.
        shouldCancel: () => provider.processedGames >= 4,
        rommStep: stepLinkedWhen((_) => true),
      );

      expect(finished, isFalse);
      expect(provider.isScraping, isFalse);
      expect(provider.processedGames, 4);
      expect(stepCalls.length, 4, reason: 'no step runs after the cancel');
    });
  });

  group('new_only cooperation', () {
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Cooperation With Provenance And Modes"
    test('a row RomM completed is not a candidate in new_only', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('ct.sfc', '/roms/snes/ct.sfc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('other.sfc', '/roms/snes/other.sfc', 'snes')",
      );
      // The same filename under another system, to prove the join is keyed
      // on the system id as well.
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('ct.sfc', '/roms/nes/ct.sfc', 'nes')",
      );
      // What the RomM step's insert leaves behind: fully scraped, source romm.
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (filename, app_system_id, is_fully_scraped, metadata_source) VALUES ('ct.sfc', 'snes', 1, 'romm')",
      );

      final newOnly = await ScraperRepository.getRomsForScraping(
        'snes',
        'new_only',
      );
      expect(newOnly.map((r) => r['filename']), ['other.sfc']);
      expect(
        await ScraperRepository.getRomCountForScraping('snes', 'new_only'),
        1,
      );

      final all = await ScraperRepository.getRomsForScraping('snes', 'all');
      expect(
        all.length,
        2,
        reason: 'all mode re-runs the chain for every candidate',
      );

      final nes = await ScraperRepository.getRomsForScraping('nes', 'new_only');
      expect(nes.map((r) => r['filename']), [
        'ct.sfc',
      ], reason: 'the snes row does not hide the nes ROM');
    });
  });
}
