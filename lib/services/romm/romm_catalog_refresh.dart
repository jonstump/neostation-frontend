import 'package:flutter/foundation.dart';

import '../../models/romm_catalog_row.dart';
import '../../repositories/romm_catalog_repository.dart';
import '../logger_service.dart';
import 'romm_library_linker.dart';
import 'romm_platform_walk.dart';

/// Why a refresh was asked for. Only [manual] and [reconnect] bypass the
/// hourly guard: the user asked, or the server just came back and whatever is
/// stored is known to be stale.
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
enum RommRefreshReason {
  /// The connect-time sweep.
  connect,

  /// The user pressed "Refresh RomM library now".
  manual,

  /// Reachability went from offline back to online.
  reconnect,

  /// Any other automatic trigger.
  scheduled;

  /// Whether this reason runs even when the catalog was refreshed within the
  /// hour.
  bool get bypassesGuard =>
      this == RommRefreshReason.manual || this == RommRefreshReason.reconnect;
}

/// Why a refresh did nothing.
enum RommRefreshSkip {
  /// A refresh is already in flight.
  alreadyRunning,

  /// No server is configured.
  noServer,

  /// The catalog was refreshed less than [RommCatalogRefresh.minInterval] ago
  /// and the reason does not bypass the guard.
  tooSoon,
}

/// Writes a batch of catalog rows; returns how many were written.
typedef RommCatalogUpsert = Future<int> Function(List<RommCatalogRow> rows);

/// Deletes a completed platform's rows that this run did not stamp.
typedef RommCatalogPruner =
    Future<int> Function({
      required String serverUrl,
      required int platformId,
      required DateTime before,
    });

/// Records a platform the walk completed.
typedef RommCatalogPlatformRecorder =
    Future<bool> Function({
      required String serverUrl,
      required int platformId,
      required String systemFolder,
      required String name,
      required int romCount,
      DateTime? refreshedAt,
    });

/// When this server's catalog was last refreshed, for the hourly guard.
typedef RommCatalogStampReader = Future<DateTime?> Function(String serverUrl);

/// What one run of [RommCatalogRefresh] did.
@immutable
class RommCatalogRefreshSummary {
  /// Set when the run did nothing, saying why.
  final RommRefreshSkip? skipped;

  /// Platforms paged to completion.
  final int platformsProcessed;

  /// Platforms whose paging failed. Their rows are left exactly as they were.
  final int platformsFailed;

  /// Platforms with no local system — they stay in the RomM tab.
  final int platformsUnresolved;

  /// Catalog rows written (inserted or updated).
  final int rowsUpserted;

  /// Rows deleted because a completed platform no longer holds them.
  final int rowsDeleted;

  /// True when the stop signal ended the run early.
  final bool stoppedEarly;

  /// Wall-clock time of the run.
  final Duration elapsed;

  /// What the link stage did, when one rode along.
  final RommLinkPassSummary? linkSummary;

  const RommCatalogRefreshSummary({
    this.skipped,
    this.platformsProcessed = 0,
    this.platformsFailed = 0,
    this.platformsUnresolved = 0,
    this.rowsUpserted = 0,
    this.rowsDeleted = 0,
    this.stoppedEarly = false,
    this.elapsed = Duration.zero,
    this.linkSummary,
  });

  /// True when the run walked the server rather than being skipped.
  bool get ran => skipped == null;
}

/// Why [RommCatalogRefresh.run] could not run at all — the platform list or a
/// platform's system resolution was unreadable. Per-platform paging failures
/// are counted, not thrown.
class RommCatalogRefreshException implements Exception {
  final String context;
  final Object cause;

  const RommCatalogRefreshException(this.context, this.cause);

  @override
  String toString() => 'RomM catalog refresh failed: $context: $cause';
}

