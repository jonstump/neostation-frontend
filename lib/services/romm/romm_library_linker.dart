import 'package:flutter/foundation.dart';

import '../../models/database_game_model.dart';
import '../../models/rom_fingerprint.dart';
import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../models/system_model.dart';
import '../../repositories/game_repository.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../utils/romm_local_matcher.dart';
import '../logger_service.dart';
import '../rom_fingerprint_service.dart';
import 'romm_paging.dart';
import 'romm_platform_walk.dart';

/// The server-facing halves of the pass now belong to the shared walk
/// ([RommPlatformWalk]) — re-exported here so every existing caller keeps one
/// import.
export 'romm_platform_walk.dart'
    show
        RommPlatformLister,
        RommPlatformPageFetcher,
        RommPlatformResolver,
        RommStopCheck;

/// The local library index — the scanned games table, never the disk.
typedef RommLocalLibraryLister = Future<List<DatabaseGameModel>> Function();

/// Every mapping already recorded, so linked games can be skipped up front.
typedef RommRomIdIndexLoader = Future<RommRomIdIndex> Function();

/// Insert-if-absent for a batch of links; returns the rows actually written.
typedef RommMappingWriter =
    Future<int> Function(List<RommSaveMapEntry> entries);

/// The cheap fingerprint of one local file — a zip's stored crc32 and
/// uncompressed size, read from its central directory off the UI isolate —
/// or the reason there is none (`RomFingerprintService.deferredCostly` for a
/// file that would have to be read in full, a skip reason for one that can
/// never be fingerprinted). The packed-archive policy of the system is the
/// caller's to resolve; the pass only hands over the path and the folder.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
typedef RommCheapFingerprinter =
    Future<({RomFingerprint? fingerprint, String? skipReason})> Function(
      String romPath,
      String? systemFolder,
    );

/// Persists a batch of fingerprint outcomes (results and skip reasons) in
/// one transaction, so a later pass pays nothing for those games.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Database Operation Standards"
typedef RommFingerprintSaver =
    Future<int> Function(List<RomFingerprintWrite> writes);

/// A local file the pass refused to link because more than one RomM ROM
/// claimed it.
@immutable
class RommLinkAmbiguity {
  /// The on-disk filename, as indexed.
  final String filename;

  /// The system folder the file was indexed under.
  final String systemFolder;

  /// Every distinct RomM ROM id whose candidate names matched the file.
  final List<int> romIds;

  const RommLinkAmbiguity({
    required this.filename,
    required this.systemFolder,
    required this.romIds,
  });

  @override
  String toString() => '$systemFolder/$filename (${romIds.join(', ')})';
}

/// A local file whose existing mapping row points at a different RomM ROM
/// than the one the pass matched it to.
///
/// The row is left exactly as it was — rows are never overwritten — but the
/// disagreement is worth a line: it is either a server whose ids changed
/// (a re-scan, a migration), two ROMs on one system sharing a filename, or a
/// link the user picked by hand ([existingSource] is manual), and either way
/// the user's saves are following the id in the row.
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
@immutable
class RommLinkConflict {
  /// The on-disk filename, as indexed.
  final String filename;

  /// The system folder the file was indexed under.
  final String systemFolder;

  /// The RomM ROM id the existing row points at.
  final int existingRomId;

  /// Who wrote the existing row. A manual row is the user's choice and is
  /// reported so the log explains why the pass did not follow the filename.
  final RommLinkSource existingSource;

  /// The RomM ROM id this pass matched the file to.
  final int matchedRomId;

  const RommLinkConflict({
    required this.filename,
    required this.systemFolder,
    required this.existingRomId,
    required this.existingSource,
    required this.matchedRomId,
  });

  @override
  String toString() =>
      '$systemFolder/$filename (row $existingRomId ${existingSource.dbValue}, '
      'matched $matchedRomId)';
}

/// What one run of [RommLibraryLinker] did.
///
/// Everything the single summary log line reports, kept as a value so the
/// sync provider can act on it (invalidate the linked games' cached state)
/// and tests can assert on counts instead of parsing log text.
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Pass Observability"
@immutable
class RommLinkPassSummary {
  /// Platforms whose ROMs were paged to completion.
  final int platformsProcessed;

  /// Platforms with no local system, listed by slug in [unresolvedSlugs].
  final int platformsUnresolved;

  /// Platforms that threw part-way and contributed nothing (see
  /// [RommLibraryLinker] on why their partial matches are discarded).
  final int platformFailures;

  /// Multi-platform system groups written nothing because one of their
  /// platforms failed: the surviving platforms' matches could not be checked
  /// for ambiguity against the failed one, so none were written.
  final int groupsSkipped;

  /// Server ROMs looked at across every page fetched.
  final int romsEnumerated;

  /// Mapping rows this run wrote.
  final int rowsAdded;

  /// Matches that already had a row: games the rom-id index said were linked
  /// before the pass, plus the (rare) insert the table itself ignored because
  /// a download finished between the index read and the write.
  final int rowsAlreadyPresent;

  /// Local files skipped because more than one ROM matched them.
  final List<RommLinkAmbiguity> ambiguities;

  /// Of [rowsAlreadyPresent], the files whose row points at a ROM other than
  /// the one this pass matched. Counted there too — the row *is* present and
  /// was left alone — and named here so the disagreement is visible.
  final List<RommLinkConflict> conflicts;

  /// Slugs of the unresolved platforms — the signal that says which alias to
  /// add, so the summary names them rather than only counting.
  final List<String> unresolvedSlugs;

