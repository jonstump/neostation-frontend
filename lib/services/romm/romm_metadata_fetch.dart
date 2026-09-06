import 'package:flutter/foundation.dart';

import '../../models/database_game_model.dart';
import '../../models/romm_metadata_fetch.dart';
import '../../models/system_model.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../utils/bounded_concurrency.dart';
import '../logger_service.dart';
import 'romm_paging.dart';

/// The scanned games of one system — the library index, never the disk.
typedef RommSystemGameLister =
    Future<List<DatabaseGameModel>> Function(String systemFolder);

/// The whole link map, read once up front so the pass can tell linked games
/// from unlinked ones without a query per game.
typedef RommLinkIndexLoader = Future<RommRomIdIndex> Function();

/// The RomM metadata writer for one linked game. The provider's
/// `fetchMetadataForRomId` never throws, but a fake or a wrapper might, and a
/// throw is treated exactly like a failed outcome.
typedef RommMetadataFetchOne =
    Future<RommMetadataOutcome> Function(
      RommMetadataFetchTarget target,
      SystemModel system,
      RommMetadataMode mode,
    );

/// Polled before each game starts; true ends the pass after the in-flight
/// fetches complete.
typedef RommMetadataStopCheck = bool Function();

/// Called after each linked game completes, with the running count.
typedef RommMetadataProgress = void Function(int done, int total);

/// One linked game the pass will fetch: the scanned row and the RomM ROM id
/// its map row points at.
@immutable
class RommMetadataFetchTarget {
  final DatabaseGameModel game;
  final int romId;

  const RommMetadataFetchTarget({required this.game, required this.romId});

  /// The on-disk filename with extension — the key the metadata row is
  /// written under (see `RommProvider.fetchMetadataForRomId`).
  String get indexedName => game.filename;

  @override
  String toString() => 'rom $romId (${game.filename})';
}

/// What one run of [RommMetadataFetch] did — the counts the summary
/// notification and the single summary log line report.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
@immutable
class RommMetadataFetchSummary {
  /// Games of the system with a map row — the ones the pass set out to fetch.
  final int linked;

  /// Linked games whose fill-gaps fetch wrote (or partially wrote) the row.
  final int filled;

  /// Linked games whose replace fetch wrote (or partially wrote) the row.
  final int replaced;

  /// Games of the system with no map row; counted, never fetched.
  final int unlinkedSkipped;

  /// Linked games the server had no detail for.
  final int notFound;

  /// Linked games whose fetch failed; each is logged with its rom id.
  final int failed;

  /// True when a cancel (or the injected stop check) ended the pass before
  /// every linked game was fetched. The games already written keep their
  /// metadata.
  final bool cancelled;

  /// Wall-clock time of the run.
  final Duration elapsed;

  const RommMetadataFetchSummary({
    this.linked = 0,
    this.filled = 0,
    this.replaced = 0,
    this.unlinkedSkipped = 0,
    this.notFound = 0,
    this.failed = 0,
    this.cancelled = false,
    this.elapsed = Duration.zero,
  });

  /// Linked games the pass never started because it was cancelled.
  int get skipped => linked - filled - replaced - notFound - failed;

  /// True when at least one row was written, so the artwork caches and the
  /// library need refreshing.
  bool get wroteSomething => filled + replaced > 0;
}

/// A second pass was asked for while one was running. Only one pass runs at a
/// time across every system; the UI maps this to a localized notice naming
/// the system that is busy.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
class RommMetadataFetchBusyException implements Exception {
  /// The system whose pass is still running — or, for a target run
  /// ([RommMetadataFetch.runTargets]), its label.
  final String runningSystemFolder;

  /// The system the refused pass was for — or the refused target run's label.
  final String requestedSystemFolder;

  const RommMetadataFetchBusyException({
    required this.runningSystemFolder,
    required this.requestedSystemFolder,
  });

  @override
  String toString() =>
      'RomM metadata fetch pass refused for "$requestedSystemFolder": '
      'a pass is already running for "$runningSystemFolder"';
}

/// Why [RommMetadataFetch.run] could not run at all — the system's games or
/// the link map were unreadable. Per-game failures are counted, not thrown;
/// this is for the inputs nothing can proceed without.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
class RommMetadataFetchPassException implements Exception {
  final String context;
  final Object cause;

  const RommMetadataFetchPassException(this.context, this.cause);

  @override
  String toString() => 'RomM metadata fetch pass failed: $context: $cause';
}

