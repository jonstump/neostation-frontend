import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/romm_collection.dart';
import '../../models/romm_rom.dart';
import '../../models/romm_rom_page.dart';
import '../logger_service.dart';
import 'romm_paging.dart';

/// One page of the RomM collection's ROMs, the same walk bulk sync makes.
typedef RommCollectionPageFetcher =
    Future<RommRomPage> Function({required int limit, required int offset});

/// The local `rom_path` of a RomM ROM — the key a membership row needs — or
/// null when the ROM is neither on disk nor indexed yet. A throw is treated
/// as "unresolved" for that ROM and logged; it never ends the run.
typedef RommCollectionLocalResolver = Future<String?> Function(RommRom rom);

/// The local collection row mirroring `(serverUrl, collectionId)`, or null.
typedef RommMirrorFinder =
    Future<Map<String, Object?>?> Function(
      String serverUrl,
      String collectionId,
    );

/// Creates the local collection with its provenance (one transaction).
typedef RommMirrorInserter =
    Future<void> Function({
      required String id,
      required String name,
      required String serverUrl,
      required String collectionId,
      required bool virtual,
      required DateTime syncedAt,
    });

/// Sets a collection's membership to exactly the given paths (one
/// transaction) and reports how many rows were added and removed.
typedef RommMirrorMemberReplacer =
    Future<({int added, int removed})> Function(
      String collectionId,
      Set<String> romPaths,
    );

/// Refreshes a collection's provenance — in practice `romm_synced_at`.
typedef RommMirrorProvenanceSetter =
    Future<void> Function(
      String id, {
      required String serverUrl,
      required String collectionId,
      required bool virtual,
      required DateTime syncedAt,
    });

/// Polled between pages; true ends the run before the next page is fetched.
typedef RommMirrorStopCheck = bool Function();

/// What one run of [RommCollectionMirror] did — the counts the outcome
/// notification and the single summary log line report.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Mirror Service"
@immutable
class RommCollectionMirrorSummary {
  /// Id of the local collection that mirrors the RomM one, or null when the
  /// run ended before one was found or created.
  final String? collectionId;

  /// True when this run created the local collection.
  final bool created;

  /// Members added this run.
  final int added;

  /// Members removed this run because their ROM left the RomM collection
  /// (or was never in it — a hand-added game).
  final int removed;

  /// Members that were already there and still belong.
  final int kept;

  /// ROMs of the RomM collection with no local copy; counted, never added.
  final int unresolved;

  /// True when the stop check ended the run between pages. Membership was
  /// not written: nothing changed locally.
  final bool cancelled;

  /// True when a page fetch or a repository write failed. See [error].
  /// Membership was not written unless the failure came after the write.
  final bool failed;

  /// The failure behind [failed], or null.
  final Object? error;

  /// Wall-clock time of the run.
  final Duration elapsed;

  const RommCollectionMirrorSummary({
    this.collectionId,
    this.created = false,
    this.added = 0,
    this.removed = 0,
    this.kept = 0,
    this.unresolved = 0,
    this.cancelled = false,
    this.failed = false,
    this.error,
    this.elapsed = Duration.zero,
  });

  /// Members of the local collection after the run: what was added plus what
  /// was already there. 0 when nothing was written.
  int get members => added + kept;

  /// True when the run wrote membership.
  bool get wroteMembership => !cancelled && !failed && collectionId != null;
}

/// A page of the RomM collection could not be fetched. Carries the RomM
/// collection id and the 1-based page so the log line names both.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Error Handling Standards"
class RommCollectionMirrorPageException implements Exception {
  final String collectionId;
  final int page;
  final Object cause;

  const RommCollectionMirrorPageException({
    required this.collectionId,
    required this.page,
    required this.cause,
  });

  @override
  String toString() =>
      'collection mirror failed: RomM collection $collectionId page $page: '
      '$cause';
}

/// A repository write of the mirror (find, create, membership, provenance)
/// failed. [step] names which.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Error Handling Standards"
class RommCollectionMirrorWriteException implements Exception {
  final String collectionId;
  final String step;
  final Object cause;