  /// True when the stop check ended the pass before every platform was seen.
  final bool stoppedEarly;

  /// Wall-clock time of the run.
  final Duration elapsed;

  /// Extension-stripped names (`DatabaseGameModel.romname`, the key the sync
  /// provider caches state under) of the games this run linked.
  final List<String> linkedRomnames;

  /// Mapping rows the hash stage wrote — counted apart from [rowsAdded],
  /// which is the filename stage's count, so the line says which stage did
  /// the work.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  final int hashRowsAdded;

  /// Cheap fingerprints this run computed and persisted.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  final int fingerprintsComputed;

  /// Files parked with a skip reason this run: persisted, never
  /// re-attempted by a later pass.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  final int fingerprintsSkipped;

  /// Files whose cheap fingerprint would have cost a full read — a bare ROM,
  /// an arcade set — so nothing was read for them. Not parked (nothing is
  /// wrong with them), not persisted and not charged to the cap, so a
  /// bare-ROM library reports the same count on every pass; kept apart from
  /// [fingerprintsSkipped] so that line does not read as N files parked.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  final int fingerprintsDeferred;

  /// Unlinked games still without a fingerprint when the per-pass cap (or the
  /// stop signal) ended the fingerprint step; the next pass picks them up.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  final int fingerprintsRemaining;

  /// Local games whose crc32 matched a server ROM that its md5 or size then
  /// ruled out — a crc32 collision, or two dumps that differ past the
  /// checksum — so nothing was linked for them.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  final int hashMismatches;

  const RommLinkPassSummary({
    this.platformsProcessed = 0,
    this.platformsUnresolved = 0,
    this.platformFailures = 0,
    this.groupsSkipped = 0,
    this.romsEnumerated = 0,
    this.rowsAdded = 0,
    this.rowsAlreadyPresent = 0,
    this.ambiguities = const [],
    this.conflicts = const [],
    this.unresolvedSlugs = const [],
    this.stoppedEarly = false,
    this.elapsed = Duration.zero,
    this.linkedRomnames = const [],
    this.hashRowsAdded = 0,
    this.fingerprintsComputed = 0,
    this.fingerprintsSkipped = 0,
    this.fingerprintsDeferred = 0,
    this.fingerprintsRemaining = 0,
    this.hashMismatches = 0,
  });

  int get ambiguousSkipped => ambiguities.length;

  int get conflictCount => conflicts.length;
}

/// The connect-time pass that links a pre-existing local library to the RomM
/// server by filename.
///
/// Every RomM feature for a game hangs off one `app_romm_rom_map` row, and
/// until this pass the only writer was the download path, so a library copied
/// from the server over USB stayed permanently unlinked. This walks every
/// platform the server has, applies the shared [RommLocalMatcher] rule against
/// the *scanned library index* — never the filesystem, so a multi-thousand
/// game Android library costs no SAF reads — and writes the missing rows.
///
/// Dependencies are injected in the style of `RommBulkSync.run` so the
/// algorithm is testable with in-memory fakes and stays out of the sync
/// provider, which only owns its schedule and guards. The pass is idempotent:
/// it writes through insert-if-absent, never overwrites, and a second run over
/// the same server adds nothing.
///
/// Matching is grouped by *local system*, not by platform: several RomM
/// platforms can resolve to one system (slug aliases), and a file that two of
/// them both claim is ambiguous. Rows are therefore written once per system
/// group, after every platform in it has been paged, so the ambiguity check
/// sees the whole picture before anything is committed.
///
/// Games the filename stage leaves unlinked get a second chance by content
/// hash (ADR-0011): the same pages carry RomM's crc32/md5 per ROM and per
/// file, the local index carries the fingerprints ScreenScraper persisted,
/// and the pass tops those up with the cheap zip crc32 — capped per pass and
/// persisted — before matching in memory. No extra request is ever made for
/// it; see [RommLinkStage.onGroupComplete].
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
class RommLibraryLinker {
  static final _defaultLog = LoggerService.instance;

  /// Most cheap fingerprints one pass computes. A first connect on a large
  /// unscraped zipped library reads that many zip tails and no more; the
  /// results are persisted, so the next pass carries on from where this one
  /// stopped and a fully fingerprinted library costs nothing.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  static const int fingerprintCapPerPass = 500;

  /// Rows per page — bulk sync's enumeration size, from the one definition
  /// every walk reads ([RommPaging]) so they cost the same.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
  static const int pageSize = RommPaging.pageSize;

  /// Hard stop on the paging loop per platform, in pages — bulk sync's cap,
  /// from the same definition. See [RommPaging.maxPages] for why.
  static const int pageCap = RommPaging.maxPages;

  /// Most ambiguities named in the summary line; the rest are counted.
  static const int _ambiguityLogLimit = 20;

  /// Most conflicts given their own warning; the rest are counted.
  static const int _conflictLogLimit = 20;

  /// How this pass names itself in the log.
  static const String logLabel = 'RomM link pass';

  final RommPlatformLister _listPlatforms;
  final RommPlatformResolver _resolveSystem;
  final RommPlatformPageFetcher _fetchPage;
  final RommLocalLibraryLister _listGames;
  final RommRomIdIndexLoader _loadRomIdIndex;
  final RommMappingWriter _putMappingsIfAbsent;
  final RommCheapFingerprinter? _fingerprintCheap;
  final RommFingerprintSaver? _saveFingerprints;
  final RommStopCheck _shouldStop;
  final DateTime Function() _clock;
  final LoggerService _log;

  bool _running = false;