/// The per-system "Fetch metadata from RomM" pass.
///
/// Lists the system's scanned games, reads the link map once, and runs the
/// injected writer over every game that has a map row — bounded to
/// [concurrency] fetches in flight, the same pool size bulk sync transfers
/// with, because `RommService` has no throttling of its own. Games without a
/// row are counted and never fetched. A failing game is counted and logged
/// with its rom id, and the pass moves on.
///
/// Dependencies are injected in the style of `RommLibraryLinker` so the
/// algorithm is testable with in-memory fakes and stays free of widgets and
/// providers: the dialog that starts a pass may close while it runs, and the
/// pass must keep going — progress goes out through [onProgress], which the
/// caller mirrors into the global notification, and through this notifier for
/// any row still on screen.
///
/// Only one pass runs at a time across every system: [run] refuses a second
/// with [RommMetadataFetchBusyException]. [cancel] (or the injected
/// [shouldStop]) ends the pass between games — the fetches already in flight
/// complete and their writes are kept.
///
/// [runTargets] runs the same bounded loop over a target list built by the
/// caller — the members a collection sync linked, which can span systems —
/// under the same guard, cancellation, counting and summary line.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Metadata For Linked Members"
class RommMetadataFetch extends ChangeNotifier {
  static final _defaultLog = LoggerService.instance;

  /// Detail fetches in flight at once — [RommPaging.concurrency], the one
  /// definition bulk sync (`RommBulkSync.defaultConcurrency`) reads too.
  static const int concurrency = RommPaging.concurrency;

  /// The pass currently running, or null. A [ValueNotifier] so a settings
  /// dialog opened while a pass is running can show its Cancel affordance and
  /// drop it when the pass ends, whichever dialog started it.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
  static final ValueNotifier<RommMetadataFetch?> activeNotifier =
      ValueNotifier<RommMetadataFetch?>(null);

  /// The pass currently running, or null.
  static RommMetadataFetch? get active => activeNotifier.value;

  /// Drops a pass the guard still holds. Only for tests whose run was left
  /// unfinished by an assertion failure; a finished run clears itself.
  @visibleForTesting
  static void resetActiveForTesting() => activeNotifier.value = null;

  final RommSystemGameLister _listGames;
  final RommLinkIndexLoader _linkIndex;
  final RommMetadataFetchOne _fetchOne;
  final RommMetadataStopCheck _shouldStop;
  final RommMetadataProgress? _onProgress;
  final DateTime Function() _clock;
  final LoggerService _log;

  bool _running = false;
  bool _cancelRequested = false;
  int _done = 0;
  int _total = 0;
  SystemModel? _system;
  String? _label;
  RommMetadataMode? _mode;

