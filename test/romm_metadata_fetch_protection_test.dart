import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// Server protection for the per-system RomM metadata pass: the circuit
/// breaker (and, added later in the same round, the 429 Retry-After pause).
///
/// Each test is named for the failure it prevents. The breaker-level tests
/// script the writer's outcome directly, so what is under test is the pass's
/// counting rule — once per game, transport-class only, reset only on a
/// fully successful game. The writer-level tests run the real writer against
/// a scripted service, so "writes are kept" and "requests stop" are measured
/// against the database and the request counters, not asserted.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

const _coverUrl = '/assets/romm/resources/roms/1/42/cover/big.png';
final Uint8List _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
]);

DatabaseGameModel _game(int i) => DatabaseGameModel(
  filename: 'game$i.sfc',
  romPath: '/roms/snes/game$i.sfc',
  systemFolderName: 'snes',
);

// ── Scripted outcomes (breaker-level tests) ────────────────────────────────

const _success = RommMetadataOutcome(kind: RommMetadataOutcomeKind.filled);
final _transportFailure = RommMetadataOutcome.failed(
  StateError('the RomM server could not be reached'),
  transportClass: true,
);
final _parseErrorFailure = RommMetadataOutcome.failed(
  StateError('the detail JSON was malformed'),
);
const _notFound = RommMetadataOutcome.notFound();
const _media404Partial = RommMetadataOutcome(
  kind: RommMetadataOutcomeKind.partial,
  columnsWritten: 3,
  mediaFailed: 1,
);
const _mediaTransportPartial = RommMetadataOutcome(
  kind: RommMetadataOutcomeKind.partial,
  columnsWritten: 3,
  mediaFailed: 2,
  transportClass: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('circuit breaker (scripted outcomes)', () {
    setUp(() {
      RommMetadataFetch.resetActiveForTesting();
      LoggerService.instance.startCapture();
    });
    tearDown(() {
      LoggerService.instance.takeCapture();
      RommMetadataFetch.resetActiveForTesting();
    });

    final games = [for (var i = 0; i < 50; i++) _game(i)];

    Future<RommMetadataFetchSummary> run(
      Future<RommMetadataOutcome> Function(int romId) outcomeFor,
    ) {
      final pass = RommMetadataFetch(
        listGames: (folder) async => games,
        linkIndex: () async => RommRomIdIndex({
          for (var i = 0; i < games.length; i++)
            RommRomIdIndex.keyFor('snes', games[i].filename): i,
        }),
        fetchOne: (target, system, mode) async {
          await Future<void>.delayed(Duration.zero);
          return outcomeFor(target.romId);
        },
      );
      return pass.run(_snes, RommMetadataMode.fillGaps);
    }

    test(
      'a server dead from the first request stops after N, not 50 timeouts',
      () async {
        var calls = 0;
        final pass = RommMetadataFetch(
          listGames: (folder) async => games,
          linkIndex: () async => RommRomIdIndex({
            for (var i = 0; i < games.length; i++)
              RommRomIdIndex.keyFor('snes', games[i].filename): i,
          }),
          fetchOne: (target, system, mode) async {
            calls++;
            await Future<void>.delayed(Duration.zero);
            return _transportFailure;
          },
        );

        final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

        expect(summary.serverProtectionStop, isTrue);
        expect(
          summary.cancelled,
          isFalse,
          reason: 'the user did not cancel; the pass stopped for the server',
        );
        expect(
          summary.notFound,
          0,
          reason: 'a dead server must not be reported as games missing',
        );
        expect(
          calls,
          allOf(
            greaterThanOrEqualTo(
              RommMetadataFetch.maxConsecutiveTransportFailures,
            ),
            lessThanOrEqualTo(
              RommMetadataFetch.maxConsecutiveTransportFailures +
                  RommMetadataFetch.concurrency,
            ),
          ),
          reason:
              'only the games already dispatched plus one pool burst are '
              'asked; the remaining ${games.length} games never issue a '
              'request',
        );
        expect(summary.skipped, games.length - calls);
        expect(summary.transportFailures, calls);
      },
    );

    test(
      'a server that dies mid-pass: earlier games keep their results',
      () async {
        final summary = await run(
          (romId) async => romId < 10 ? _success : _transportFailure,
        );

        expect(summary.filled, 10, reason: 'the healthy games completed');
        expect(summary.serverProtectionStop, isTrue);
        expect(summary.skipped, greaterThan(0));
        expect(summary.failed, greaterThanOrEqualTo(5));
      },
    );

    test(
      'failures below the threshold in a row never trip the breaker',
      () async {
        // Four in a row — one under the threshold — then a success, over and
        // over: 50 games, 40 failures, never five consecutive.
        final summary = await run(
          (romId) async => romId % 5 == 4 ? _success : _transportFailure,
        );

        expect(summary.serverProtectionStop, isFalse);
        expect(summary.skipped, 0);
        expect(summary.failed, 40);
        expect(summary.filled, 10);
      },
    );

    test('a success between failures resets the consecutive count', () async {
      // With the reset working, the streak never passes 4 (four failures,
      // one success, four failures, ...). Without it, the second block of
      // failures would reach 8 consecutive and trip.
      final summary = await run(
        (romId) async => romId % 5 == 4 ? _success : _transportFailure,
      );

      expect(summary.serverProtectionStop, isFalse);
      expect(summary.skipped, 0);
    });

    test('a notFound game never counts toward the breaker', () async {
      final summary = await run((romId) async => _notFound);

      expect(summary.notFound, 50);
      expect(summary.serverProtectionStop, isFalse);
      expect(summary.skipped, 0);
      expect(summary.transportFailures, 0);
    });

    test('a parse error on one game never counts toward the breaker', () async {
      final summary = await run((romId) async => _parseErrorFailure);

      expect(summary.failed, 50);
      expect(summary.serverProtectionStop, isFalse);
      expect(summary.skipped, 0);
    });

    test(
      'a media 404 partial (not transport) never counts toward the breaker',
      () async {
        final summary = await run((romId) async => _media404Partial);

        expect(summary.filled, 50, reason: 'partials count as completed');
        expect(summary.serverProtectionStop, isFalse);
        expect(summary.skipped, 0);
      },
    );

    test('a media transport failure counts once per game', () async {
      final summary = await run((romId) async => _mediaTransportPartial);

      expect(summary.serverProtectionStop, isTrue);
      expect(
        summary.transportFailures,
        lessThanOrEqualTo(
          RommMetadataFetch.maxConsecutiveTransportFailures +
              RommMetadataFetch.concurrency,
        ),
        reason: 'one increment per game however many media types failed',
      );
      expect(summary.skipped, greaterThan(0));
    });

    test(
      'the breaker tripping never lets peak in-flight exceed the bound',
      () async {
        var inFlight = 0;
        var peak = 0;
        final pass = RommMetadataFetch(
          listGames: (folder) async => games,
          linkIndex: () async => RommRomIdIndex({
            for (var i = 0; i < games.length; i++)
              RommRomIdIndex.keyFor('snes', games[i].filename): i,
          }),
          fetchOne: (target, system, mode) async {
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            await Future<void>.delayed(Duration.zero);
            inFlight--;
            return _transportFailure;
          },
        );

        await pass.run(_snes, RommMetadataMode.fillGaps);

        expect(peak, lessThanOrEqualTo(RommMetadataFetch.concurrency));
        expect(peak, greaterThan(1), reason: 'the pool really parallelises');
      },
    );
  });

  group('429 Retry-After pause', () {
    setUp(() {
      RommMetadataFetch.resetActiveForTesting();
      LoggerService.instance.startCapture();
    });
    tearDown(() {
      LoggerService.instance.takeCapture();
      RommMetadataFetch.resetActiveForTesting();
    });

    final games = [for (var i = 0; i < 10; i++) _game(i)];

    RommMetadataFetch passOf(
      Future<RommMetadataOutcome> Function(int romId) outcomeFor, {
      DateTime Function()? clock,
      Future<void> Function(Duration)? sleep,
    }) => RommMetadataFetch(
      listGames: (folder) async => games,
      linkIndex: () async => RommRomIdIndex({
        for (var i = 0; i < games.length; i++)
          RommRomIdIndex.keyFor('snes', games[i].filename): i,
      }),
      fetchOne: (target, system, mode) async {
        await Future<void>.delayed(Duration.zero);
        return outcomeFor(target.romId);
      },
      clock: clock,
      sleep: sleep,
    );

    RommMetadataOutcome rateLimited([Duration? retryAfter]) =>
        RommMetadataOutcome.failed(
          StateError('rate limited'),
          transportClass: true,
          retryAfter: retryAfter,
        );

    test(
      'a 429 with Retry-After pauses the pool and the pass resumes',
      () async {
        final watch = Stopwatch()..start();
        final summary = await passOf(
          (romId) async => romId == 0
              ? rateLimited(const Duration(milliseconds: 150))
              : _success,
        ).run(_snes, RommMetadataMode.fillGaps);
        watch.stop();

        expect(summary.filled, 9, reason: 'the healthy games all ran');
        expect(summary.failed, 1);
        expect(summary.pauses, 1);
        expect(
          watch.elapsedMilliseconds,
          greaterThanOrEqualTo(140),
          reason: 'the pool really waited out the Retry-After',
        );
        expect(
          summary.paused.inMilliseconds,
          greaterThanOrEqualTo(140),
          reason: 'the paused total is measured, not asserted',
        );
        expect(summary.serverProtectionStop, isFalse);
      },
    );

    test(
      'a hostile Retry-After is clamped to the cap by the pass too',
      () async {
        var fakeNow = DateTime(2026, 10, 9, 12);
        final slices = <Duration>[];
        final summary = await passOf(
          (romId) async =>
              romId == 0 ? rateLimited(const Duration(hours: 2)) : _success,
          clock: () => fakeNow,
          sleep: (d) async {
            slices.add(d);
            fakeNow = fakeNow.add(d);
          },
        ).run(_snes, RommMetadataMode.fillGaps);

        expect(summary.filled, 9);
        final total = slices.fold(Duration.zero, (a, b) => a + b);
        expect(
          total,
          lessThanOrEqualTo(RommService.retryAfterCap),
          reason:
              'a value that bypassed the service clamp still cannot pause the '
              'pass past the cap',
        );
      },
    );

    test(
      'a missing Retry-After (null) is safe: no pause, and only the breaker counts',
      () async {
        final summary = await passOf(
          (romId) async => romId == 0 ? rateLimited(null) : _success,
        ).run(_snes, RommMetadataMode.fillGaps);

        expect(summary.filled, 9);
        expect(summary.pauses, 0, reason: 'nothing to wait for');
        expect(summary.paused, Duration.zero);
        expect(summary.serverProtectionStop, isFalse);
      },
    );

    test('repeated 429s count toward the breaker even while pausing', () async {
      final summary = await passOf(
        (romId) async => rateLimited(const Duration(milliseconds: 10)),
      ).run(_snes, RommMetadataMode.fillGaps);

      expect(summary.serverProtectionStop, isTrue);
      expect(summary.transportFailures, greaterThanOrEqualTo(5));
      expect(summary.pauses, greaterThanOrEqualTo(1));
    });

    test('cancel during a pause ends the pass within one poll slice', () async {
      final pass = passOf(
        (romId) async => rateLimited(const Duration(seconds: 30)),
      );
      final watch = Stopwatch()..start();
      final running = pass.run(_snes, RommMetadataMode.fillGaps);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      pass.cancel();
      final summary = await running;
      watch.stop();

      expect(summary.cancelled, isTrue);
      expect(summary.skipped, greaterThan(0));
      expect(
        watch.elapsedMilliseconds,
        lessThan(2000),
        reason:
            'a 30-second pause must not outlive the cancel that interrupted '
            'it (it exits within one 50ms poll slice)',
      );
      expect(summary.serverProtectionStop, isFalse);
    });
  });

  // ── Writer-level: the real writer against a scripted server ─────────────

  group('circuit breaker (real writer)', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory root;
    late _TempMedia media;
    late _ScriptedService svc;
    late _TestProvider provider;

    setUp(() async {
      RommMetadataNetwork.resetForTesting();
      RommMetadataFetch.resetActiveForTesting();
      db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(
        "INSERT INTO app_systems (id, folder_name) VALUES ('snes', 'snes')",
      );
      root = await Directory.systemTemp.createTemp('romm_breaker_');
      media = _TempMedia(root.path);
      svc = _ScriptedService();
      provider = _TestProvider(svc);
      LoggerService.instance.startCapture();
    });

    tearDown(() async {
      LoggerService.instance.takeCapture();
      RommMetadataFetch.resetActiveForTesting();
      await helper.tearDown();
      await root.delete(recursive: true);
    });

    RommMetadataFetch pass(int count) => RommMetadataFetch(
      listGames: (folder) async => [for (var i = 0; i < count; i++) _game(i)],
      linkIndex: () async => RommRomIdIndex({
        for (var i = 0; i < count; i++)
          RommRomIdIndex.keyFor('snes', _game(i).filename): i,
      }),
      fetchOne: (target, system, mode) => provider.fetchMetadataForRomId(
        romId: target.romId,
        system: system,
        fileProvider: media,
        indexedName: target.indexedName,
        mode: mode,
      ),
    );

    Future<Map<String, dynamic>?> rowOf(String filename) async {
      final rows = await db.rawQuery(
        'SELECT * FROM user_screenscraper_metadata '
        'WHERE app_system_id = ? AND filename = ?',
        ['snes', filename],
      );
      return rows.isEmpty ? null : rows.first;
    }

    test(
      'a server that dies mid-pass keeps every row written before it died',
      () async {
        svc.failDetailFrom = 10;

        final summary = await pass(30).run(_snes, RommMetadataMode.fillGaps);

        expect(summary.filled, 10, reason: 'the first ten games wrote');
        expect(summary.serverProtectionStop, isTrue);
        expect(
          summary.notFound,
          0,
          reason: 'never "not found" for a dead server',
        );
        expect(summary.skipped, greaterThan(0));
        for (var i = 0; i < 10; i++) {
          final row = await rowOf('game$i.sfc');
          expect(row, isNotNull, reason: 'game$i keeps its metadata');
        }
        expect(await rowOf('game29.sfc'), isNull, reason: 'never reached');
        expect(
          svc.detailCalls,
          lessThan(20),
          reason: 'the remaining games are not asked',
        );
      },
    );

    test(
      'a dead server is not walked: requests stop after the threshold',
      () async {
        svc.failDetailFrom = 0;

        final summary = await pass(50).run(_snes, RommMetadataMode.fillGaps);

        expect(summary.serverProtectionStop, isTrue);
        expect(summary.failed, greaterThanOrEqualTo(5));
        expect(
          svc.detailCalls,
          lessThanOrEqualTo(
            RommMetadataFetch.maxConsecutiveTransportFailures +
                RommMetadataFetch.concurrency,
          ),
          reason: 'every remaining game would otherwise cost a 30s timeout',
        );
        expect(
          svc.detailCalls + svc.mediaCalls,
          svc.detailCalls,
          reason: 'no media is asked for when the detail already failed',
        );
      },
    );

    test(
      'a media transport failure counts per game and stops the pass',
      () async {
        svc.failingMedia.add(_coverUrl);

        final summary = await pass(50).run(_snes, RommMetadataMode.fillGaps);

        expect(summary.serverProtectionStop, isTrue);
        expect(summary.skipped, greaterThan(0));
        expect(summary.transportFailures, greaterThanOrEqualTo(5));
      },
    );

    test(
      'the one measurement line reports requests, peak, pauses and the stop reason',
      () async {
        await pass(10).run(_snes, RommMetadataMode.fillGaps);

        final lines = LoggerService.instance
            .takeCapture()
            .where((l) => l.startsWith('i|RomM metadata fetch pass'))
            .toList();
        expect(lines, hasLength(1), reason: 'exactly one line per run');
        final line = lines.single;
        expect(line, contains('detail_requests=10'));
        expect(
          line,
          contains('media_requests=20'),
          reason:
              'the cover plus the fanart type\'s cover fallback, per game, '
              'through the fake',
        );
        expect(line, contains('peak_in_flight=3'));
        expect(line, contains('pauses=0'));
        expect(line, contains('stopped=false'));
        expect(line, contains('complete:'), reason: 'why the run ended');
        expect(
          line,
          isNot(contains('romm.invalid')),
          reason: 'no hostname in the measurement',
        );
      },
    );

    test(
      'the measurement line reports the stop reason and pauses of a protected run',
      () async {
        svc.rateLimitDetailFrom = 0;
        svc.retryAfter = const Duration(milliseconds: 10);

        await pass(10).run(_snes, RommMetadataMode.fillGaps);

        final line = LoggerService.instance.takeCapture().firstWhere(
          (l) => l.startsWith('i|RomM metadata fetch pass'),
        );
        expect(line, contains('stopped:'));
        expect(line, contains('transport_failures='));
        expect(line, contains('pauses='));
        expect(line, contains('paused_ms='));
      },
    );
  });
}