  /// [fingerprintCheap] and [saveFingerprints] are the fingerprint step's two
  /// halves; without both the step is skipped and the hash stage matches on
  /// the fingerprints the library already holds.
  RommLibraryLinker({
    required RommPlatformLister listPlatforms,
    required RommPlatformResolver resolveSystem,
    required RommPlatformPageFetcher fetchPage,
    required RommLocalLibraryLister listGames,
    required RommRomIdIndexLoader loadRomIdIndex,
    required RommMappingWriter putMappingsIfAbsent,
    RommCheapFingerprinter? fingerprintCheap,
    RommFingerprintSaver? saveFingerprints,
    RommStopCheck? shouldStop,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _listPlatforms = listPlatforms,
       _resolveSystem = resolveSystem,
       _fetchPage = fetchPage,
       _listGames = listGames,
       _loadRomIdIndex = loadRomIdIndex,
       _putMappingsIfAbsent = putMappingsIfAbsent,
       _fingerprintCheap = fingerprintCheap,
       _saveFingerprints = saveFingerprints,
       _shouldStop = shouldStop ?? _neverStop,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// True while a pass — standalone or driven by the catalog refresh — is in
  /// progress.
  bool get isRunning => _running;

  /// Runs one standalone pass and returns what it did.
  ///
  /// This is the pass on its own server walk: it lists the platforms, pages
  /// them through [RommPlatformWalk] and consumes its own pages. When the
  /// catalog refresh is driving instead, it walks once and hands the pages to
  /// [beginStage]'s consumer — the same algorithm, one enumeration.
  ///
  /// Never overlaps with itself: a call while one is running returns an empty
  /// summary immediately (the provider guards this too; here it is the
  /// belt-and-braces). Never throws for a platform's sake — a failing platform
  /// is logged, counted and stepped over — but a failure to list the library,
  /// the platforms, or to resolve a platform to a system ends the run, since
  /// nothing can be matched without them, and is rethrown wrapped with
  /// context for the scheduler to log.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Concurrency Safety"
  Future<RommLinkPassSummary> run() async {
    if (_running) {
      _log.w('$logLabel skipped: a pass is already running');
      return const RommLinkPassSummary();
    }
    final begun = await _begin();
    final stage = begun.stage;
    // Nothing unlinked: the standalone pass has no reason to touch the server
    // at all. Under the catalog refresh the walk happens anyway — the catalog
    // needs it — and only this stage is skipped.
    if (stage == null) {
      final summary = RommLinkPassSummary(
        elapsed: _clock().difference(begun.started),
      );
      _logSummary(summary);
      return summary;
    }
    try {
      final result = await walk().run(
        onRom: stage.onRom,
        onPlatformComplete: stage.onPlatformComplete,
        onGroupComplete: stage.onGroupComplete,
      );
      return stage.finish(result);
    } catch (_) {
      stage.abandon();
      rethrow;
    }
  }

  /// The walk this pass would make on its own, wired to its own dependencies.
  ///
  /// Exposed so the catalog refresh can build the identical walk from the same
  /// injected server access when it drives both consumers.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  RommPlatformWalk walk() => RommPlatformWalk(
    listPlatforms: _listPlatforms,
    resolveSystem: _resolveSystem,
    fetchPage: _fetchPage,
    shouldStop: _shouldStop,
    logger: _log,
    logLabel: logLabel,
    wrapFailure: RommLinkPassException.new,
  );

  /// Opens a link stage for a walk somebody else drives.
  ///
  /// The stage is the pass's algorithm minus the paging: register
  /// [RommLinkStage.onRom], [RommLinkStage.onPlatformComplete] and
  /// [RommLinkStage.onGroupComplete] with a [RommPlatformWalk] and close it
  /// with [RommLinkStage.finish]. Returns null — with one log line — when
  /// there is nothing for it to do, either because every indexed game already
  /// has a mapping row or because a pass is already running; the caller's walk
  /// carries on regardless, which is the point: the catalog still has to be
  /// refreshed on a fully linked library.
  ///
  /// Throws [RommLinkPassException] when the local library index cannot be
  /// built, exactly as [run] does.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  Future<RommLinkStage?> beginStage() async => (await _begin()).stage;

  /// [beginStage] with the start stamp the summary's elapsed time is measured
  /// from, so exactly one clock reading opens a pass however it was entered.
  Future<({DateTime started, RommLinkStage? stage})> _begin() async {
    final started = _clock();
    if (_running) {
      _log.w('$logLabel skipped: a pass is already running');
      return (started: started, stage: null);
    }
    _running = true;
    final _LocalIndex index;
    try {
      index = _LocalIndex.build(await _listGames(), await _loadRomIdIndex());
    } catch (e) {
      _running = false;
      throw RommLinkPassException('local library index failed', e);
    }
    // Every game already has a row: nothing a server walk could add, so the
    // steady-state cost of a reconnect is one library read.
    if (index.unlinkedCount == 0) {
      _running = false;
      return (started: started, stage: null);
    }
    return (started: started, stage: RommLinkStage._(this, index, started));
  }

  /// Every folder name a system's ROMs are indexed under, normalized the way
  /// the local index keys them. The same alias source the "already downloaded"
  /// probe walks (`RommProvider._systemFolderNames`): primary plus `folders`.
  static Set<String> _folderAliases(SystemModel system) => {
    if (system.folderName.isNotEmpty) _normalizeFolder(system.folderName),
    for (final f in system.folders)
      if (f.isNotEmpty) _normalizeFolder(f),
  };

  static String _normalizeFolder(String folder) => folder.trim().toLowerCase();

  /// The one info line per run. Per-game outcomes are deliberately absent:
  /// on a large library they would drown the log, and the counts are what a
  /// user reading it needs.
  ///
  /// Every message here is phrased `link pass skipped:` rather than
  /// `link pass: skipped` because the log redactor treats `pass:` as a
  /// credential key and blanks whatever follows it.
  void _logSummary(RommLinkPassSummary s) {
    final buffer = StringBuffer(
      'RomM link pass ${s.stoppedEarly ? 'stopped early' : 'complete'}: '
      '${s.platformsProcessed} platforms processed, '
      '${s.platformsUnresolved} unresolved, '
      '${s.platformFailures} failed, '
      '${s.groupsSkipped} systems skipped after a failure, '
      '${s.romsEnumerated} ROMs enumerated, '
      '${s.rowsAdded} rows added, '
      '${s.hashRowsAdded} hash rows added, '
      '${s.rowsAlreadyPresent} already present, '
      '${s.ambiguousSkipped} ambiguous skipped, '
      '${s.conflictCount} conflicting, '
      '${s.fingerprintsComputed} fingerprints computed, '
      '${s.fingerprintsSkipped} fingerprints skipped, '
      '${s.fingerprintsDeferred} fingerprints deferred, '
      '${s.fingerprintsRemaining} fingerprints left for the next pass, '
      '${s.hashMismatches} hash mismatches, '
      '${s.elapsed.inMilliseconds} ms',
    );
    if (s.unresolvedSlugs.isNotEmpty) {
      buffer.write('; unresolved: ${s.unresolvedSlugs.join(', ')}');
    }
    if (s.ambiguities.isNotEmpty) {
      final shown = s.ambiguities.take(_ambiguityLogLimit);
      buffer.write('; ambiguous: ${shown.join('; ')}');
      final hidden = s.ambiguities.length - _ambiguityLogLimit;
      if (hidden > 0) buffer.write(' (+$hidden more)');
    }
    _log.i(buffer.toString());
    // The conflicting pairs get their own warning, one per file: the summary
    // line counts them, but which row disagrees with which match is what a
    // user reading the log needs to act on.
    // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
    if (s.conflicts.isNotEmpty) {
      for (final conflict in s.conflicts.take(_conflictLogLimit)) {
        _log.w(
          'RomM link pass left ${conflict.systemFolder}/${conflict.filename} '
          'on rom ${conflict.existingRomId} '
          '(${conflict.existingSource.dbValue} link): this pass matched it to '
          'rom ${conflict.matchedRomId}, existing rows are never overwritten',
        );
      }
      final hidden = s.conflicts.length - _conflictLogLimit;
      if (hidden > 0) {
        _log.w('RomM link pass left $hidden more conflicting rows unchanged');
      }
    }
  }
}

/// One link pass in progress, consuming pages a [RommPlatformWalk] delivers.
///
/// This is the matching half of [RommLibraryLinker] with the paging taken out:
/// it accumulates the claims each platform's ROMs make on local files, drops a
/// platform's claims when its paging failed or was cut short, and writes a
/// system group's rows once every platform in the group has been seen. Both
/// callers use it — the standalone [RommLibraryLinker.run] and the catalog
/// refresh, which registers this stage against the walk it is already making
/// so the server is enumerated once for both.
///
/// Matching is grouped by *local system*, not by platform: several RomM
/// platforms can resolve to one system (slug aliases), and a file that two of
/// them both claim is ambiguous. Rows are therefore written once per system
/// group, after every platform in it has been paged, so the ambiguity check
/// sees the whole picture before anything is committed.
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
class RommLinkStage {
  final RommLibraryLinker _linker;
  final _LocalIndex _index;
  final DateTime _started;

