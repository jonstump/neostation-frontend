import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_scrape_step.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';
import 'package:neostation/services/romm/romm_paging.dart';
import 'package:neostation/services/romm/romm_server_guard.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/screenscraper_service.dart';
import 'package:neostation/utils/scrape_result_message.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// What the RomM step of a scrape does to a server that is down, rate
/// limiting, or simply does not have the game, and what the guard shared by a
/// bulk run's workers does about it.
///
/// The rule under test (see [RommServerGuard]): a game adds at most one to the
/// streak when its outcome is transport-class (timeout, socket or TLS error,
/// 5xx, 429), only a fully successful game resets it, and a real 404, a game
/// that is not linked, a parse error or a media 404 neither count nor reset.
/// After five in a row RomM is skipped for the rest of the run without a
/// request, and ScreenScraper (when set up) carries on. A `Retry-After`
/// pauses every worker, capped, and a cancel interrupts the pause.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

final Uint8List _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
]);

Map<String, dynamic> _detail(int romId) => {
  'id': romId,
  'name': 'Game $romId',
  'fs_name': 'game$romId.sfc',
  'fs_name_no_ext': 'game$romId',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
  'summary': 'A game.',
  'metadatum': const {
    'genres': ['RPG'],
  },
  'path_cover_large': '/assets/romm/resources/roms/1/$romId/cover/big.png',
};

// ── Scripted results for the guard-only tests ──────────────────────────────

RommScrapeStepResult _ok() => RommScrapeStepResult.fromOutcome(
  const RommMetadataOutcome(
    kind: RommMetadataOutcomeKind.filled,
    columnsWritten: 3,
  ),
);

RommScrapeStepResult _transport({Duration? retryAfter}) =>
    RommScrapeStepResult.fromOutcome(
      RommMetadataOutcome.failed(
        StateError('timeout'),
        transportClass: true,
        retryAfter: retryAfter,
      ),
    );

RommScrapeStepResult _notFound() =>
    RommScrapeStepResult.fromOutcome(const RommMetadataOutcome.notFound());

/// A write that landed (columns) while a media download failed on transport.
RommScrapeStepResult _mediaTransportPartial() =>
    RommScrapeStepResult.fromOutcome(
      const RommMetadataOutcome(
        kind: RommMetadataOutcomeKind.partial,
        columnsWritten: 2,
        mediaFailed: 1,
        transportClass: true,
      ),
    );

/// A partial whose media failure says nothing about the server (a parse or
/// write error): not fully successful, and not transport-class.
RommScrapeStepResult _partialNotTransport() => RommScrapeStepResult.fromOutcome(
  const RommMetadataOutcome(
    kind: RommMetadataOutcomeKind.partial,
    columnsWritten: 2,
    mediaFailed: 1,
  ),
);

/// A guard on a fake clock whose `sleep` advances it, so a pause costs no
/// real time. [slept] collects every sleep the guard asks for.
class _FakeTime {
  DateTime now = DateTime(2026, 1, 1);
  final List<Duration> slept = [];
  DateTime clock() => now;
  Future<void> sleep(Duration d) async {
    slept.add(d);
    now = now.add(d);
  }
}

class _NoScreenContext implements BuildContext {
  @override
  bool get mounted => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('BuildContext.${invocation.memberName}');
}

/// A RomM server whose detail answer is scripted per request and that records
/// how many requests were in flight at once.
class _ScriptedService extends RommService {
  final RommDetailFetch Function(int id, int call) detailScript;
  final Map<String, Uint8List> assets;

  _ScriptedService({required this.detailScript, this.assets = const {}});

  int _inFlight = 0;
  int peakInFlight = 0;
  int detailCalls = 0;
  int mediaCalls = 0;

  Future<void> _hold() async {
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    _inFlight--;
  }

  @override
  Future<RommDetailFetch> fetchRomDetail(int id) async {
    final call = detailCalls++;
    await _hold();
    return detailScript(id, call);
  }

