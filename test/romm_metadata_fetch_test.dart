import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';

/// The per-system pass ([RommMetadataFetch]) against in-memory fakes: a
/// scanned library, a link map, and a scripted writer whose fetches can be
/// held open behind gates. No filesystem, no database, no network, and no
/// widget — the pass is supposed to need none of them, which is also why a
/// dialog closing under it cannot stop it (SPEC-0005 "Concurrency Safety").
///
/// What is pinned (SPEC-0005 "Per-System Fetch Pass"): only linked games are
/// fetched and unlinked ones are counted; at most the bulk-sync concurrency
/// is in flight; cancel stops new fetches while in-flight ones complete;
/// a second run is refused while one runs and allowed after; one failing
/// game is counted, logged with its id, and the pass continues; not found is
/// counted; and exactly one summary line is logged per run.

// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);

const _nes = SystemModel(
  id: 'nes',
  folderName: 'nes',
  realName: 'Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['nes'],
);

DatabaseGameModel _game(int i, {String folder = 'snes'}) => DatabaseGameModel(
  filename: 'Game $i.sfc',
  romPath: '/roms/$folder/Game $i.sfc',
  systemFolderName: folder,
);

/// [count] games of which the first [linked] have a map row (rom id = index).
({List<DatabaseGameModel> games, RommRomIdIndex index}) _library({
  required int count,
  required int linked,
  String folder = 'snes',
}) {
  final games = [for (var i = 0; i < count; i++) _game(i, folder: folder)];
  final rows = <String, int>{
    for (var i = 0; i < linked; i++) '$folder\t${games[i].filename}': i,
  };
  return (games: games, index: RommRomIdIndex(rows));
}

/// The writer: records every call, keeps a per-call gate when [gated], and
/// scripts the outcome per rom id.
class _FakeWriter {
  final bool gated;
  final Set<int> failing;
  final Set<int> notFound;
  final Set<int> partial;

  _FakeWriter({
    this.gated = false,
    this.failing = const {},
    this.notFound = const {},
    this.partial = const {},
  });

  final List<int> calls = [];
  final List<RommMetadataMode> modes = [];
  final Map<int, Completer<void>> _gates = {};
  int inFlight = 0;
  int maxInFlight = 0;
  int completed = 0;

  Future<RommMetadataOutcome> call(
    RommMetadataFetchTarget target,
    SystemModel system,
    RommMetadataMode mode,
  ) async {
    calls.add(target.romId);
    modes.add(mode);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    if (gated) {
      final gate = _gates.putIfAbsent(target.romId, Completer<void>.new);
      await gate.future;
    }
    inFlight--;
    completed++;
    if (failing.contains(target.romId)) {
      throw StateError('detail request for rom ${target.romId} timed out');
    }
    if (notFound.contains(target.romId)) {
      return const RommMetadataOutcome.notFound();
    }
    if (partial.contains(target.romId)) {
      return RommMetadataOutcome(
        kind: RommMetadataOutcomeKind.partial,
        columnsWritten: 3,
        mediaFailed: 1,
        error: StateError('cover download failed'),
      );
    }
    return RommMetadataOutcome(
      kind: mode == RommMetadataMode.fillGaps
          ? RommMetadataOutcomeKind.filled
          : RommMetadataOutcomeKind.replaced,
      columnsWritten: 3,
    );
  }

  /// Rom ids whose fetch is in flight, oldest first.
  List<int> get pending => [
    for (final e in _gates.entries)
      if (!e.value.isCompleted) e.key,
  ];

  /// Lets the oldest in-flight fetch finish.
  void releaseOne() {
    final id = pending.first;
    _gates[id]!.complete();
  }

  /// Lets every in-flight fetch finish, and any that start afterwards.
  void releaseAll() {
    for (final id in pending) {
      _gates[id]!.complete();
    }
    _releaseFuture = true;
  }

  bool _releaseFuture = false;

  /// Whether new fetches should pass straight through after [releaseAll].
  bool get openGates => _releaseFuture;
}

/// Flushes the event loop enough times for the pass's awaits to settle.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A writer whose gates open on their own once [_FakeWriter.releaseAll] ran,
/// so a run can be driven to the end after the interesting part.
RommMetadataFetchOne _gatedOrOpen(_FakeWriter writer) =>
    (target, system, mode) async {
      if (writer.openGates) {
        writer._gates.putIfAbsent(target.romId, Completer<void>.new).complete();
      }
      return writer(target, system, mode);
    };