  /// Claims made by the platform currently being paged, keyed by platform id:
  /// local file → the distinct ROMs claiming it. Merged into [_claims] when
  /// the platform completes, dropped when it fails or is stopped — a platform
  /// only partly seen cannot be checked for ambiguity.
  final Map<int, Map<_LocalGame, Map<int, String>>> _platformClaims = {};

  /// Claims accumulated for the system group being walked, keyed by folder.
  final Map<String, Map<_LocalGame, Map<int, String>>> _claims = {};

  /// The hashes of the platform currently being paged, keyed by platform id:
  /// crc32 → ROM id → what that ROM (or one of its files) says beside the
  /// crc. Kept and dropped exactly as [_platformClaims] is: a platform only
  /// partly seen cannot be checked for ambiguity.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  final Map<int, Map<String, Map<int, List<_RomHashes>>>> _platformHashes = {};

  /// The hash index of the system group being walked, keyed by folder — the
  /// completed platforms' [_platformHashes] merged.
  final Map<String, Map<String, Map<int, List<_RomHashes>>>> _hashes = {};

  /// Normalized folder aliases per system folder, computed once per group.
  final Map<String, Set<String>> _aliases = {};

  final List<RommLinkAmbiguity> _ambiguities = [];
  final List<RommLinkConflict> _conflicts = [];
  final List<String> _linked = [];

  var _added = 0;
  var _hashAdded = 0;
  var _alreadyPresent = 0;
  var _groupsSkipped = 0;
  var _fingerprintsComputed = 0;
  var _fingerprintsSkipped = 0;
  var _fingerprintsDeferred = 0;
  var _fingerprintsRemaining = 0;
  var _hashMismatches = 0;
  var _fingerprintBudget = RommLibraryLinker.fingerprintCapPerPass;

  /// True once the stop check fired inside the fingerprint step. The walk
  /// polls the same check between pages and groups; this is the one place
  /// the stage polls it itself, so it has to carry the answer to the summary.
  var _stopped = false;
  var _closed = false;