  @override
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    mediaCalls++;
    await _hold();
    final bytes = assets[pathOrUrl];
    return bytes == null
        ? const RommImageFetch.missing(RommImageMiss.absent)
        : RommImageFetch.found(bytes);
  }
}

class _TestProvider extends RommProvider {
  final RommService fake;
  _TestProvider(this.fake);

  @override
  RommService get service => fake;

  @override
  bool get isConnected => true;
}

class _TempMedia extends FileProvider {
  final String root;
  _TempMedia(this.root);

  @override
  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) => p.join(
    root,
    systemFolderName,
    imageType,
    '${p.basenameWithoutExtension(romName)}.$extension',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  // ── The guard on its own ─────────────────────────────────────────────────

  group('RommServerGuard (scripted results)', () {
    RommServerGuard newGuard({
      _FakeTime? time,
      bool Function()? shouldStop,
      int threshold = RommServerGuard.defaultThreshold,
    }) {
      final t = time ?? _FakeTime();
      return RommServerGuard(
        threshold: threshold,
        clock: t.clock,
        sleep: t.sleep,
        shouldStop: shouldStop,
      );
    }

    test('the threshold is the per-system pass\'s, five', () {
      expect(
        RommServerGuard.defaultThreshold,
        RommMetadataFetch.maxConsecutiveTransportFailures,
      );
      expect(RommServerGuard.defaultThreshold, 5);
    });

    test(
      'a dead server trips on the fifth consecutive failure, not before',
      () {
        final guard = newGuard();
        for (var i = 0; i < 4; i++) {
          guard.record(_transport());
          expect(guard.tripped, isFalse, reason: 'after ${i + 1} failures');
        }
        guard.record(_transport());
        expect(guard.tripped, isTrue);
        expect(guard.transportFailures, 5);
      },
    );

    test('a fully successful game between failures resets the streak', () {
      final guard = newGuard();
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 4; i++) {
          guard.record(_transport());
        }
        guard.record(_ok());
      }
      expect(guard.tripped, isFalse);
    });

    test('failures that never reach five in a row do not trip', () {
      final guard = newGuard();
      for (var i = 0; i < 40; i++) {
        guard.record(i.isEven ? _transport() : _ok());
      }
      expect(guard.tripped, isFalse);
      expect(guard.transportFailures, 20);
    });

    test('a 404 neither counts toward the trip nor resets the streak', () {
      final guard = newGuard();
      for (var i = 0; i < 4; i++) {
        guard.record(_transport());
      }
      guard.record(_notFound());
      expect(guard.tripped, isFalse, reason: 'a 404 does not count');
      guard.record(_transport());
      expect(
        guard.tripped,
        isTrue,
        reason: 'and it did not reset the four failures before it',
      );
    });

    test('a long run of 404s never trips', () {
      final guard = newGuard();
      for (var i = 0; i < 200; i++) {
        guard.record(_notFound());
      }
      expect(guard.tripped, isFalse);
      expect(guard.transportFailures, 0);
    });

    test('not linked, a non-transport failure and a non-transport partial '
        'say nothing about the server', () {
      final guard = newGuard();
      for (var i = 0; i < 4; i++) {
        guard.record(_transport());
      }
      guard.record(const RommScrapeStepResult.notLinked());
      guard.record(RommScrapeStepResult.failed(StateError('parse error')));
      guard.record(_partialNotTransport());
      expect(guard.tripped, isFalse);
      guard.record(_transport());
      expect(guard.tripped, isTrue, reason: 'the streak of four survived');
    });

    test('a media transport failure counts once per game', () {
      final guard = newGuard();
      for (var i = 0; i < 4; i++) {
        guard.record(_mediaTransportPartial());
      }
      expect(guard.tripped, isFalse);
      expect(guard.transportFailures, 4);
      guard.record(_mediaTransportPartial());
      expect(guard.tripped, isTrue);
    });

    test('a skipped game made no request, so it records nothing', () {
      final guard = newGuard();
      for (var i = 0; i < 5; i++) {
        guard.record(_transport());
      }
      final before = guard.transportFailures;
      final skipped = guard.skip();
      guard.record(skipped);
      expect(skipped.status, RommScrapeStepStatus.serverSkipped);
      expect(skipped.serverUnavailable, isTrue);
      expect(guard.skipped, 1);
      expect(guard.transportFailures, before);
    });

    test('a 429 pauses for its Retry-After, once, on the clock', () async {
      final time = _FakeTime();
      final guard = newGuard(time: time);
      guard.record(_transport(retryAfter: const Duration(seconds: 30)));
      expect(guard.pauses, 1);

      final start = time.now;
      await guard.waitTurn();

      expect(time.now.difference(start), const Duration(seconds: 30));
      expect(guard.pausedTotal, const Duration(seconds: 30));
      await guard.waitTurn();
      expect(guard.pausedTotal, const Duration(seconds: 30));
    });

    test('a hostile Retry-After is clamped to the cap', () async {
      final time = _FakeTime();
      final guard = newGuard(time: time);
      guard.record(_transport(retryAfter: const Duration(hours: 6)));

      final start = time.now;
      await guard.waitTurn();

      expect(time.now.difference(start), RommService.retryAfterCap);
      expect(RommService.retryAfterCap, const Duration(seconds: 60));
    });

    test('zero, negative and missing Retry-After invent no pause', () async {
      final time = _FakeTime();
      final guard = newGuard(time: time);
      guard.record(_transport(retryAfter: Duration.zero));
      guard.record(_transport(retryAfter: const Duration(seconds: -5)));
      guard.record(_transport());
      await guard.waitTurn();
      expect(guard.pauses, 0);
      expect(time.slept, isEmpty);
    });

    test('two 429s pause until the later deadline, not the sum', () async {
      final time = _FakeTime();
      final guard = newGuard(time: time);
      guard.record(_transport(retryAfter: const Duration(seconds: 10)));
      guard.record(_transport(retryAfter: const Duration(seconds: 30)));

      final start = time.now;
      await guard.waitTurn();

      expect(time.now.difference(start), const Duration(seconds: 30));
    });

    test(
      'a shorter Retry-After after a longer one does not shorten the pause',
      () async {
        final time = _FakeTime();
        final guard = newGuard(time: time);
        guard.record(_transport(retryAfter: const Duration(seconds: 30)));
        guard.record(_transport(retryAfter: const Duration(seconds: 10)));

        final start = time.now;
        await guard.waitTurn();

        expect(time.now.difference(start), const Duration(seconds: 30));
      },
    );

    test('repeated 429s count toward the trip', () {
      final guard = newGuard();
      for (var i = 0; i < 5; i++) {
        guard.record(_transport(retryAfter: const Duration(seconds: 1)));
      }
      expect(guard.tripped, isTrue);
    });

    test('a cancel during a pause ends it within one poll slice', () async {
      final time = _FakeTime();
      var stop = false;
      final guard = RommServerGuard(
        clock: time.clock,
        sleep: (d) async {
          await time.sleep(d);
          stop = true; // the user cancels during the first slice
        },
        shouldStop: () => stop,
      );
      guard.record(_transport(retryAfter: const Duration(seconds: 60)));

      await guard.waitTurn();

      expect(time.slept, hasLength(1));
      expect(
        time.slept.single,
        lessThanOrEqualTo(const Duration(milliseconds: 50)),
      );
      expect(guard.stopRequested, isTrue);
    });

    test(
      'a guard that trips while a worker waits releases that worker',
      () async {
        final time = _FakeTime();
        late RommServerGuard guard;
        var sleeps = 0;
        guard = RommServerGuard(
          clock: time.clock,
          sleep: (d) async {
            await time.sleep(d);
            if (++sleeps == 2) {
              for (var i = 0; i < 5; i++) {
                guard.record(_transport());
              }
            }
          },
        );
        guard.record(_transport(retryAfter: const Duration(seconds: 60)));

        await guard.waitTurn();

        expect(guard.tripped, isTrue);
        expect(
          sleeps,
          2,
          reason: 'it stopped waiting the moment the guard tripped',
        );
      },
    );
  });

  // ── A bulk run against a scripted server ─────────────────────────────────

  group('a bulk scrape against a failing RomM', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory root;
    late _TempMedia media;

    setUp(() async {
      RommMetadataNetwork.resetForTesting();
      db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(
        "INSERT INTO app_systems (id, folder_name, real_name, screenscraper_id) "
        "VALUES ('snes', 'snes', 'Super Nintendo', 4)",
      );
      root = await Directory.systemTemp.createTemp('romm_scrape_guard_');
      media = _TempMedia(root.path);
      LoggerService.instance.startCapture();
    });

    tearDown(() async {
      LoggerService.instance.takeCapture();
      await helper.tearDown();
      await root.delete(recursive: true);
    });

    Future<void> seedLinkedGames(int count) async {
      await db.execute(
        "INSERT OR IGNORE INTO user_detected_systems (app_system_id, actual_folder_name) VALUES ('snes', 'snes')",
      );
      for (var i = 0; i < count; i++) {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) "
          "VALUES ('game$i.sfc', '/roms/snes/game$i.sfc', 'snes')",
        );
        await RommSaveMapRepository.putMapping(
          romname: 'game$i.sfc',
          systemFolder: 'snes',
          rommRomId: i,
          source: RommLinkSource.download,
          fsName: 'game$i.sfc',
        );
      }
    }

    RommDetailFetch ok(int id) => RommDetailFetch.found(_detail(id));
    const unreachable = RommDetailFetch.missing(RommDetailMiss.unreachable);

    /// Runs one RomM-only bulk scrape (no ScreenScraper credentials in the
    /// test database) over the seeded games.
    Future<
      ({
        ScrapingProvider scraping,
        RommServerGuard guard,
        _ScriptedService svc,
        bool finished,
      })
    >
    runBulk(
      RommDetailFetch Function(int id, int call) script, {
      int games = 40,
      _FakeTime? time,
      Map<String, Uint8List> assets = const {},
      void Function(ScrapingProvider scraping)? onProvider,
    }) async {
      await seedLinkedGames(games);
      final svc = _ScriptedService(detailScript: script, assets: assets);
      final provider = _TestProvider(svc);
      final t = time ?? _FakeTime();
      final scraping = ScrapingProvider()..startScraping(maxThreads: 4);
      onProvider?.call(scraping);
      final guard = RommServerGuard(
        clock: t.clock,
        sleep: t.sleep,
        shouldStop: () => !scraping.isScraping,
      );
      final step = await provider.bulkScrapeStep(media, guard: guard);
      final finished = await ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        scraping,
        shouldCancel: () => false,
        rommStep: step,
        rommGuard: guard,
      );
      return (scraping: scraping, guard: guard, svc: svc, finished: finished);
    }

    // Workers that already passed the trip check when it trips still finish:
    // at most (workers - 1) more requests than the threshold.
    const workers = 4;
    const slack = RommServerGuard.defaultThreshold + workers - 1;

    test('dead from the first request, RomM only: the run stops with an error '
        'instead of failing every game', () async {
      final r = await runBulk((id, call) => unreachable);

      expect(r.finished, isFalse, reason: 'the run is aborted, not completed');
      expect(r.guard.tripped, isTrue);
      expect(
        r.svc.detailCalls,
        lessThanOrEqualTo(slack),
        reason: 'the other games\' requests were never issued',
      );
      expect(
        r.scraping.processedGames,
        lessThan(40),
        reason: 'games after the stop were never processed or counted failed',
      );
      expect(r.scraping.successfulGames, 0);
      expect(r.scraping.isScraping, isFalse);
      // The run says so while it goes: RomM took part and could not answer.
      expect(r.scraping.rommInPlay, isTrue);
      expect(r.scraping.rommUnavailableGames, greaterThan(0));
      expect(r.scraping.rommGames, 0);
    });

    test('a run reports its games per source while it goes', () async {
      final seen = <int>[];
      final r = await runBulk(
        (id, call) => ok(id),
        games: 12,
        assets: {
          for (var i = 0; i < 12; i++)
            '/assets/romm/resources/roms/1/$i/cover/big.png': _png,
        },
        onProvider: (scraping) =>
            scraping.addListener(() => seen.add(scraping.rommGames)),
      );

      expect(r.finished, isTrue);
      expect(r.scraping.rommInPlay, isTrue);
      expect(r.scraping.rommGames, 12);
      expect(r.scraping.screenscraperGames, 0);
      expect(r.scraping.rommUnavailableGames, 0);
      expect(
        seen.last,
        12,
        reason: 'the tally reached the provider, not only the final summary',
      );
      expect(seen, isNotEmpty);
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i],
          greaterThanOrEqualTo(seen[i - 1]),
          reason: 'it only grows',
        );
      }
    });

    test('the stop is logged as a stop, not as a finished run, and is never '
        'a "not found"', () async {
      await runBulk((id, call) => unreachable, games: 12);

      final log = LoggerService.instance.takeCapture().join('\n');
      expect(log, contains('Bulk scrape stopped: RomM is the only source'));
      expect(log, contains('guard_tripped=true'));
      expect(log, isNot(contains('Bulk scrape sources:')));
    });

    test('a server that dies mid-run keeps what was already written', () async {
      final r = await runBulk(
        (id, call) => call < 10 ? ok(id) : unreachable,
        assets: {
          for (var i = 0; i < 40; i++)
            '/assets/romm/resources/roms/1/$i/cover/big.png': _png,
        },
      );

      expect(r.finished, isFalse, reason: 'RomM went away: the run stops');
      expect(r.guard.tripped, isTrue);
      expect(r.scraping.successfulGames, 10, reason: 'the first ten rode RomM');
      expect(r.scraping.failedGames, lessThan(30));
      // "Consecutive" is counted in completion order. A game that succeeded
      // before the server died costs six requests and finishes after a failed
      // one costs one, so a slow success still in flight can reset the streak
      // after some failures. The bound is therefore the ten good games, plus
      // up to (workers - 1) late resets each allowing (threshold - 1) failures,
      // plus the five that finally trip it. The point is that it is bounded
      // and well short of walking all forty games.
      expect(
        r.svc.detailCalls,
        lessThanOrEqualTo(
          10 +
              (workers - 1) * (RommServerGuard.defaultThreshold - 1) +
              RommServerGuard.defaultThreshold,
        ),
      );
      expect(r.svc.detailCalls, lessThan(40));
    });

    test(
      'intermittent failures that never reach five in a row do not trip',
      () async {
        final r = await runBulk(
          (id, call) => call.isEven ? unreachable : ok(id),
          assets: {
            for (var i = 0; i < 40; i++)
              '/assets/romm/resources/roms/1/$i/cover/big.png': _png,
          },
        );

        expect(r.guard.tripped, isFalse);
        expect(r.svc.detailCalls, 40, reason: 'every game was asked');
        expect(r.scraping.successfulGames, 20);
      },
    );

    test('a real 404 on every game never trips: every game is asked', () async {
      final r = await runBulk(
        (id, call) => const RommDetailFetch.missing(RommDetailMiss.absent),
      );

      expect(r.guard.tripped, isFalse);
      expect(r.guard.transportFailures, 0);
      expect(r.svc.detailCalls, 40);
      expect(r.scraping.failedGames, 40, reason: 'RomM-only: nothing scraped');
    });

    test(
      'a 429 pauses the workers for its Retry-After and the run goes on',
      () async {
        final time = _FakeTime();
        final r = await runBulk(
          (id, call) => call == 2
              ? const RommDetailFetch.missing(
                  RommDetailMiss.rateLimited,
                  retryAfter: Duration(seconds: 30),
                )
              : ok(id),
          games: 12,
          time: time,
          assets: {
            for (var i = 0; i < 12; i++)
              '/assets/romm/resources/roms/1/$i/cover/big.png': _png,
          },
        );

        expect(r.finished, isTrue);
        expect(r.guard.pauses, 1);
        expect(
          r.guard.pausedTotal,
          greaterThanOrEqualTo(const Duration(seconds: 30)),
        );
        expect(r.guard.tripped, isFalse, reason: 'one 429 is not five');
        expect(
          r.scraping.successfulGames,
          11,
          reason: 'only the 429\'d game failed',
        );
      },
    );

    test(
      'the tripping run never puts more than the shared bound in flight',
      () async {
        final r = await runBulk((id, call) => unreachable);

        expect(r.svc.peakInFlight, lessThanOrEqualTo(RommPaging.concurrency));
        expect(
          RommMetadataNetwork.instance.peakInFlight,
          lessThanOrEqualTo(RommPaging.concurrency),
        );
      },
    );

    test('a pause holds no gate: a per-system pass finishes while the bulk '
        'run is paused', () async {
      await seedLinkedGames(12);
      // The bulk run's only RomM answer is a 429; its pause is held open by
      // the test on a completer, so the workers sit in waitTurn.
      final svc = _ScriptedService(
        detailScript: (id, call) => id >= 100
            ? ok(id)
            : const RommDetailFetch.missing(
                RommDetailMiss.rateLimited,
                retryAfter: Duration(seconds: 30),
              ),
        assets: {
          for (var i = 100; i < 104; i++)
            '/assets/romm/resources/roms/1/$i/cover/big.png': _png,
        },
      );
      final provider = _TestProvider(svc);
      final hold = Completer<void>();
      final inPause = Completer<void>();
      final time = _FakeTime();
      final scraping = ScrapingProvider()..startScraping(maxThreads: 4);
      final guard = RommServerGuard(
        clock: time.clock,
        sleep: (d) async {
          if (!inPause.isCompleted) inPause.complete();
          if (!hold.isCompleted) await hold.future;
          await time.sleep(d);
        },
        shouldStop: () => !scraping.isScraping,
      );
      final step = await provider.bulkScrapeStep(media, guard: guard);
      final bulk = ScreenScraperService.startMetadataScraping(
        _NoScreenContext(),
        scraping,
        shouldCancel: () => false,
        rommStep: step,
        rommGuard: guard,
      );
      // Start the pass only once a worker is actually waiting out the pause:
      // a fixed number of yields can run before any worker has got there, and
      // the pass would then finish whether or not the pause held the gate.
      await inPause.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('no worker ever reached the pause'),
      );
      expect(guard.pauses, greaterThanOrEqualTo(1));

      final pass = RommMetadataFetch(
        listGames: (folder) async => [
          for (var i = 0; i < 4; i++)
            DatabaseGameModel(
              filename: 'pass$i.sfc',
              romPath: '/roms/snes/pass$i.sfc',
              systemFolderName: 'snes',
            ),
        ],
        linkIndex: () async => RommRomIdIndex({
          for (var i = 0; i < 4; i++)
            RommRomIdIndex.keyFor('snes', 'pass$i.sfc'): 100 + i,
        }),
        fetchOne: (target, system, mode) => provider.fetchMetadataForRomId(
          romId: target.romId,
          system: system,
          fileProvider: media,
          indexedName: target.indexedName,
          mode: mode,
        ),
      );
      final summary = await pass
          .run(_snes, RommMetadataMode.fillGaps)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                fail('the pass was blocked by the paused bulk run'),
          );

      expect(summary.filled, 4, reason: 'the pass ran to completion mid-pause');
      hold.complete();
      // The 429s count toward the guard, and a RomM-only run stops when it
      // trips; what matters here is that the pass was never blocked.
      await bulk;
    });
  });

  group('shouldAbortForRomm', () {
    RommServerGuard tripped() {
      final g = RommServerGuard();
      for (var i = 0; i < RommServerGuard.defaultThreshold; i++) {
        g.record(_transport());
      }
      expect(g.tripped, isTrue);
      return g;
    }

    test('RomM is the only source and the guard tripped: abort', () {
      expect(
        ScreenScraperService.shouldAbortForRomm(
          screenscraperAvailable: false,
          guard: tripped(),
        ),
        isTrue,
      );
    });

    test('ScreenScraper is set up: carry on without RomM, never abort', () {
      expect(
        ScreenScraperService.shouldAbortForRomm(
          screenscraperAvailable: true,
          guard: tripped(),
        ),
        isFalse,
      );
    });

    test('the guard has not tripped: no abort', () {
      final g = RommServerGuard()..record(_transport());
      expect(
        ScreenScraperService.shouldAbortForRomm(
          screenscraperAvailable: false,
          guard: g,
        ),
        isFalse,
      );
    });

    test('no guard (RomM not in play): no abort', () {
      expect(
        ScreenScraperService.shouldAbortForRomm(
          screenscraperAvailable: false,
          guard: null,
        ),
        isFalse,
      );
    });
  });

  // ── Per-game wording ─────────────────────────────────────────────────────

  group('one scrape, RomM unreachable or empty, no ScreenScraper account', () {
    final helper = DatabaseTestHelper();

    setUp(() async {
      await helper.setUp();
    });

    tearDown(() async {
      await helper.tearDown();
    });

    Future<Map<String, dynamic>> scrapeWith(RommScrapeStepResult result) {
      return ScreenScraperService.scrapeSingleGame(
        appSystemId: 'snes',
        romName: 'game0.sfc',
        systemFolder: 'snes',
        romPath: '/roms/snes/game0.sfc',
        rommStep: (target) async => result,
      );
    }

    test('an unreachable RomM says so, not "RomM has no data"', () async {
      final map = await scrapeWith(_transport());

      expect(map['message'], AppLocale.scrapeRommUnreachable);
      expect(map['rommUnavailable'], isTrue);
      expect(map['rommAttempted'], isTrue);
    });

    test('a rate-limited RomM is unreachable too', () async {
      final map = await scrapeWith(
        _transport(retryAfter: const Duration(seconds: 30)),
      );
      expect(map['message'], AppLocale.scrapeRommUnreachable);
    });

    test('a guard that gave up reads as unreachable', () async {
      final map = await scrapeWith(const RommScrapeStepResult.serverSkipped());
      expect(map['message'], AppLocale.scrapeRommUnreachable);
      expect(map['rommUnavailable'], isTrue);
    });

    test(
      'a real 404 keeps "RomM has no data" and is not unavailable',
      () async {
        final map = await scrapeWith(_notFound());

        expect(map['message'], AppLocale.scrapeNoSourceForGame);
        expect(map['rommUnavailable'], isFalse);
      },
    );

    test('a game that is not linked is not unavailable either', () async {
      final map = await scrapeWith(const RommScrapeStepResult.notLinked());
      expect(map['message'], AppLocale.scrapeNoSourceForGame);
      expect(map['rommUnavailable'], isFalse);
    });

    test('the notification reads as info and names the unreachable server', () {
      final failed = scrapeResultMessageFor({
        'success': false,
        'message': AppLocale.scrapeRommUnreachable,
        'source': ScreenScraperService.scrapeSourceScreenscraper,
        'rommAttempted': true,
        'rommUnavailable': true,
      });
      expect(failed.tone, ScrapeResultTone.info);
      expect(
        failed.localizedPlaceholders['reason'],
        AppLocale.scrapeRommUnreachable,
      );

      final done = scrapeResultMessageFor({
        'success': true,
        'source': ScreenScraperService.scrapeSourceScreenscraper,
        'rommAttempted': true,
        'rommUnavailable': true,
      });
      expect(done.key, AppLocale.scrapeCompletedRommUnreachable);

      final nothing = scrapeResultMessageFor({
        'success': true,
        'source': ScreenScraperService.scrapeSourceScreenscraper,
        'rommAttempted': true,
        'rommUnavailable': false,
      });
      expect(nothing.key, AppLocale.scrapeCompletedFallback);
    });
  });

  // ── The bulk worker's fall-through ───────────────────────────────────────

  group('processRomForBulk with an unavailable RomM', () {
    Future<Map<String, dynamic>> run(
      RommScrapeStepResult step, {
      required bool screenscraperAvailable,
      required void Function() onScreenscraper,
    }) {
      return ScreenScraperService.processRomForBulk(
        rom: {'filename': 'game0.sfc'},
        threadId: 1,
        systemName: 'Super Nintendo',
        systemFolder: 'snes',
        appSystemId: 'snes',
        forceOverwrite: false,
        screenscraperAvailable: screenscraperAvailable,
        rommStep: (target) async => step,
        scrapingProvider: ScrapingProvider()..startScraping(maxThreads: 1),
        shouldCancel: null,
        scrapeWithScreenscraper: () async {
          onScreenscraper();
          return {'success': true, 'cancelled': false, 'requests': 1};
        },
      );
    }

    test(
      'ScreenScraper carries on and the game is marked RomM-unavailable',
      () async {
        var asked = 0;
        final map = await run(
          const RommScrapeStepResult.serverSkipped(),
          screenscraperAvailable: true,
          onScreenscraper: () => asked++,
        );

        expect(asked, 1);
        expect(map['success'], isTrue);
        expect(map['source'], ScreenScraperService.scrapeSourceScreenscraper);
        expect(map['rommUnavailable'], isTrue);
      },
    );

    test(
      'with no ScreenScraper the game fails and says RomM was unavailable',
      () async {
        var asked = 0;
        final map = await run(
          _transport(),
          screenscraperAvailable: false,
          onScreenscraper: () => asked++,
        );

        expect(asked, 0, reason: 'no ScreenScraper request is made');
        expect(map['success'], isFalse);
        expect(map['rommUnavailable'], isTrue);
      },
    );

    test(
      'a real miss falls through without being marked unavailable',
      () async {
        final map = await run(
          _notFound(),
          screenscraperAvailable: true,
          onScreenscraper: () {},
        );
        expect(map['rommUnavailable'], isFalse);
      },
    );
  });

  // ── The measurement window ───────────────────────────────────────────────

  group('RommMetadataNetwork measurement window', () {
    setUp(RommMetadataNetwork.resetForTesting);

    test(
      'counts the requests and peak in flight between open and close',
      () async {
        final net = RommMetadataNetwork.instance;
        final window = net.openWindow();

        await net.enter();
        await net.enter();
        net.recordDetail();
        net.recordMedia();
        net.recordMedia();
        net.leave();
        net.leave();

        final load = net.closeWindow(window);
        expect(load.detail, 1);
        expect(load.media, 2);
        expect(load.peak, 2);
      },
    );

    test('two overlapping windows each measure their own span', () async {
      final net = RommMetadataNetwork.instance;
      final first = net.openWindow();
      net.recordDetail();
      final second = net.openWindow();
      net.recordDetail();
      net.recordDetail();

      expect(net.closeWindow(second).detail, 2);
      expect(net.closeWindow(first).detail, 3);
    });

    test('a window does not disturb a pass\'s measurement session', () {
      final net = RommMetadataNetwork.instance;
      net.startSession();
      net.recordDetail();
      final window = net.openWindow();
      net.recordDetail();
      net.closeWindow(window);
      expect(net.endSession().detail, 2);
    });
  });
}