/// Rebuilds the persisted RomM catalog from the server, and carries the
/// connect-time link pass along for the ride.
///
/// This owns the walk: it groups the server's platforms by the local system
/// they resolve to, pages each one through [RommPlatformWalk], upserts a
/// catalog row per ROM, and — because the link pass wants exactly the same
/// pages — hands every ROM to a [RommLinkStage] as it goes. One enumeration
/// serves both, which is the cost model ADR-0001 set for the link pass and
/// ADR-0020 inherited for the catalog.
///
/// Deletion is per completed platform: once a platform has been paged to the
/// end, its rows that this run did not stamp are gone from the server and are
/// removed. A platform whose paging failed is counted and left completely
/// alone — a partial view must never delete ROMs that are still there.
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
class RommCatalogRefresh {
  static final _defaultLog = LoggerService.instance;

  /// How this refresh names itself in the log.
  static const String logLabel = 'RomM catalog refresh';

  /// Shortest gap between two automatic refreshes. A reconnect or a manual
  /// refresh ignores it; everything else waits, because a full walk of a large
  /// library is the most expensive thing this app asks of a RomM server.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  static const Duration minInterval = Duration(hours: 1);

  final RommPlatformLister _listPlatforms;
  final RommPlatformResolver _resolveSystem;
  final RommPlatformPageFetcher _fetchPage;
  final RommStopCheck _shouldStop;
  final String Function() _serverUrl;
  final RommCatalogUpsert _upsert;
  final RommCatalogPruner _deleteUnseen;
  final RommCatalogPlatformRecorder _recordPlatform;
  final RommCatalogStampReader _newestRefreshedAt;
  final RommLibraryLinker? _linker;
  final DateTime Function() _clock;
  final LoggerService _log;

  bool _running = false;

  RommCatalogRefresh({
    required RommPlatformLister listPlatforms,
    required RommPlatformResolver resolveSystem,
    required RommPlatformPageFetcher fetchPage,
    required String Function() serverUrl,
    RommLibraryLinker? linker,
    RommStopCheck? shouldStop,
    RommCatalogUpsert? upsert,
    RommCatalogPruner? deleteUnseen,
    RommCatalogPlatformRecorder? recordPlatform,
    RommCatalogStampReader? newestRefreshedAt,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _listPlatforms = listPlatforms,
       _resolveSystem = resolveSystem,
       _fetchPage = fetchPage,
       _serverUrl = serverUrl,
       _linker = linker,
       _shouldStop = shouldStop ?? _neverStop,
       _upsert = upsert ?? RommCatalogRepository.upsertRows,
       _deleteUnseen = deleteUnseen ?? RommCatalogRepository.deleteUnseen,
       _recordPlatform = recordPlatform ?? RommCatalogRepository.recordPlatform,
       _newestRefreshedAt =
           newestRefreshedAt ?? RommCatalogRepository.newestRefreshedAt,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// True while a refresh is in progress.
  bool get isRunning => _running;

  /// Walks the server once, refreshing the catalog and driving the link stage.
  ///
  /// Never throws for a platform's sake. A failure to list the platforms or to
  /// resolve one to a system ends the run with a
  /// [RommCatalogRefreshException]; the caller logs it and reads it as
  /// "nothing refreshed", exactly as the link pass's scheduler does.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  Future<RommCatalogRefreshSummary> run({
    RommRefreshReason reason = RommRefreshReason.scheduled,
  }) async {
    if (_running) {
      _log.i('$logLabel skipped: a refresh is already running');
      return const RommCatalogRefreshSummary(
        skipped: RommRefreshSkip.alreadyRunning,
      );
    }
    final serverUrl = _serverUrl();
    if (serverUrl.isEmpty) {
      _log.i('$logLabel skipped: reason=${reason.name} cause=no_server');
      return const RommCatalogRefreshSummary(skipped: RommRefreshSkip.noServer);
    }

    final started = _clock();
    if (!reason.bypassesGuard) {
      final newest = await _newestRefreshedAt(serverUrl);
      if (newest != null &&
          started.toUtc().difference(newest) < minInterval &&
          !started.toUtc().isBefore(newest)) {
        _log.i(
          '$logLabel skipped: reason=${reason.name} cause=too_soon '
          'last_refresh=${newest.toIso8601String()} '
          'min_interval_minutes=${minInterval.inMinutes}',
        );
        return const RommCatalogRefreshSummary(
          skipped: RommRefreshSkip.tooSoon,
        );
      }
    }

    _running = true;
    try {
      return await _run(reason: reason, serverUrl: serverUrl, started: started);
    } finally {
      _running = false;
    }
  }