  RommLinkStage._(this._linker, this._index, this._started);

  /// Records what [rom] claims among the local files of [group]'s system,
  /// and every hash it carries for the group's hash index.
  void onRom(RommWalkGroup group, RommPlatform platform, RommRom rom) {
    final aliases = _aliases.putIfAbsent(
      group.system.folderName,
      () => RommLibraryLinker._folderAliases(group.system),
    );
    final claims = _platformClaims.putIfAbsent(platform.id, () => {});
    for (final candidate in RommLocalMatcher.candidateNames(rom)) {
      final key = RommLocalMatcher.normalizeName(candidate);
      for (final alias in aliases) {
        final game = _index.lookup(alias, key);
        if (game == null) continue;
        claims.putIfAbsent(game, () => {})[rom.id] = rom.fsName;
      }
    }
    // ROM-level and file-level hashes are indexed side by side (the union
    // `allCrc32`), each with the md5 and size *of its own level*: whether
    // RomM hashed the stored archive or the image inside it depends on the
    // server version and file type, and comparing a file's md5 against the
    // archive's size would veto a correct match.
    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
    final hashes = _platformHashes.putIfAbsent(platform.id, () => {});
    void record(String? crc, String? md5, int size) {
      if (crc == null) return;
      hashes
          .putIfAbsent(crc, () => {})
          .putIfAbsent(rom.id, () => [])
          .add(_RomHashes(fsName: rom.fsName, md5: md5, size: size));
    }

    record(rom.crcHash, rom.md5Hash, rom.fsSizeBytes);
    for (final file in rom.files) {
      record(file.crcHash, file.md5Hash, file.fileSizeBytes);
    }
  }

  /// Keeps a completed platform's claims and discards the rest.
  ///
  /// A platform that threw part-way — or that the stop check cut short — has
  /// not been fully seen, so its matches cannot be checked for ambiguity;
  /// contributing nothing is the only outcome that can't link the wrong ROM.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Ambiguous Matches Are Skipped"
  Future<void> onPlatformComplete(
    RommWalkGroup group,
    RommPlatform platform,
    RommWalkPlatformOutcome outcome,
  ) async {
    final claims = _platformClaims.remove(platform.id);
    final hashes = _platformHashes.remove(platform.id);
    if (outcome != RommWalkPlatformOutcome.completed) return;
    final folder = group.system.folderName;
    if (claims != null) {
      final groupClaims = _claims.putIfAbsent(folder, () => {});
      for (final entry in claims.entries) {
        groupClaims.putIfAbsent(entry.key, () => {}).addAll(entry.value);
      }
    }
    if (hashes != null) {
      final groupHashes = _hashes.putIfAbsent(folder, () => {});
      for (final byCrc in hashes.entries) {
        final byRom = groupHashes.putIfAbsent(byCrc.key, () => {});
        for (final entry in byCrc.value.entries) {
          byRom.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }
      }
    }
  }

  /// Writes the rows for one system group, now that every platform in it has
  /// been walked: the filename stage's, then — for the games it left
  /// unlinked, topped up with cheap fingerprints — the hash stage's, in one
  /// insert-if-absent batch.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  Future<void> onGroupComplete(
    RommWalkGroup group, {
    required bool groupFailed,
  }) async {
    final folder = group.system.folderName;
    final claims = _claims.remove(folder) ?? const {};
    final hashes = _hashes.remove(folder) ?? const {};
    // A failed platform in a multi-platform group: a file the surviving
    // platforms claim once may also be claimed by a ROM on the platform that
    // threw, and a guess written now is permanent (rows are never
    // overwritten). Skipping the whole group keeps the ambiguity check whole;
    // the next connect retries it. A single-platform group that failed has
    // nothing to write, so it is not counted here.
    // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Ambiguous Matches Are Skipped"
    if (groupFailed && group.platforms.length > 1) {
      _groupsSkipped++;
      _linker._log.w(
        'RomM link pass skipped system "${group.system.folderName}": '
        'a platform in its group failed, so its matches were not written',
      );
      return;
    }

    final entries = <RommSaveMapEntry>[];
    final entryGames = <_LocalGame>[];
    for (final entry in claims.entries) {
      final game = entry.key;
      final roms = entry.value;
      // A row that already exists is never touched, so whether the match is
      // ambiguous is moot for it. A row pointing somewhere none of this
      // pass's matches do is recorded, not corrected: the user's saves are
      // attached to the id in the row, and swapping it silently would move
      // them to a ROM the server may have renumbered underneath us — or,
      // for a manual row, away from the ROM the user deliberately chose.
      // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
      // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
      final existingRomId = game.existingRomId;
      if (existingRomId != null) {
        _alreadyPresent++;
        if (!roms.containsKey(existingRomId)) {
          for (final matchedRomId in roms.keys.toList()..sort()) {
            _conflicts.add(
              RommLinkConflict(
                filename: game.filename,
                systemFolder: game.systemFolder,
                existingRomId: existingRomId,
                existingSource: game.existingSource ?? RommLinkSource.auto,
                matchedRomId: matchedRomId,
              ),
            );
          }
        }
        continue;
      }
      // Two ROMs claiming one file: guessing would attach the user's saves
      // to the wrong server entry, so record both and write nothing.
      // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Ambiguous Matches Are Skipped"
      if (roms.length > 1) {
        _ambiguities.add(
          RommLinkAmbiguity(
            filename: game.filename,
            systemFolder: game.systemFolder,
            romIds: roms.keys.toList()..sort(),
          ),
        );
        continue;
      }
      final romId = roms.keys.single;
      entries.add((
        romname: game.filename,
        systemFolder: game.systemFolder,
        rommRomId: romId,
        fsName: roms[romId],
        source: RommLinkSource.auto,
      ));
      entryGames.add(game);
    }

    // Stage two. A game the filename stage had any claim on — linked, in
    // conflict, or ambiguous — is settled; the filename decision wins. The
    // rest of the group's games are matched by hash, fingerprinting the ones
    // that have none first.
    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
    final aliases = _aliases.putIfAbsent(
      folder,
      () => RommLibraryLinker._folderAliases(group.system),
    );
    final candidates = [
      for (final game in _index.gamesUnder(aliases))
        if (!claims.containsKey(game)) game,
    ];
    await _fingerprintUnlinked(
      folder,
      candidates,
      hasHashes: hashes.isNotEmpty,
    );
    final hashCount = _matchByHash(candidates, hashes, entries, entryGames);
    if (entries.isEmpty) return;

    final inserted = await _linker._putMappingsIfAbsent(entries);
    // One batch, one count: the writer says how many rows went in, not
    // which. The split is exact unless a row appeared between the index read
    // and the write (a download finishing); that shortfall is charged to the
    // filename stage, which already reads an ignored insert as "already
    // present" rather than a failure.
    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
    final hashInserted = hashCount < inserted ? hashCount : inserted;
    _hashAdded += hashInserted;
    _added += inserted - hashInserted;
    _alreadyPresent += entries.length - inserted;
    if (inserted > 0) {
      // Which specific rows were ignored isn't reported; every candidate is
      // invalidated, which is harmless — a game that was linked by a
      // download meanwhile needs its badge refreshed just the same.
      _linked.addAll(entryGames.map((g) => g.romname));
    }
  }