  RommMetadataFetch({
    required RommSystemGameLister listGames,
    required RommLinkIndexLoader linkIndex,
    required RommMetadataFetchOne fetchOne,
    RommMetadataStopCheck? shouldStop,
    RommMetadataProgress? onProgress,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _listGames = listGames,
       _linkIndex = linkIndex,
       _fetchOne = fetchOne,
       _shouldStop = shouldStop ?? _neverStop,
       _onProgress = onProgress,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// True while [run] is in progress.
  bool get isRunning => _running;

  /// True once [cancel] was called on a running pass.
  bool get cancelRequested => _cancelRequested;

  /// Linked games completed so far.
  int get done => _done;

  /// Linked games the pass set out to fetch (0 until the index is read).
  int get total => _total;

  /// The system of the running (or last) pass; null for a target run.
  SystemModel? get system => _system;

  /// The label of the running (or last) target run; null for a system pass.
  String? get label => _label;

  /// What the running (or last) pass is over, for a notice that names it:
  /// the system's display name, or the target run's label.
  String get subject =>
      _system?.realName ?? _system?.folderName ?? _label ?? '';

  /// The mode of the running (or last) pass.
  RommMetadataMode? get mode => _mode;

  /// Asks the running pass to stop. No further games start; the fetches in
  /// flight complete and their writes are kept.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
  void cancel() {
    if (!_running || _cancelRequested) return;
    _cancelRequested = true;
    _log.i(
      'RomM metadata fetch pass cancel requested '
      '(system=${_system?.folderName ?? _label}, done=$_done, total=$_total)',
    );
    notifyListeners();
  }

  bool get _stopRequested => _cancelRequested || _shouldStop();

  /// Runs one pass over [system] in [mode] and returns what it did.
  ///
  /// Fails with [RommMetadataFetchBusyException] — before any work, the
  /// guard is taken synchronously — when a pass is already running, and
  /// [RommMetadataFetchPassException] when the games or the link map could
  /// not be read. Per-game failures never propagate: they are counted and
  /// logged with the rom id.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
  Future<RommMetadataFetchSummary> run(
    SystemModel system,
    RommMetadataMode mode,
  ) async {
    _claim(requested: system.folderName, system: system, mode: mode);
    return _finish(scope: 'system=${system.folderName}', mode: mode, (
      started,
    ) async {
      final split = await _systemTargets(system);
      return _fetchTargets(
        split.targets,
        mode,
        (_) => system,
        started,
        unlinked: split.unlinked,
      );
    });
  }

  /// Runs one pass over an explicit [targets] list in [mode] — the members a
  /// collection sync linked, resolved by the caller and possibly spanning
  /// systems ([systemOf] names each target's) — and returns what it did.
  ///
  /// Same guard, cancellation, concurrency, per-game isolation and summary
  /// line as [run]; [label] stands in for the system name in the busy
  /// refusal and the log. Nothing is listed or looked up: every target is
  /// linked by construction, so `unlinkedSkipped` is 0.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Metadata For Linked Members"
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
  Future<RommMetadataFetchSummary> runTargets(
    List<RommMetadataFetchTarget> targets, {
    required RommMetadataMode mode,
    required SystemModel Function(RommMetadataFetchTarget target) systemOf,
    required String label,
  }) async {
    // Resolve every system before claiming the guard: a throwing lookup here
    // would otherwise leave the pass marked active with no run to release it.
    final folders = <String>{
      for (final target in targets) systemOf(target).folderName,
    };
    _claim(requested: label, label: label, mode: mode);
    return _finish(
      scope: 'targets="$label" systems=${folders.join(',')}',
      mode: mode,
      (started) => _fetchTargets(List.of(targets), mode, systemOf, started),
    );
  }

  /// Takes the process-wide guard for this pass, or throws
  /// [RommMetadataFetchBusyException] without touching anything.
  void _claim({
    required String requested,
    required RommMetadataMode mode,
    SystemModel? system,
    String? label,
  }) {
    final current = activeNotifier.value;
    if (current != null) {
      final running = current._system?.folderName ?? current._label ?? '';
      _log.w(
        'RomM metadata fetch pass refused '
        '(system=$requested): a pass is already running '
        '(system=$running)',
      );
      throw RommMetadataFetchBusyException(
        runningSystemFolder: running,
        requestedSystemFolder: requested,
      );
    }
    // Claimed before the first await so two starts in one event-loop turn
    // cannot both pass the check above.
    activeNotifier.value = this;
    _running = true;
    _cancelRequested = false;
    _done = 0;
    _total = 0;
    _system = system;
    _label = label;
    _mode = mode;
    notifyListeners();
  }

  /// Runs [body] under the guard taken by [_claim], logs the one summary
  /// line, and releases the guard however [body] ends.
  Future<RommMetadataFetchSummary> _finish(
    Future<RommMetadataFetchSummary> Function(DateTime started) body, {
    required String scope,
    required RommMetadataMode mode,
  }) async {
    final started = _clock();
    try {
      final summary = await body(started);
      _logSummary(scope, mode, summary);
      return summary;
    } finally {
      _running = false;
      if (identical(activeNotifier.value, this)) activeNotifier.value = null;
      notifyListeners();
    }
  }

  /// Lists [system]'s games and splits them into the linked ones (as
  /// targets) and a count of the rest.
  Future<({List<RommMetadataFetchTarget> targets, int unlinked})>
  _systemTargets(SystemModel system) async {
    final List<DatabaseGameModel> games;
    try {
      games = await _listGames(system.folderName);
    } catch (e) {
      throw RommMetadataFetchPassException(
        'listing games of "${system.folderName}" failed',
        e,
      );
    }
    final RommRomIdIndex index;
    try {
      index = await _linkIndex();
    } catch (e) {
      throw RommMetadataFetchPassException('reading the link map failed', e);
    }

    // Split the system into the linked games (fetched) and the rest (counted).
    final targets = <RommMetadataFetchTarget>[];
    var unlinked = 0;
    for (final game in games) {
      final romId = lookupRomId(index, game, system);
      if (romId == null) {
        unlinked++;
        continue;
      }
      targets.add(RommMetadataFetchTarget(game: game, romId: romId));
    }
    return (targets: targets, unlinked: unlinked);
  }

  /// The bounded loop both entry points share: fetches every target with at
  /// most [concurrency] in flight, counting each outcome.
  Future<RommMetadataFetchSummary> _fetchTargets(
    List<RommMetadataFetchTarget> targets,
    RommMetadataMode mode,
    SystemModel Function(RommMetadataFetchTarget target) systemOf,
    DateTime started, {
    int unlinked = 0,
  }) async {
    _total = targets.length;
    _done = 0;
    notifyListeners();
    _onProgress?.call(0, _total);

    var filled = 0, replaced = 0, notFound = 0, failed = 0, skipped = 0;
    await runBounded<RommMetadataFetchTarget>(targets, concurrency, (
      target,
    ) async {
      // Checked before each game, never mid-fetch: a game that has started
      // runs to completion and keeps its writes; the rest are skipped.
      // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
      if (_stopRequested) {
        skipped++;
        return;
      }
      final system = systemOf(target);
      RommMetadataOutcome outcome;
      try {
        outcome = await _fetchOne(target, system, mode);
      } catch (e) {
        outcome = RommMetadataOutcome.failed(e);
      }
      switch (outcome.kind) {
        case RommMetadataOutcomeKind.filled:
        case RommMetadataOutcomeKind.replaced:
        case RommMetadataOutcomeKind.partial:
          // A partial write left RomM data in the row, so it counts for
          // the mode it ran in; the media failure is already logged by
          // the writer with its URL.
          if (mode == RommMetadataMode.fillGaps) {
            filled++;
          } else {
            replaced++;
          }
        case RommMetadataOutcomeKind.notFound:
          notFound++;
        case RommMetadataOutcomeKind.failed:
          // Counted, named, and stepped over — never fatal to the games
          // still to come.
          // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
          failed++;
          _log.w(
            'RomM metadata fetch pass game failed '
            '(system=${system.folderName}, rom=${target.romId}, '
            'filename="${target.indexedName}"): ${outcome.error}',
          );
      }
      _done++;
      notifyListeners();
      _onProgress?.call(_done, _total);
    }, label: 'RomM metadata fetch pass');

    return RommMetadataFetchSummary(
      linked: targets.length,
      filled: filled,
      replaced: replaced,
      unlinkedSkipped: unlinked,
      notFound: notFound,
      failed: failed,
      cancelled: skipped > 0 || _stopRequested,
      elapsed: _clock().difference(started),
    );
  }

  /// The rom id of [game]'s map row, or null when it has none.
  ///
  /// The map is written under the on-disk filename but readable by either
  /// spelling, and under whichever folder the row was indexed in, so every
  /// combination is asked before a game is called unlinked. Public so the
  /// collection sync resolves its linked members the same way.
  static int? lookupRomId(
    RommRomIdIndex index,
    DatabaseGameModel game,
    SystemModel system,
  ) {
    final folders = <String>{
      if (game.systemFolderName case final folder? when folder.isNotEmpty)
        folder,
      system.folderName,
    };
    for (final folder in folders) {
      final byFilename = index.lookup(game.filename, folder);
      if (byFilename != null) return byFilename;
      final byRomname = index.lookup(game.romname, folder);
      if (byRomname != null) return byRomname;
    }
    return null;
  }

  /// The one info line per run. Per-game outcomes are deliberately absent:
  /// on a large system they would drown the log, and the counts are what a
  /// user reading it needs. Failed games each got a warning as they failed.
  /// [scope] names what ran: `system=<folder>` or the target run's label.
  ///
  /// Phrased `pass complete:` / `pass cancelled:` rather than `pass:` because
  /// the log redactor treats `pass:` as a credential key and blanks whatever
  /// follows it.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
  void _logSummary(
    String scope,
    RommMetadataMode mode,
    RommMetadataFetchSummary s,
  ) {
    _log.i(
      'RomM metadata fetch pass ${s.cancelled ? 'cancelled' : 'complete'}: '
      '$scope mode=${mode.name} '
      'linked=${s.linked} filled=${s.filled} replaced=${s.replaced} '
      'unlinked_skipped=${s.unlinkedSkipped} not_found=${s.notFound} '
      'failed=${s.failed} skipped=${s.skipped} cancelled=${s.cancelled} '
      'elapsed_ms=${s.elapsed.inMilliseconds}',
    );
  }
}