  Future<RommCatalogRefreshSummary> _run({
    required RommRefreshReason reason,
    required String serverUrl,
    required DateTime started,
  }) async {
    // The link pass rides along on this walk. A stage it refuses to open —
    // nothing unlinked, or a pass already in flight — only means no link work
    // this time; the catalog still has to be refreshed, which is exactly the
    // early exit that used to skip the walk altogether.
    // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
    RommLinkStage? stage;
    try {
      stage = await _linker?.beginStage();
    } on RommLinkPassException catch (e) {
      // The link stage needs the local library; the catalog does not. Log it
      // once and walk anyway.
      // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Error Handling Standards"
      _log.w('$logLabel: the link stage could not start: $e');
    }

    var rowsUpserted = 0;
    var rowsDeleted = 0;
    final romsByPlatform = <int, int>{};

    final walk = RommPlatformWalk(
      listPlatforms: _listPlatforms,
      resolveSystem: _resolveSystem,
      fetchPage: _fetchPage,
      shouldStop: _shouldStop,
      logger: _log,
      logLabel: logLabel,
      wrapFailure: RommCatalogRefreshException.new,
    );

    final RommWalkResult result;
    try {
      result = await walk.run(
        // One page, both consumers: the rows are persisted here and the same
        // ROMs reach the link stage through onRom below.
        // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
        onPage: (group, platform, roms) async {
          if (roms.isEmpty) return;
          final rows = [
            for (final rom in roms)
              RommCatalogRow.fromRom(
                rom,
                serverUrl: serverUrl,
                systemFolder: group.system.folderName,
                seenAt: started,
              ),
          ];
          rowsUpserted += await _upsert(rows);
          romsByPlatform[platform.id] =
              (romsByPlatform[platform.id] ?? 0) + roms.length;
        },
        onRom: stage?.onRom,
        onPlatformComplete: (group, platform, outcome) async {
          await stage?.onPlatformComplete(group, platform, outcome);
          if (outcome != RommWalkPlatformOutcome.completed) {
            // A platform that failed or was cut short has not been fully
            // seen: its rows and its previous stamp stay untouched.
            // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Error Handling Standards"
            return;
          }
          rowsDeleted += await _deleteUnseen(
            serverUrl: serverUrl,
            platformId: platform.id,
            before: started,
          );
          await _recordPlatform(
            serverUrl: serverUrl,
            platformId: platform.id,
            systemFolder: group.system.folderName,
            name: platform.name,
            romCount: romsByPlatform[platform.id] ?? 0,
            refreshedAt: _clock(),
          );
        },
        onGroupComplete: stage == null
            ? null
            : (group, {required groupFailed}) =>
                  stage!.onGroupComplete(group, groupFailed: groupFailed),
      );
    } catch (_) {
      stage?.abandon();
      rethrow;
    }

    final linkSummary = stage?.finish(result);
    final summary = RommCatalogRefreshSummary(
      platformsProcessed: result.platformsProcessed,
      platformsFailed: result.platformFailures,
      platformsUnresolved: result.platformsUnresolved,
      rowsUpserted: rowsUpserted,
      rowsDeleted: rowsDeleted,
      stoppedEarly: result.stoppedEarly,
      elapsed: _clock().difference(started),
      linkSummary: linkSummary,
    );
    _logSummary(summary, reason: reason);
    return summary;
  }

  /// The one info line per run, in key=value form.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Error Handling Standards"
  void _logSummary(
    RommCatalogRefreshSummary s, {
    required RommRefreshReason reason,
  }) {
    _log.i(
      '$logLabel ${s.stoppedEarly ? 'stopped early' : 'complete'}: '
      'reason=${reason.name} '
      'platforms=${s.platformsProcessed} '
      'unresolved=${s.platformsUnresolved} '
      'failed=${s.platformsFailed} '
      'rows_upserted=${s.rowsUpserted} '
      'rows_deleted=${s.rowsDeleted} '
      'elapsed_ms=${s.elapsed.inMilliseconds}',
    );
  }
}