  /// Computes the cheap fingerprint of every unlinked game in [candidates]
  /// that has none and is not parked, up to the per-pass cap, and persists
  /// the outcomes in one batch.
  ///
  /// Skipped altogether when the pass was built without the two halves of the
  /// step, and for a group whose hash index is empty ([hasHashes] false: the
  /// server sent no hashes for it, or its platform failed and they were
  /// discarded) — nothing computed now could match this pass, so up to a
  /// cap's worth of zip-tail reads is not spent on it; the games stay
  /// unfingerprinted and a later pass with hashes picks them up. Polls the
  /// stop check before each file: a disconnect mid-step ends the reads after
  /// the current file, persists what was computed, and the group still
  /// matches on what it has — no server round trip is involved past this
  /// point. A file whose fingerprint would cost a full read
  /// (`deferredCostly`) is counted as deferred, not skipped: it is neither
  /// parked nor charged to the cap, since nothing was read for it and
  /// nothing is wrong with it.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Concurrency Safety"
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Error Handling Standards"
  Future<void> _fingerprintUnlinked(
    String folder,
    List<_LocalGame> candidates, {
    required bool hasHashes,
  }) async {
    final fingerprintCheap = _linker._fingerprintCheap;
    final save = _linker._saveFingerprints;
    if (fingerprintCheap == null || save == null) return;

    if (!hasHashes) {
      final pending = candidates.where(_wantsFingerprint).length;
      if (pending > 0) {
        _linker._log.i(
          'RomM hash stage skipped fingerprinting for system "$folder": '
          'the server sent no hashes for it, so $pending files were left '
          'for a later pass',
        );
      }
      return;
    }

    final writes = <RomFingerprintWrite>[];
    for (final game in candidates) {
      if (!_wantsFingerprint(game)) continue;
      if (_fingerprintBudget <= 0) {
        _fingerprintsRemaining++;
        continue;
      }
      if (_stopped || _linker._shouldStop()) {
        _stopped = true;
        _fingerprintsRemaining++;
        continue;
      }

      ({RomFingerprint? fingerprint, String? skipReason}) attempt;
      try {
        attempt = await fingerprintCheap(game.romPath, game.systemFolder);
      } catch (e) {
        // Named and parked, never swallowed: the file is recorded as
        // unreadable so the next pass does not pay for it again, and the
        // pass carries on with the rest.
        _linker._log.w(
          'RomM link pass could not fingerprint '
          '${game.systemFolder}/${game.filename}: $e',
        );
        attempt = (
          fingerprint: null,
          skipReason: RomFingerprintService.skipError,
        );
      }

      final fingerprint = attempt.fingerprint;
      if (fingerprint != null) {
        _fingerprintBudget--;
        _fingerprintsComputed++;
        game.setFingerprint(fingerprint);
        writes.add((
          romPath: game.romPath,
          crc32: fingerprint.crc32,
          md5: fingerprint.md5,
          size: fingerprint.sizeBytes,
          skipReason: null,
        ));
        continue;
      }
      final reason = attempt.skipReason ?? RomFingerprintService.skipError;
      if (reason == RomFingerprintService.deferredCostly) {
        _fingerprintsDeferred++;
        continue;
      }
      _fingerprintsSkipped++;
      _fingerprintBudget--;
      game.skipped = true;
      writes.add((
        romPath: game.romPath,
        crc32: null,
        md5: null,
        size: null,
        skipReason: reason,
      ));
    }
    if (writes.isNotEmpty) await save(writes);
  }

  /// An unlinked game the step would fingerprint: it has no crc32 yet and
  /// is not parked.
  static bool _wantsFingerprint(_LocalGame game) =>
      !game.linked && game.crc32 == null && !game.skipped;

