import 'package:flutter/foundation.dart';

import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../models/romm_rom_page.dart';
import '../../models/system_model.dart';
import '../logger_service.dart';
import 'romm_paging.dart';

/// Lists the server's platforms (the ones with ROMs on them).
typedef RommPlatformLister = Future<List<RommPlatform>> Function();

/// Resolves a RomM platform to the local system its ROMs belong to, or null
/// when this build has no system for it.
typedef RommPlatformResolver =
    Future<SystemModel?> Function(RommPlatform platform);

/// One page of a platform's ROMs. Offset/limit paging only, like
/// `RommPageFetcher`; the platform is bound per call because the walk covers
/// several.
typedef RommPlatformPageFetcher =
    Future<RommRomPage> Function({
      required int platformId,
      required int limit,
      required int offset,
    });

/// Polled between platforms and between pages; true ends the walk.
typedef RommStopCheck = bool Function();

/// How one platform's paging ended.
enum RommWalkPlatformOutcome {
  /// Every page the server has was fetched.
  completed,

  /// A page request threw, or the page cap cut the paging short; either way
  /// the platform has not been fully seen.
  ///
  /// The cap counts as a failure on purpose. Consumers read `completed` as
  /// "this is the whole platform" and act destructively on it — the catalog
  /// refresh deletes every row the run did not stamp — so a truncated walk
  /// reported as complete prunes the catalog down to the cap and throws away
  /// ROMs that are still on the server.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  failed,

  /// The stop check fired before the platform finished.
  stopped,
}

/// The RomM platforms that resolve to one local system, walked together.
///
/// Grouping is by *local system*, not by platform: several RomM platforms can
/// resolve to one system through slug aliases, and consumers that decide
/// anything per system (the link pass's ambiguity check) need every platform
/// in the group before they act.
@immutable
class RommWalkGroup {
  final SystemModel system;
  final List<RommPlatform> platforms;

  const RommWalkGroup(this.system, this.platforms);
}

/// What one walk covered — the counts every consumer's summary line shares.
@immutable
class RommWalkResult {
  /// Platforms whose ROMs were paged to completion.
  final int platformsProcessed;

  /// Platforms with no local system, named in [unresolvedSlugs].
  final int platformsUnresolved;

  /// Platforms that threw part-way, or that the page cap cut short — either
  /// way not fully seen, and never treated as complete.
  final int platformFailures;

  /// Server ROMs handed to the consumers, across every page fetched.
  final int romsEnumerated;

  /// Slugs of the unresolved platforms — the signal that says which alias to
  /// add, so a summary names them rather than only counting.
  final List<String> unresolvedSlugs;

  /// True when the stop check ended the walk before every platform was seen.
  final bool stoppedEarly;

  const RommWalkResult({
    this.platformsProcessed = 0,
    this.platformsUnresolved = 0,
    this.platformFailures = 0,
    this.romsEnumerated = 0,
    this.unresolvedSlugs = const [],
    this.stoppedEarly = false,
  });
}

/// Called for every ROM on every page, in server order.
typedef RommWalkRomCallback =
    void Function(RommWalkGroup group, RommPlatform platform, RommRom rom);

/// Called once per fetched page, before its ROMs reach [RommWalkRomCallback].
/// Awaited, so a consumer that persists a page holds the walk until it has.
typedef RommWalkPageCallback =
    Future<void> Function(
      RommWalkGroup group,
      RommPlatform platform,
      List<RommRom> roms,
    );

/// Called when a platform's paging ends, with how it ended.
typedef RommWalkPlatformCallback =
    Future<void> Function(
      RommWalkGroup group,
      RommPlatform platform,
      RommWalkPlatformOutcome outcome,
    );

/// Called after every platform of a system group has been walked — unless the
/// walk stopped inside the group, which leaves it unfinished on purpose.
typedef RommWalkGroupCallback =
    Future<void> Function(RommWalkGroup group, {required bool groupFailed});

/// The one walk of a RomM server's ROM list, shared by every pass that needs
/// it.
///
/// Extracted from `RommLibraryLinker._pagePlatform` and its grouping loop so
/// the catalog refresh and the connect-time link pass cost *one* enumeration
/// between them: the refresh drives this walk and the link pass consumes the
/// same pages through the callbacks ([RommWalkRomCallback] and friends). Two
/// separate walks would double the server cost ADR-0001 bounded.
///
/// Never throws for a platform's sake — a failing platform is logged, counted
/// and stepped over — but a failure to list the platforms or to resolve one to
/// a system ends the walk, since nothing can be walked without them, and is
/// rethrown through [wrapFailure] so each caller surfaces its own exception
/// type with context.
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
class RommPlatformWalk {
  static final _defaultLog = LoggerService.instance;

  /// Rows per page — bulk sync's enumeration size, from the one definition
  /// every walk reads ([RommPaging]) so they all cost the same.
  static const int pageSize = RommPaging.pageSize;

  /// Hard stop on the paging loop per platform, in pages. See
  /// [RommPaging.maxPages] for why.
  static const int pageCap = RommPaging.maxPages;

  final RommPlatformLister _listPlatforms;
  final RommPlatformResolver _resolveSystem;
  final RommPlatformPageFetcher _fetchPage;
  final RommStopCheck _shouldStop;
  final LoggerService _log;

  /// How this walk names itself in the log — "RomM link pass",
  /// "RomM catalog refresh". One walk, two callers, two voices.
  final String logLabel;

  /// Wraps a fatal input failure (platform listing, system resolution) in the
  /// caller's own exception type.
  final Object Function(String context, Object cause) _wrapFailure;

