import 'package:flutter/foundation.dart';

import '../../models/database_game_model.dart';
import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../models/romm_rom_page.dart';
import '../../models/system_model.dart';
import '../../providers/romm_bulk_sync.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../utils/romm_local_matcher.dart';
import '../logger_service.dart';

/// Lists the server's platforms (the ones with ROMs on them).
typedef RommPlatformLister = Future<List<RommPlatform>> Function();

/// Resolves a RomM platform to the local system its ROMs belong to, or null
/// when this build has no system for it.
typedef RommPlatformResolver =
    Future<SystemModel?> Function(RommPlatform platform);

/// One page of a platform's ROMs. Offset/limit paging only, like
/// [RommPageFetcher]; the platform is bound per call because the pass walks
/// several.
typedef RommPlatformPageFetcher =
    Future<RommRomPage> Function({
      required int platformId,
      required int limit,
      required int offset,
    });

/// The local library index — the scanned games table, never the disk.
typedef RommLocalLibraryLister = Future<List<DatabaseGameModel>> Function();

/// Every mapping already recorded, so linked games can be skipped up front.
typedef RommRomIdIndexLoader = Future<RommRomIdIndex> Function();

/// Insert-if-absent for a batch of links; returns the rows actually written.
typedef RommMappingWriter =
    Future<int> Function(List<RommSaveMapEntry> entries);

/// Polled between platforms and between pages; true ends the pass.
typedef RommStopCheck = bool Function();

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

  const RommLinkPassSummary({
    this.platformsProcessed = 0,
    this.platformsUnresolved = 0,
    this.platformFailures = 0,
    this.romsEnumerated = 0,
    this.rowsAdded = 0,
    this.rowsAlreadyPresent = 0,
    this.ambiguities = const [],
    this.unresolvedSlugs = const [],
    this.stoppedEarly = false,
    this.elapsed = Duration.zero,
    this.linkedRomnames = const [],
  });

  int get ambiguousSkipped => ambiguities.length;
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
/// Dependencies are injected in the style of [RommBulkSync.run] so the
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
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
class RommLibraryLinker {
  static final _defaultLog = LoggerService.instance;

  /// Rows per page — bulk sync's enumeration size, shared on purpose so the
  /// two server walks cost the same.
  static const int pageSize = RommBulkSync.defaultPageSize;

  /// Hard stop on the paging loop per platform, in pages. Mirrors bulk sync's
  /// enumeration cap (`RommBulkSync._maxPages`, private there): a server that
  /// keeps returning full pages would otherwise page forever. 500 × 500 =
  /// 250k ROMs per platform, far past any real library.
  static const int pageCap = 500;

  /// Most ambiguities named in the summary line; the rest are counted.
  static const int _ambiguityLogLimit = 20;

  final RommPlatformLister _listPlatforms;
  final RommPlatformResolver _resolveSystem;
  final RommPlatformPageFetcher _fetchPage;
  final RommLocalLibraryLister _listGames;
  final RommRomIdIndexLoader _loadRomIdIndex;
  final RommMappingWriter _putMappingsIfAbsent;
  final RommStopCheck _shouldStop;
  final DateTime Function() _clock;
  final LoggerService _log;

  bool _running = false;