  /// Matches [candidates] by crc32 against the group's hash index and
  /// appends the rows to write to [entries]; returns how many it appended.
  ///
  /// A crc32 match stands unless the md5 or the size says otherwise: when
  /// both sides carry one they must agree ([_LocalGame.agreesWith]). A game
  /// whose crc32 survives for more than one ROM id is ambiguous and skipped;
  /// one whose only matches were vetoed is a mismatch and counted. A game
  /// that already has a row is never written — the row is the user's saves'
  /// anchor — but a match pointing elsewhere is reported, exactly as the
  /// filename stage reports its own.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Rows Follow The Link Rules"
  int _matchByHash(
    List<_LocalGame> candidates,
    Map<String, Map<int, List<_RomHashes>>> hashes,
    List<RommSaveMapEntry> entries,
    List<_LocalGame> entryGames,
  ) {
    if (hashes.isEmpty) return 0;
    var appended = 0;
    for (final game in candidates) {
      final crc = game.crc32;
      if (crc == null) continue;
      final byRom = hashes[crc];
      if (byRom == null || byRom.isEmpty) continue;

      final matched = <int, String>{};
      for (final entry in byRom.entries) {
        for (final romHashes in entry.value) {
          if (game.agreesWith(romHashes)) {
            matched[entry.key] = romHashes.fsName;
            break;
          }
        }
      }
      if (matched.isEmpty) {
        _hashMismatches++;
        continue;
      }

      // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
      // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
      final existingRomId = game.existingRomId;
      if (existingRomId != null) {
        _alreadyPresent++;
        if (!matched.containsKey(existingRomId)) {
          for (final matchedRomId in matched.keys.toList()..sort()) {
            _conflicts.add(
              RommLinkConflict(
                filename: game.filename,
                systemFolder: game.systemFolder,
                existingRomId: existingRomId,
                existingSource: game.existingSource ?? RommLinkSource.auto,
                matchedRomId: matchedRomId,
              ),
            );
          }
        }
        continue;
      }
      if (matched.length > 1) {
        _ambiguities.add(
          RommLinkAmbiguity(
            filename: game.filename,
            systemFolder: game.systemFolder,
            romIds: matched.keys.toList()..sort(),
          ),
        );
        continue;
      }
      final romId = matched.keys.single;
      entries.add((
        romname: game.filename,
        systemFolder: game.systemFolder,
        rommRomId: romId,
        fsName: matched[romId],
        source: RommLinkSource.hash,
      ));
      entryGames.add(game);
      appended++;
    }
    return appended;
  }

  /// Closes the stage against the walk that drove it and logs the one summary
  /// line. Releases [RommLibraryLinker.isRunning].
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Pass Observability"
  RommLinkPassSummary finish(RommWalkResult result) {
    final summary = RommLinkPassSummary(
      platformsProcessed: result.platformsProcessed,
      platformsUnresolved: result.platformsUnresolved,
      platformFailures: result.platformFailures,
      groupsSkipped: _groupsSkipped,
      romsEnumerated: result.romsEnumerated,
      rowsAdded: _added,
      rowsAlreadyPresent: _alreadyPresent,
      ambiguities: _ambiguities,
      conflicts: _conflicts,
      unresolvedSlugs: result.unresolvedSlugs,
      stoppedEarly: result.stoppedEarly || _stopped,
      elapsed: _linker._clock().difference(_started),
      linkedRomnames: _linked,
      hashRowsAdded: _hashAdded,
      fingerprintsComputed: _fingerprintsComputed,
      fingerprintsSkipped: _fingerprintsSkipped,
      fingerprintsDeferred: _fingerprintsDeferred,
      fingerprintsRemaining: _fingerprintsRemaining,
      hashMismatches: _hashMismatches,
    );
    _close();
    _linker._logSummary(summary);
    return summary;
  }

  /// Closes the stage without a summary, for a walk that threw before it
  /// could produce one.
  void abandon() => _close();

  void _close() {
    if (_closed) return;
    _closed = true;
    _linker._running = false;
  }
}

/// Why [RommLibraryLinker.run] could not run at all — the library, the
/// platform list, or a platform's system resolution was unreadable.
/// Per-platform paging failures are counted, not thrown; this is for the
/// inputs nothing can proceed without.
class RommLinkPassException implements Exception {
  final String context;
  final Object cause;

  const RommLinkPassException(this.context, this.cause);

  @override
  String toString() => 'RomM link pass failed: $context: $cause';
}

/// What one RomM ROM — or one of its files — says beside a crc32 in the
/// group's hash index: the md5 and size *at that level*, and the name the
/// row is written with.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
@immutable
class _RomHashes {
  final String fsName;

  /// Lowercase hex, or null when RomM sent none at this level.
  final String? md5;

  /// Stored size in bytes at this level; 0 reads as unknown.
  final int size;

  const _RomHashes({
    required this.fsName,
    required this.md5,
    required this.size,
  });
}

/// One indexed local file. Identity is the `(systemFolder, filename)` pair,
/// which is also the mapping table's primary key, so two library rows for the
/// same file (a duplicate scan) collapse to one candidate.
///
/// The fingerprint fields are the one mutable part: they start from what the
/// library persisted and are filled in when the pass computes a cheap
/// fingerprint — on the main isolate, after the isolate has answered — so the
/// hash stage reads one place. Identity never depends on them.
class _LocalGame {
  /// On-disk filename with extension, the library's canonical spelling.
  final String filename;

  /// Extension-stripped name — the sync provider's cache key.
  final String romname;

  /// The system folder the row carries, exactly as stored.
  final String systemFolder;