  const RommCollectionMirrorWriteException({
    required this.collectionId,
    required this.step,
    required this.cause,
  });

  @override
  String toString() =>
      'collection mirror failed: RomM collection $collectionId $step: $cause';
}

/// A run asked for while another was active, waiting its turn.
class _QueuedRun {
  final RommCollectionMirror mirror;
  final RommCollection collection;
  final String serverUrl;
  final Completer<RommCollectionMirrorSummary> completer =
      Completer<RommCollectionMirrorSummary>();

  _QueuedRun(this.mirror, this.collection, this.serverUrl);
}

/// Mirrors one RomM collection into a local collection.
///
/// [run] pages the RomM collection's ROMs, resolves each to a local
/// `rom_path` through the injected resolver, then finds the local collection
/// by `(server URL, RomM collection id)` — creating one named after the RomM
/// collection when none exists — and sets its membership to exactly the
/// resolved paths. Name, artwork, colours and sort order of an existing
/// collection are never touched, so a rename sticks. ROMs that resolve to
/// nothing are counted as unresolved and left out.
///
/// **Membership is written once, at the end.** A run that is cancelled
/// between pages or whose page fetch fails writes nothing: the previous
/// membership stays exactly as it was, and the summary says so. This is a
/// deliberate narrowing of SPEC-0009's "keeps the membership written so far":
/// there is never a "so far" to keep, because a partial page walk cannot
/// tell which absent members left the RomM collection and which were simply
/// not paged yet — removing them on a guess would look like data loss.
///
/// Dependencies are injected in the style of `RommMetadataFetch` so the
/// algorithm runs against in-memory fakes and stays free of providers and
/// datasources; the provider wires the real `RommService` page fetch, its
/// local-copy probe, and `CollectionRepository`.
///
/// One run at a time, process-wide. A [run] that arrives while another is
/// active is **queued** — at most one pending run per RomM collection id, a
/// later request for the same id joining the pending one — and starts when
/// the active run finishes; its summary is delivered through the future the
/// caller already holds. The settle-triggered re-run after a sync is what
/// this exists for: it must follow the post-sync run, never overlap it, and
/// never be dropped.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Mirror Service"
class RommCollectionMirror {
  static final _defaultLog = LoggerService.instance;

  /// Rows per page — [RommPaging.pageSize], the same walk bulk sync makes.
  static const int pageSize = RommPaging.pageSize;

  /// Hard stop on the page loop — [RommPaging.maxPages].
  static const int maxPages = RommPaging.maxPages;

  /// The run in progress, or null.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Concurrency Safety"
  static RommCollectionMirror? _active;

  /// Runs waiting for [_active] to finish, keyed by RomM collection id and in
  /// arrival order.
  static final Map<String, _QueuedRun> _queued = <String, _QueuedRun>{};

  /// True while a run is in progress.
  static bool get isActive => _active != null;

  /// RomM collection ids with a run waiting its turn.
  static List<String> get queuedCollectionIds =>
      List.unmodifiable(_queued.keys);

  /// Drops the active run and the queue. Only for tests whose run was left
  /// unfinished by an assertion failure; a finished run clears itself.
  @visibleForTesting
  static void resetForTesting() {
    _active = null;
    _queued.clear();
  }

  final RommCollectionPageFetcher _fetchPage;
  final RommCollectionLocalResolver _resolveLocal;
  final RommMirrorFinder _findMirror;
  final RommMirrorInserter _insertMirror;
  final RommMirrorMemberReplacer _replaceMembers;
  final RommMirrorProvenanceSetter _setProvenance;
  final RommMirrorStopCheck _shouldStop;
  final String Function() _newId;
  final DateTime Function() _clock;
  final LoggerService _log;