  RommLibraryLinker({
    required RommPlatformLister listPlatforms,
    required RommPlatformResolver resolveSystem,
    required RommPlatformPageFetcher fetchPage,
    required RommLocalLibraryLister listGames,
    required RommRomIdIndexLoader loadRomIdIndex,
    required RommMappingWriter putMappingsIfAbsent,
    RommStopCheck? shouldStop,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _listPlatforms = listPlatforms,
       _resolveSystem = resolveSystem,
       _fetchPage = fetchPage,
       _listGames = listGames,
       _loadRomIdIndex = loadRomIdIndex,
       _putMappingsIfAbsent = putMappingsIfAbsent,
       _shouldStop = shouldStop ?? _neverStop,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  static bool _neverStop() => false;

  /// True while [run] is in progress.
  bool get isRunning => _running;

  /// Runs one pass and returns what it did.
  ///
  /// Never overlaps with itself: a call while one is running returns an empty
  /// summary immediately (the provider guards this too; here it is the
  /// belt-and-braces). Never throws for a platform's sake — a failing platform
  /// is logged, counted and stepped over — but a failure to list the library
  /// or the platforms ends the run, since nothing can be matched without them,
  /// and is rethrown wrapped with context for the scheduler to log.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Concurrency Safety"
  Future<RommLinkPassSummary> run() async {
    if (_running) {
      _log.w('RomM link pass skipped: a pass is already running');
      return const RommLinkPassSummary();
    }
    _running = true;
    final started = _clock();
    try {
      final summary = await _run(started);
      _logSummary(summary);
      return summary;
    } finally {
      _running = false;
    }
  }

  Future<RommLinkPassSummary> _run(DateTime started) async {
    final _LocalIndex index;
    try {
      index = _LocalIndex.build(await _listGames(), await _loadRomIdIndex());
    } catch (e) {
      throw RommLinkPassException('local library index failed', e);
    }
    // Every game already has a row: nothing a server walk could add, so the
    // steady-state cost of a reconnect is one library read.
    if (index.unlinkedCount == 0) {
      return RommLinkPassSummary(elapsed: _clock().difference(started));
    }

    final List<RommPlatform> platforms;
    try {
      platforms = await _listPlatforms();
    } catch (e) {
      throw RommLinkPassException('platform enumeration failed', e);
    }

    // Group platforms by the local system they resolve to, in server order.
    final groups = <String, _SystemGroup>{};
    final unresolvedSlugs = <String>[];
    for (final platform in platforms) {
      final system = await _resolveSystem(platform);
      if (system == null) {
        unresolvedSlugs.add(platform.slug);
        continue;
      }
      groups
          .putIfAbsent(system.folderName, () => _SystemGroup(system))
          .platforms
          .add(platform);
    }

    var processed = 0, failures = 0, enumerated = 0;
    var added = 0, alreadyPresent = 0;
    var stopped = false;
    final ambiguities = <RommLinkAmbiguity>[];
    final linked = <String>[];

    for (final group in groups.values) {
      if (_shouldStop()) {
        stopped = true;
        break;
      }
      // Matches for this system: local file → the distinct ROMs claiming it.
      final claims = <_LocalGame, Map<int, String>>{};
      final aliases = _folderAliases(group.system);

      for (final platform in group.platforms) {
        if (_shouldStop()) {
          stopped = true;
          break;
        }
        final platformClaims = <_LocalGame, Map<int, String>>{};
        final result = await _pagePlatform(platform, (rom) {
          enumerated++;
          for (final candidate in RommLocalMatcher.candidateNames(rom)) {
            final key = RommLocalMatcher.normalizeName(candidate);
            for (final alias in aliases) {
              final game = index.lookup(alias, key);
              if (game == null) continue;
              platformClaims.putIfAbsent(game, () => {})[rom.id] = rom.fsName;
            }
          }
        });
        switch (result) {
          case _PageResult.completed:
            processed++;
            for (final entry in platformClaims.entries) {
              claims.putIfAbsent(entry.key, () => {}).addAll(entry.value);
            }
          case _PageResult.failed:
            // A platform that threw part-way has not been fully seen, so its
            // matches cannot be checked for ambiguity; contributing nothing
            // is the only outcome that can't link the wrong ROM.
            failures++;
          case _PageResult.stopped:
            stopped = true;
        }
        if (stopped) break;
      }
      // A stop mid-group leaves the group unwritten: the ambiguity check needs
      // every platform in it, and the contract is "no further rows".
      if (stopped) break;

      final entries = <RommSaveMapEntry>[];
      final entryGames = <_LocalGame>[];
      for (final entry in claims.entries) {
        final game = entry.key;
        final roms = entry.value;
        // A row that already exists is never touched, so whether the match is
        // ambiguous is moot for it.
        if (game.linked) {
          alreadyPresent++;
          continue;
        }
        // Two ROMs claiming one file: guessing would attach the user's saves
        // to the wrong server entry, so record both and write nothing.
        // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Ambiguous Matches Are Skipped"
        if (roms.length > 1) {
          ambiguities.add(
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
        ));
        entryGames.add(game);
      }
      if (entries.isEmpty) continue;

      final inserted = await _putMappingsIfAbsent(entries);
      added += inserted;
      // An ignored insert means a row appeared between the index read and the
      // write (a download finishing): already present, not a failure.
      alreadyPresent += entries.length - inserted;
      if (inserted > 0) {
        // Which specific rows were ignored isn't reported; every candidate is
        // invalidated, which is harmless — a game that was linked by a
        // download meanwhile needs its badge refreshed just the same.
        linked.addAll(entryGames.map((g) => g.romname));
      }
    }

    return RommLinkPassSummary(
      platformsProcessed: processed,
      platformsUnresolved: unresolvedSlugs.length,
      platformFailures: failures,
      romsEnumerated: enumerated,
      rowsAdded: added,
      rowsAlreadyPresent: alreadyPresent,
      ambiguities: ambiguities,
      unresolvedSlugs: unresolvedSlugs,
      stoppedEarly: stopped,
      elapsed: _clock().difference(started),
      linkedRomnames: linked,
    );
  }

  /// Pages one platform to completion, handing every ROM to [onRom].
  ///
  /// Same loop shape as bulk sync's enumeration: a short page ends the
  /// results, an empty one guards a server that ignores the offset, and the
  /// page cap guards one that never stops. The stop check runs before every
  /// request so a dispose or disconnect ends the pass before the next round
  /// trip.
  Future<_PageResult> _pagePlatform(
    RommPlatform platform,
    void Function(RommRom rom) onRom,
  ) async {
    var offset = 0;
    var total = 0;
    for (var page = 0; page < pageCap; page++) {
      if (_shouldStop()) return _PageResult.stopped;

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
        _log.w(
          'RomM link pass platform "${platform.slug}" (id ${platform.id}) '
          'failed at offset $offset, skipping it: $e',
        );
        return _PageResult.failed;
      }

      if (result.total > 0) total = result.total;
      for (final rom in result.items) {
        onRom(rom);
      }

      offset += result.items.length;
      if (result.items.length < pageSize) return _PageResult.completed;
      if (total > 0 && offset >= total) return _PageResult.completed;
    }
    _log.w(
      'RomM link pass platform "${platform.slug}" hit the $pageCap-page cap, '
      'matched what was seen',
    );
    return _PageResult.completed;
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
      '${s.romsEnumerated} ROMs enumerated, '
      '${s.rowsAdded} rows added, '
      '${s.rowsAlreadyPresent} already present, '
      '${s.ambiguousSkipped} ambiguous skipped, '
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
  }
}

/// Why [RommLibraryLinker.run] could not run at all — the library or the
/// platform list was unreadable. Per-platform failures are counted, not
/// thrown; this is for the two inputs nothing can proceed without.
class RommLinkPassException implements Exception {
  final String context;
  final Object cause;