  /// The stored path (a SAF `content://` URI on Android), which is what the
  /// fingerprinter opens and the fingerprint columns are keyed by.
  final String romPath;

  /// The image's crc32, lowercase hex, or null when the library holds none.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  String? crc32;

  /// The image's md5, lowercase hex, or null when only the cheap path ran.
  String? md5;

  /// The image's size in bytes, or null when not fingerprinted.
  int? size;

  /// True when an earlier attempt parked the file with a skip reason; the
  /// pass does not try again.
  bool skipped;

  /// The RomM ROM id of the mapping row the file already had when the pass
  /// started, or null when it had none. Kept as the id rather than a flag so
  /// a match that disagrees with the row can be reported.
  final int? existingRomId;

  /// Who wrote that row (null when there is none), reported alongside
  /// [existingRomId] so a conflict with a manual row reads as such.
  final RommLinkSource? existingSource;

  _LocalGame({
    required this.filename,
    required this.romname,
    required this.systemFolder,
    required this.romPath,
    required this.existingRomId,
    required this.existingSource,
    this.crc32,
    this.md5,
    this.size,
    this.skipped = false,
  });

  /// Already had a mapping row when the pass started.
  bool get linked => existingRomId != null;

  /// A zip or 7z the library indexes by its inner image: the fingerprint
  /// describes the image, so the stored size RomM reports for the archive
  /// is not comparable with it.
  bool get isArchive {
    final lower = filename.toLowerCase();
    return lower.endsWith('.zip') || lower.endsWith('.7z');
  }

  /// Adopts a fingerprint computed this pass.
  void setFingerprint(RomFingerprint fingerprint) {
    crc32 = normalizeRommHash(fingerprint.crc32);
    md5 = normalizeRommHash(fingerprint.md5) ?? md5;
    size = fingerprint.sizeBytes;
    skipped = false;
  }

  /// Whether a crc32 match with [rom] stands: when both sides carry an md5
  /// they must agree, and when both carry a size they must agree — except
  /// for an archive, whose local size is the inner image's while RomM's is
  /// the stored file's, so the two say nothing about each other.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  bool agreesWith(_RomHashes rom) {
    final localMd5 = md5;
    if (localMd5 != null && rom.md5 != null && localMd5 != rom.md5) {
      return false;
    }
    final localSize = size;
    if (!isArchive &&
        localSize != null &&
        localSize > 0 &&
        rom.size > 0 &&
        localSize != rom.size) {
      return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is _LocalGame &&
      other.filename == filename &&
      other.systemFolder == systemFolder;

  @override
  int get hashCode => Object.hash(filename, systemFolder);
}

/// The local library keyed by `(normalized system folder, normalized
/// filename)` — the same normalization [RommLocalMatcher] compares with, so a
/// lookup by a ROM's candidate name is exactly the equivalence rule.
class _LocalIndex {
  final Map<String, _LocalGame> _byKey;

  /// The same games grouped by normalized folder, for the hash stage, which
  /// walks a system group's games rather than looking them up by name.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  final Map<String, List<_LocalGame>> _byFolder;
  final int unlinkedCount;

  const _LocalIndex._(this._byKey, this._byFolder, this.unlinkedCount);

  static String _keyFor(String folder, String normalizedName) =>
      '$folder\t$normalizedName';

  static _LocalIndex build(
    List<DatabaseGameModel> games,
    RommRomIdIndex romIds,
  ) {
    final byKey = <String, _LocalGame>{};
    final byFolder = <String, List<_LocalGame>>{};
    var unlinked = 0;
    for (final game in games) {
      final folder = game.systemFolderName ?? '';
      final filename = game.filename;
      if (folder.isEmpty || filename.isEmpty) continue;
      final normalizedFolder = RommLibraryLinker._normalizeFolder(folder);
      final key = _keyFor(
        normalizedFolder,
        RommLocalMatcher.normalizeName(filename),
      );
      if (byKey.containsKey(key)) continue;
      // The map is written with the on-disk name but read by either spelling
      // (see RommSaveMapRepository.getRomIdIndex), so ask both ways. The
      // source is read under whichever spelling answered, so it describes the
      // same row as the id.
      var spelling = filename;
      var existingRomId = romIds.lookup(spelling, folder);
      if (existingRomId == null) {
        spelling = game.romname;
        existingRomId = romIds.lookup(spelling, folder);
      }
      if (existingRomId == null) unlinked++;
      final local = _LocalGame(
        filename: filename,
        romname: game.romname,
        systemFolder: folder,
        romPath: game.romPath,
        existingRomId: existingRomId,
        existingSource: existingRomId == null
            ? null
            : romIds.sourceFor(spelling, folder),
        crc32: normalizeRommHash(game.romCrc32),
        md5: normalizeRommHash(game.romMd5),
        size: game.romSize,
        skipped: game.fingerprintSkipped != null,
      );
      byKey[key] = local;
      byFolder.putIfAbsent(normalizedFolder, () => []).add(local);
    }
    return _LocalIndex._(byKey, byFolder, unlinked);
  }

  /// The indexed file named [normalizedName] under [normalizedFolder].
  _LocalGame? lookup(String normalizedFolder, String normalizedName) =>
      _byKey[_keyFor(normalizedFolder, normalizedName)];

  /// Every indexed file under any of the normalized folder [aliases], in
  /// library order.
  Iterable<_LocalGame> gamesUnder(Set<String> aliases) sync* {
    for (final alias in aliases) {
      yield* _byFolder[alias] ?? const [];
    }
  }
}