  RommCollectionMirror({
    required RommCollectionPageFetcher fetchPage,
    required RommCollectionLocalResolver resolveLocal,
    required RommMirrorFinder findMirror,
    required RommMirrorInserter insertMirror,
    required RommMirrorMemberReplacer replaceMembers,
    required RommMirrorProvenanceSetter setProvenance,
    required String Function() newId,
    RommMirrorStopCheck? shouldStop,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _fetchPage = fetchPage,
       _resolveLocal = resolveLocal,
       _findMirror = findMirror,
       _insertMirror = insertMirror,
       _replaceMembers = replaceMembers,
       _setProvenance = setProvenance,
       _newId = newId,
       _shouldStop = shouldStop ?? _neverStop,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// Mirrors [collection] from the RomM server at [serverUrl] and returns
  /// what happened. Never throws: a failure is reported through
  /// [RommCollectionMirrorSummary.failed] / `error` and logged with the
  /// collection id (and page, for a fetch failure).
  ///
  /// While another run is active this one is queued rather than started —
  /// see the class doc — and the returned future completes with the queued
  /// run's summary once it has had its turn.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Concurrency Safety"
  Future<RommCollectionMirrorSummary> run(
    RommCollection collection, {
    required String serverUrl,
  }) {
    if (_active != null) {
      final pending = _queued[collection.id];
      if (pending != null) {
        _log.d(
          'RomM collection mirror already queued: collection=${collection.id} '
          'joining the pending run',
        );
        return pending.completer.future;
      }
      final queued = _QueuedRun(this, collection, serverUrl);
      _queued[collection.id] = queued;
      _log.d(
        'RomM collection mirror queued: collection=${collection.id} '
        'behind an active run',
      );
      return queued.completer.future;
    }
    return _runNow(collection, serverUrl);
  }

  Future<RommCollectionMirrorSummary> _runNow(
    RommCollection collection,
    String serverUrl,
  ) async {
    // Claimed before the first await so two starts in one event-loop turn
    // cannot both pass the check in [run].
    _active = this;
    final started = _clock();
    try {
      final summary = await _mirror(collection, serverUrl, started);
      _logSummary(collection, summary);
      return summary;
    } finally {
      _active = null;
      _startNextQueued();
    }
  }

  /// Starts the oldest queued run, if any. Called as each run finishes, so
  /// the queue drains one run at a time in arrival order.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Concurrency Safety"
  static void _startNextQueued() {
    if (_queued.isEmpty || _active != null) return;
    final next = _queued.remove(_queued.keys.first)!;
    next.completer.complete(
      next.mirror._runNow(next.collection, next.serverUrl),
    );
  }

  Future<RommCollectionMirrorSummary> _mirror(
    RommCollection collection,
    String serverUrl,
    DateTime started,
  ) async {
    Duration elapsed() => _clock().difference(started);

    // The existing mirror first, so a cancelled or failed run can still name
    // the collection it would have updated.
    final Map<String, Object?>? existing;
    try {
      existing = await _findMirror(serverUrl, collection.id);
    } catch (e) {
      final error = RommCollectionMirrorWriteException(
        collectionId: collection.id,
        step: 'lookup',
        cause: e,
      );
      _log.e(
        'RomM collection mirror lookup failed: collection=${collection.id} error=$e',
      );
      return RommCollectionMirrorSummary(
        failed: true,
        error: error,
        elapsed: elapsed(),
      );
    }
    final existingId = existing?['id']?.toString();

    // Page the whole RomM collection and resolve every ROM before touching
    // the database: membership is written once, from the complete set.
    final resolved = <String>{};
    var unresolved = 0;
    var offset = 0;
    for (var page = 1; page <= maxPages; page++) {
      // Between pages, never mid-page: a page that has started completes.
      // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Concurrency Safety"
      if (_shouldStop()) {
        return RommCollectionMirrorSummary(
          collectionId: existingId,
          unresolved: unresolved,
          cancelled: true,
          elapsed: elapsed(),
        );
      }
      final RommRomPage result;
      try {
        result = await _fetchPage(limit: pageSize, offset: offset);
      } catch (e) {
        // Stops the run with nothing written; the caller sees the page.
        // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Error Handling Standards"
        final error = RommCollectionMirrorPageException(
          collectionId: collection.id,
          page: page,
          cause: e,
        );
        _log.w(
          'RomM collection mirror page failed: collection=${collection.id} '
          'page=$page offset=$offset error=$e',
        );
        return RommCollectionMirrorSummary(
          collectionId: existingId,
          unresolved: unresolved,
          failed: true,
          error: error,
          elapsed: elapsed(),
        );
      }
      for (final rom in result.items) {
        String? path;
        try {
          path = await _resolveLocal(rom);
        } catch (e) {
          // One ROM's probe failing is that ROM unresolved, not the run.
          // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Error Handling Standards"
          _log.w(
            'RomM collection mirror resolve failed: '
            'collection=${collection.id} rom=${rom.id} error=$e',
          );
          path = null;
        }
        if (path == null || path.isEmpty) {
          unresolved++;
        } else {
          resolved.add(path);
        }
      }
      if (result.items.length < pageSize) break;
      offset += result.items.length;
    }

    // Find-or-create, then the one membership write, then the sync time.
    final syncedAt = _clock();
    final String localId;
    final created = existingId == null;
    try {
      if (existingId != null) {
        localId = existingId;
      } else {
        localId = _newId();
        await _insertMirror(
          id: localId,
          name: collection.name,
          serverUrl: serverUrl,
          collectionId: collection.id,
          virtual: collection.isVirtual,
          syncedAt: syncedAt,
        );
      }
    } catch (e) {
      final error = RommCollectionMirrorWriteException(
        collectionId: collection.id,
        step: 'create',
        cause: e,
      );
      _log.e(
        'RomM collection mirror create failed: collection=${collection.id} error=$e',
      );
      return RommCollectionMirrorSummary(
        unresolved: unresolved,
        failed: true,
        error: error,
        elapsed: elapsed(),
      );
    }

    final ({int added, int removed}) change;
    try {
      change = await _replaceMembers(localId, resolved);
    } catch (e) {
      final error = RommCollectionMirrorWriteException(
        collectionId: collection.id,
        step: 'membership',
        cause: e,
      );
      _log.e(
        'RomM collection mirror membership write failed: '
        'collection=${collection.id} local=$localId error=$e',
      );
      return RommCollectionMirrorSummary(
        collectionId: localId,
        created: created,
        unresolved: unresolved,
        failed: true,
        error: error,
        elapsed: elapsed(),
      );
    }

    if (!created) {
      try {
        await _setProvenance(
          localId,
          serverUrl: serverUrl,
          collectionId: collection.id,
          virtual: collection.isVirtual,
          syncedAt: syncedAt,
        );
      } catch (e) {
        // Membership is in; only the timestamp is stale. Logged, and the
        // summary still counts what was written.
        // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Error Handling Standards"
        _log.w(
          'RomM collection mirror provenance refresh failed: '
          'collection=${collection.id} local=$localId error=$e',
        );
      }
    }

    return RommCollectionMirrorSummary(
      collectionId: localId,
      created: created,
      added: change.added,
      removed: change.removed,
      kept: resolved.length - change.added,
      unresolved: unresolved,
      elapsed: elapsed(),
    );
  }

  /// The one info line per run. Per-ROM outcomes are deliberately absent —
  /// a virtual collection can hold thousands — and a failed page or write
  /// already got its own warning or error line with the page and cause.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Mirror Service"
  void _logSummary(RommCollection collection, RommCollectionMirrorSummary s) {
    final outcome = s.failed
        ? 'failed'
        : s.cancelled
        ? 'cancelled'
        : 'complete';
    _log.i(
      'RomM collection mirror $outcome: collection=${collection.id} '
      'virtual=${collection.isVirtual} local=${s.collectionId ?? '-'} '
      'created=${s.created} added=${s.added} removed=${s.removed} '
      'kept=${s.kept} unresolved=${s.unresolved} cancelled=${s.cancelled} '
      'failed=${s.failed} elapsed_ms=${s.elapsed.inMilliseconds}',
    );
  }
}