// ── Fakes ──────────────────────────────────────────────────────────────────

/// The scripted server: every game healthy until a knob turns a failure on,
/// with the request counters and in-flight measurement the assertions read.
class _ScriptedService extends RommService {
  /// Detail GETs for rom ids at or above this are unreachable.
  int failDetailFrom = 1 << 30;

  /// Detail GETs for rom ids at or above this are rate limited.
  int rateLimitDetailFrom = 1 << 30;

  /// The Retry-After a rate-limited answer carries.
  Duration? retryAfter;

  /// Media URLs that fail to download (transport class).
  final Set<String> failingMedia = {};

  int detailCalls = 0;
  int mediaCalls = 0;
  int _inFlight = 0;
  int peakInFlight = 0;

  final Map<String, Uint8List> assets = {_coverUrl: _png};

  Future<void> _hold() async {
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    _inFlight--;
  }

  Map<String, dynamic> _detail(int id) => {
    'id': id,
    'name': 'Game $id',
    'fs_name': 'game$id.sfc',
    'fs_name_no_ext': 'game$id',
    'fs_extension': 'sfc',
    'platform_id': 1,
    'platform_slug': 'snes',
    'summary': 'A game.',
    'path_cover_large': _coverUrl,
  };

  @override
  Future<RommDetailFetch> fetchRomDetail(int id) async {
    detailCalls++;
    await _hold();
    if (id >= rateLimitDetailFrom) {
      return RommDetailFetch.missing(
        RommDetailMiss.rateLimited,
        retryAfter: retryAfter,
      );
    }
    if (id >= failDetailFrom) {
      return const RommDetailFetch.missing(RommDetailMiss.unreachable);
    }
    return RommDetailFetch.found(_detail(id));
  }

  @override
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async {
    mediaCalls++;
    await _hold();
    if (failingMedia.contains(pathOrUrl)) {
      return const RommImageFetch.missing(RommImageMiss.unreachable);
    }
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
}

/// Media paths rooted in a temp directory, the same shape the app writes.
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