  RommPlatformWalk({
    required RommPlatformLister listPlatforms,
    required RommPlatformResolver resolveSystem,
    required RommPlatformPageFetcher fetchPage,
    required this.logLabel,
    required Object Function(String context, Object cause) wrapFailure,
    RommStopCheck? shouldStop,
    LoggerService? logger,
  }) : _listPlatforms = listPlatforms,
       _resolveSystem = resolveSystem,
       _fetchPage = fetchPage,
       _wrapFailure = wrapFailure,
       _shouldStop = shouldStop ?? _neverStop,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// Groups the server's platforms by local system and pages each one,
  /// handing every page and every ROM to the callbacks that were supplied.
  Future<RommWalkResult> run({
    RommWalkRomCallback? onRom,
    RommWalkPageCallback? onPage,
    RommWalkPlatformCallback? onPlatformComplete,
    RommWalkGroupCallback? onGroupComplete,
  }) async {
    final List<RommPlatform> platforms;
    try {
      platforms = await _listPlatforms();
    } catch (e) {
      throw _wrapFailure('platform enumeration failed', e);
    }

    // Group platforms by the local system they resolve to, in server order.
    final groups = <String, List<RommPlatform>>{};
    final systems = <String, SystemModel>{};
    final unresolvedSlugs = <String>[];
    for (final platform in platforms) {
      final SystemModel? resolved;
      try {
        resolved = await _resolveSystem(platform);
      } catch (e) {
        throw _wrapFailure('platform resolution failed', e);
      }
      if (resolved == null) {
        unresolvedSlugs.add(platform.slug);
        continue;
      }
      final system = resolved;
      systems.putIfAbsent(system.folderName, () => system);
      groups.putIfAbsent(system.folderName, () => []).add(platform);
    }

    var processed = 0, failures = 0, enumerated = 0;
    var stopped = false;

    for (final entry in groups.entries) {
      if (_shouldStop()) {
        stopped = true;
        break;
      }
      final group = RommWalkGroup(systems[entry.key]!, entry.value);
      var groupFailed = false;

      for (final platform in group.platforms) {
        if (_shouldStop()) {
          stopped = true;
          break;
        }
        final outcome = await _pagePlatform(
          group,
          platform,
          onRom: onRom,
          onPage: onPage,
          countRom: () => enumerated++,
        );
        switch (outcome) {
          case RommWalkPlatformOutcome.completed:
            processed++;
          case RommWalkPlatformOutcome.failed:
            failures++;
            groupFailed = true;
          case RommWalkPlatformOutcome.stopped:
            stopped = true;
        }
        await onPlatformComplete?.call(group, platform, outcome);
        if (stopped) break;
      }
      // A stop mid-group leaves the group unfinished: a consumer that decides
      // per system (the link pass) needs every platform in it, and the
      // contract is "nothing further".
      if (stopped) break;
      await onGroupComplete?.call(group, groupFailed: groupFailed);
    }

    return RommWalkResult(
      platformsProcessed: processed,
      platformsUnresolved: unresolvedSlugs.length,
      platformFailures: failures,
      romsEnumerated: enumerated,
      unresolvedSlugs: unresolvedSlugs,
      stoppedEarly: stopped,
    );
  }

  /// Pages one platform to completion, handing every page and every ROM to
  /// the callbacks.
  ///
  /// Same loop shape as bulk sync's enumeration: a short page ends the
  /// results, an empty one guards a server that ignores the offset, and the
  /// page cap guards one that never stops. The stop check runs before every
  /// request so a dispose or disconnect ends the walk before the next round
  /// trip.
  Future<RommWalkPlatformOutcome> _pagePlatform(
    RommWalkGroup group,
    RommPlatform platform, {
    required RommWalkRomCallback? onRom,
    required RommWalkPageCallback? onPage,
    required void Function() countRom,
  }) async {
    var offset = 0;
    var total = 0;
    for (var page = 0; page < pageCap; page++) {
      if (_shouldStop()) return RommWalkPlatformOutcome.stopped;

      final RommRomPage result;
      try {
        result = await _fetchPage(
          platformId: platform.id,
          limit: pageSize,
          offset: offset,
        );
      } catch (e) {
        // Named, counted and stepped over — never swallowed, never fatal to
        // the platforms still to come.
        // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Error Handling Standards"
        // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Error Handling Standards"
        _log.w(
          '$logLabel platform "${platform.slug}" (id ${platform.id}) '
          'failed at offset $offset, skipping it: $e',
        );
        return RommWalkPlatformOutcome.failed;
      }

      if (result.total > 0) total = result.total;
      await onPage?.call(group, platform, result.items);
      for (final rom in result.items) {
        countRom();
        onRom?.call(group, platform, rom);
      }

      offset += result.items.length;
      if (result.items.length < pageSize) {
        return RommWalkPlatformOutcome.completed;
      }
      if (total > 0 && offset >= total) {
        return RommWalkPlatformOutcome.completed;
      }
    }
    // Everything paged so far is kept — the pages already handed to the
    // callbacks are good data — but the platform is *not* complete, and
    // saying otherwise would let a consumer treat the truncation as the whole
    // server: the catalog refresh would prune every row past the cap.
    // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
    _log.w(
      '$logLabel platform "${platform.slug}" (id ${platform.id}) hit the '
      '$pageCap-page cap at offset $offset; keeping what was seen and '
      'treating the platform as incomplete, so its rows are left alone',
    );
    return RommWalkPlatformOutcome.failed;
  }
}