  const RommLinkPassException(this.context, this.cause);

  @override
  String toString() => 'RomM link pass failed: $context: $cause';
}

enum _PageResult { completed, failed, stopped }

/// Platforms resolving to one local system, written together.
class _SystemGroup {
  final SystemModel system;
  final List<RommPlatform> platforms = [];
  _SystemGroup(this.system);
}

/// One indexed local file. Identity is the `(systemFolder, filename)` pair,
/// which is also the mapping table's primary key, so two library rows for the
/// same file (a duplicate scan) collapse to one candidate.
@immutable
class _LocalGame {
  /// On-disk filename with extension, the library's canonical spelling.
  final String filename;

  /// Extension-stripped name — the sync provider's cache key.
  final String romname;

  /// The system folder the row carries, exactly as stored.
  final String systemFolder;

  /// Already had a mapping row when the pass started.
  final bool linked;

  const _LocalGame({
    required this.filename,
    required this.romname,
    required this.systemFolder,
    required this.linked,
  });

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
  final int unlinkedCount;

  const _LocalIndex._(this._byKey, this.unlinkedCount);

  static String _keyFor(String folder, String normalizedName) =>
      '$folder\t$normalizedName';

  static _LocalIndex build(
    List<DatabaseGameModel> games,
    RommRomIdIndex romIds,
  ) {
    final byKey = <String, _LocalGame>{};
    var unlinked = 0;
    for (final game in games) {
      final folder = game.systemFolderName ?? '';
      final filename = game.filename;
      if (folder.isEmpty || filename.isEmpty) continue;
      final key = _keyFor(
        RommLibraryLinker._normalizeFolder(folder),
        RommLocalMatcher.normalizeName(filename),
      );
      if (byKey.containsKey(key)) continue;
      // The map is written with the on-disk name but read by either spelling
      // (see RommSaveMapRepository.getRomIdIndex), so ask both ways.
      final linked =
          romIds.lookup(filename, folder) != null ||
          romIds.lookup(game.romname, folder) != null;
      if (!linked) unlinked++;
      byKey[key] = _LocalGame(
        filename: filename,
        romname: game.romname,
        systemFolder: folder,
        linked: linked,
      );
    }
    return _LocalIndex._(byKey, unlinked);
  }

  /// The indexed file named [normalizedName] under [normalizedFolder].
  _LocalGame? lookup(String normalizedFolder, String normalizedName) =>
      _byKey[_keyFor(normalizedFolder, normalizedName)];
}