RommMetadataFetch _pass({
  required List<DatabaseGameModel> games,
  required RommRomIdIndex index,
  required RommMetadataFetchOne fetchOne,
  bool Function()? shouldStop,
  void Function(int done, int total)? onProgress,
  Object? listGamesError,
}) => RommMetadataFetch(
  listGames: (folder) async {
    if (listGamesError != null) throw listGamesError;
    return games;
  },
  linkIndex: () async => index,
  fetchOne: fetchOne,
  shouldStop: shouldStop,
  onProgress: onProgress,
);

/// The summary lines the pass logged, from the logger's capture.
List<String> _summaryLines() => LoggerService.instance
    .takeCapture()
    .where((l) => l.startsWith('i|RomM metadata fetch pass'))
    .toList();

void main() {
  setUp(() {
    RommMetadataFetch.resetActiveForTesting();
    LoggerService.instance.startCapture();
  });
  tearDown(() {
    LoggerService.instance.takeCapture();
    RommMetadataFetch.resetActiveForTesting();
  });

  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
  test('fetches with bulk sync\'s concurrency, from one definition', () {
    expect(RommMetadataFetch.concurrency, RommBulkSync.defaultConcurrency);
  });

  group('mixed system', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
    test(
      '120 games / 100 linked: 100 fetches, 20 unlinked counted, counts',
      () async {
        final lib = _library(count: 120, linked: 100);
        final writer = _FakeWriter();
        final progress = <(int, int)>[];
        final pass = _pass(
          games: lib.games,
          index: lib.index,
          fetchOne: writer.call,
          onProgress: (done, total) => progress.add((done, total)),
        );

        final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

        expect(writer.calls.length, 100);
        expect(writer.calls.toSet(), {for (var i = 0; i < 100; i++) i});
        expect(writer.modes.toSet(), {RommMetadataMode.fillGaps});
        expect(summary.linked, 100);
        expect(summary.filled, 100);
        expect(summary.replaced, 0);
        expect(summary.unlinkedSkipped, 20);
        expect(summary.notFound, 0);
        expect(summary.failed, 0);
        expect(summary.cancelled, isFalse);
        expect(summary.skipped, 0);
        expect(summary.wroteSomething, isTrue);
        // One progress call up front, then one per completed game.
        expect(progress.first, (0, 100));
        expect(progress.last, (100, 100));
        expect(progress.length, 101);
        expect(pass.isRunning, isFalse);
        expect(RommMetadataFetch.active, isNull);
      },
    );

    test('replace mode counts writes as replaced', () async {
      final lib = _library(count: 5, linked: 5);
      final writer = _FakeWriter();
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: writer.call,
      );

      final summary = await pass.run(_snes, RommMetadataMode.replace);

      expect(writer.modes.toSet(), {RommMetadataMode.replace});
      expect(summary.replaced, 5);
      expect(summary.filled, 0);
    });

    test(
      'a game linked under the extension-stripped spelling is linked',
      () async {
        final games = [_game(0), _game(1)];
        final index = RommRomIdIndex({'snes\tGame 0': 7});
        final writer = _FakeWriter();
        final pass = _pass(games: games, index: index, fetchOne: writer.call);

        final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

        expect(writer.calls, [7]);
        expect(summary.linked, 1);
        expect(summary.unlinkedSkipped, 1);
      },
    );

    test('a system with no games or no links fetches nothing', () async {
      final lib = _library(count: 3, linked: 0);
      final writer = _FakeWriter();
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: writer.call,
      );

      final summary = await pass.run(_nes, RommMetadataMode.fillGaps);

      expect(writer.calls, isEmpty);
      expect(summary.linked, 0);
      expect(summary.unlinkedSkipped, 3);
      expect(summary.wroteSomething, isFalse);
      expect(_summaryLines(), hasLength(1));
    });
  });

  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
  test('never more than the bulk-sync concurrency is in flight', () async {
    final lib = _library(count: 20, linked: 20);
    final writer = _FakeWriter(gated: true);
    final pass = _pass(
      games: lib.games,
      index: lib.index,
      fetchOne: _gatedOrOpen(writer),
    );

    final run = pass.run(_snes, RommMetadataMode.fillGaps);
    await _settle();

    expect(writer.inFlight, RommBulkSync.defaultConcurrency);
    expect(writer.calls.length, RommBulkSync.defaultConcurrency);

    // Each completion admits exactly one more.
    writer.releaseOne();
    await _settle();
    expect(writer.inFlight, RommBulkSync.defaultConcurrency);
    expect(writer.calls.length, RommBulkSync.defaultConcurrency + 1);

    writer.releaseAll();
    final summary = await run;

    expect(writer.maxInFlight, RommBulkSync.defaultConcurrency);
    expect(writer.calls.length, 20);
    expect(summary.filled, 20);
  });

  group('cancel', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
    test('after 40 of 100: no further fetches start, in-flight complete, '
        'cancelled reported', () async {
      final lib = _library(count: 100, linked: 100);
      final writer = _FakeWriter(gated: true);
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: _gatedOrOpen(writer),
      );

      final run = pass.run(_snes, RommMetadataMode.fillGaps);
      await _settle();
      while (writer.completed < 40) {
        writer.releaseOne();
        await _settle();
      }
      expect(pass.done, 40);
      final startedBeforeCancel = writer.calls.length;
      expect(startedBeforeCancel, 40 + RommBulkSync.defaultConcurrency);

      pass.cancel();
      expect(pass.cancelRequested, isTrue);
      await _settle();
      // Cancel never interrupts a fetch: the three in flight are still
      // waiting on their gates, and nothing new has been admitted.
      expect(writer.inFlight, RommBulkSync.defaultConcurrency);
      expect(writer.calls.length, startedBeforeCancel);

      writer.releaseAll();
      final summary = await run;

      expect(writer.calls.length, startedBeforeCancel);
      expect(summary.cancelled, isTrue);
      expect(summary.linked, 100);
      // The 40 done plus the in-flight ones that completed keep their
      // writes; the rest were never started.
      expect(summary.filled, startedBeforeCancel);
      expect(summary.skipped, 100 - startedBeforeCancel);
      expect(summary.failed, 0);
      expect(pass.isRunning, isFalse);
      expect(RommMetadataFetch.active, isNull);
    });

    test('the injected stop check ends the pass the same way', () async {
      final lib = _library(count: 10, linked: 10);
      final writer = _FakeWriter();
      var stop = false;
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: (target, system, mode) async {
          final outcome = await writer(target, system, mode);
          if (writer.completed >= 2) stop = true;
          return outcome;
        },
        shouldStop: () => stop,
      );

      final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

      expect(summary.cancelled, isTrue);
      expect(writer.calls.length, lessThan(10));
      expect(summary.filled, writer.calls.length);
    });

    test('cancel on an idle pass is a no-op', () {
      final lib = _library(count: 1, linked: 1);
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: _FakeWriter().call,
      );
      pass.cancel();
      expect(pass.cancelRequested, isFalse);
    });
  });

  group('one pass at a time', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
    test('a second run on any system is refused while one runs', () async {
      final lib = _library(count: 5, linked: 5);
      final writer = _FakeWriter(gated: true);
      final first = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: _gatedOrOpen(writer),
      );
      final other = _FakeWriter();
      final second = _pass(
        games: _library(count: 2, linked: 2, folder: 'nes').games,
        index: _library(count: 2, linked: 2, folder: 'nes').index,
        fetchOne: other.call,
      );

      final run = first.run(_snes, RommMetadataMode.fillGaps);
      await _settle();
      expect(RommMetadataFetch.active, same(first));

      await expectLater(
        second.run(_nes, RommMetadataMode.fillGaps),
        throwsA(
          isA<RommMetadataFetchBusyException>()
              .having((e) => e.runningSystemFolder, 'running', 'snes')
              .having((e) => e.requestedSystemFolder, 'requested', 'nes'),
        ),
      );
      expect(other.calls, isEmpty);
      // The refusal must not disturb the running pass.
      expect(RommMetadataFetch.active, same(first));
      expect(first.isRunning, isTrue);

      writer.releaseAll();
      await run;
      expect(RommMetadataFetch.active, isNull);

      // And once it is done, the next pass is allowed.
      final summary = await second.run(_nes, RommMetadataMode.fillGaps);
      expect(other.calls.length, 2);
      expect(summary.filled, 2);
    });

    test('the same instance refuses to overlap with itself', () async {
      final lib = _library(count: 3, linked: 3);
      final writer = _FakeWriter(gated: true);
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: _gatedOrOpen(writer),
      );

      final run = pass.run(_snes, RommMetadataMode.fillGaps);
      await _settle();
      await expectLater(
        pass.run(_snes, RommMetadataMode.replace),
        throwsA(isA<RommMetadataFetchBusyException>()),
      );
      writer.releaseAll();
      await run;
    });
  });

  group('per-game outcomes', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
    test(
      'one throwing fetch is counted, logged with its id, pass continues',
      () async {
        final lib = _library(count: 10, linked: 10);
        final writer = _FakeWriter(failing: {4});
        final pass = _pass(
          games: lib.games,
          index: lib.index,
          fetchOne: writer.call,
        );

        final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

        expect(writer.calls.length, 10);
        expect(summary.failed, 1);
        expect(summary.filled, 9);
        expect(summary.cancelled, isFalse);

        final lines = LoggerService.instance.takeCapture();
        final warnings = lines.where((l) => l.startsWith('w|')).toList();
        expect(warnings, hasLength(1));
        expect(warnings.single, contains('rom=4'));
        expect(warnings.single, contains('Game 4.sfc'));
        expect(warnings.single, contains('timed out'));
        expect(
          lines.where((l) => l.startsWith('i|RomM metadata fetch pass')),
          hasLength(1),
        );
      },
    );

    test('a failed outcome (not a throw) is counted the same way', () async {
      final lib = _library(count: 3, linked: 3);
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: (target, system, mode) async => target.romId == 1
            ? RommMetadataOutcome.failed(
                RommMetadataFetchException(
                  stage: 'detail',
                  romId: 1,
                  filename: target.indexedName,
                  cause: 'boom',
                ),
              )
            : const RommMetadataOutcome(kind: RommMetadataOutcomeKind.filled),
      );

      final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

      expect(summary.failed, 1);
      expect(summary.filled, 2);
    });

    test('not found is counted and writes nothing', () async {
      final lib = _library(count: 6, linked: 6);
      final writer = _FakeWriter(notFound: {0, 5});
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: writer.call,
      );

      final summary = await pass.run(_snes, RommMetadataMode.fillGaps);

      expect(summary.notFound, 2);
      expect(summary.filled, 4);
      expect(summary.failed, 0);
    });

    test('a partial write counts for the mode it ran in', () async {
      final lib = _library(count: 2, linked: 2);
      final writer = _FakeWriter(partial: {1});
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: writer.call,
      );

      expect((await pass.run(_snes, RommMetadataMode.fillGaps)).filled, 2);
      expect((await pass.run(_snes, RommMetadataMode.replace)).replaced, 2);
    });
  });

  group('summary log line', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
    test('exactly one per run, with every count as key=value', () async {
      final lib = _library(count: 12, linked: 10);
      final writer = _FakeWriter(notFound: {2}, failing: {3});
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: writer.call,
      );

      await pass.run(_snes, RommMetadataMode.fillGaps);

      final lines = _summaryLines();
      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line, contains('pass complete:'));
      expect(line, contains('system=snes'));
      expect(line, contains('mode=fillGaps'));
      expect(line, contains('linked=10'));
      expect(line, contains('filled=8'));
      expect(line, contains('replaced=0'));
      expect(line, contains('unlinked_skipped=2'));
      expect(line, contains('not_found=1'));
      expect(line, contains('failed=1'));
      expect(line, contains('cancelled=false'));
      expect(line, contains('elapsed_ms='));
    });

    test('a cancelled run says so in its one line', () async {
      final lib = _library(count: 8, linked: 8);
      var stop = false;
      final writer = _FakeWriter();
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: (target, system, mode) async {
          stop = true;
          return writer(target, system, mode);
        },
        shouldStop: () => stop,
      );

      await pass.run(_snes, RommMetadataMode.fillGaps);

      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('pass cancelled:'));
      expect(lines.single, contains('cancelled=true'));
    });
  });

  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
  test(
    'an unreadable library is a named failure and releases the guard',
    () async {
      final pass = _pass(
        games: const [],
        index: const RommRomIdIndex({}),
        fetchOne: _FakeWriter().call,
        listGamesError: StateError('database closed'),
      );

      await expectLater(
        pass.run(_snes, RommMetadataMode.fillGaps),
        throwsA(
          isA<RommMetadataFetchPassException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('listing games of "snes"'),
              contains('database closed'),
            ),
          ),
        ),
      );
      expect(pass.isRunning, isFalse);
      expect(RommMetadataFetch.active, isNull);
      expect(_summaryLines(), isEmpty);
    },
  );

  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
  test(
    'the notifier reports progress and the active pass for any listener',
    () async {
      final lib = _library(count: 4, linked: 4);
      final writer = _FakeWriter(gated: true);
      final pass = _pass(
        games: lib.games,
        index: lib.index,
        fetchOne: _gatedOrOpen(writer),
      );
      final seenActive = <RommMetadataFetch?>[];
      final seenDone = <int>[];
      void onActive() => seenActive.add(RommMetadataFetch.activeNotifier.value);
      void onPass() => seenDone.add(pass.done);
      RommMetadataFetch.activeNotifier.addListener(onActive);
      pass.addListener(onPass);

      final run = pass.run(_snes, RommMetadataMode.fillGaps);
      await _settle();
      expect(pass.system, same(_snes));
      expect(pass.mode, RommMetadataMode.fillGaps);
      expect(pass.total, 4);
      writer.releaseAll();
      await run;

      RommMetadataFetch.activeNotifier.removeListener(onActive);
      pass.removeListener(onPass);
      expect(seenActive.first, same(pass));
      expect(seenActive.last, isNull);
      expect(seenDone.last, 4);
    },
  );
}
