import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../data/datasources/sqlite_service.dart';
import '../repositories/game_repository.dart';
import '../repositories/scraper_repository.dart';
import 'config_service.dart';
import 'esde/saf_media_mirror.dart';
import 'logger_service.dart';
import 'permission_service.dart';
import 'saf_directory_service.dart';
import 'storage_space_service.dart';
import 'user_data_location_service.dart';

/// Which path the in-folder importer took for one configured ROM folder.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Real-Path Precedence"
enum EsdeImportPathKind {
  /// Resolved to a readable real path and imported per SPEC-0002.
  real,

  /// A `content://` tree with no readable real path, discovered over SAF.
  saf,

  /// A `content://` tree that could not even be listed (lost grant, SAF
  /// unavailable on this platform); counted in
  /// [EsdeImportResult.foldersSkippedSaf].
  skippedSaf,
}

/// Per-folder record of the path the in-folder importer used, so the summary
/// can say which folders were read directly and which went over SAF.
class EsdeImportFolderOutcome {
  /// The ROM folder exactly as configured (a plain path or a `content://` URI).
  final String folder;

  final EsdeImportPathKind kind;

  const EsdeImportFolderOutcome({required this.folder, required this.kind});

  @override
  String toString() => 'EsdeImportFolderOutcome($folder: ${kind.name})';
}

/// A SAF operation the importer could not perform: the tree is unreadable
/// (no persisted grant, SAF unavailable off-Android) or a document read
/// returned nothing. Sentinel so callers can tell an access failure apart
/// from a parse failure when isolating one system.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
class EsdeSafAccessException implements Exception {
  final String uri;
  final String reason;

  const EsdeSafAccessException(this.uri, this.reason);

  @override
  String toString() => 'EsdeSafAccessException(uri=$uri reason=$reason)';
}

/// Thrown by [EsdeImportService.reset] when an import is running: two
/// overlapping runs would race on the same metadata rows and mirror files.
/// The import entry points return a result flagged
/// [EsdeImportResult.refusedAlreadyRunning] instead of throwing, because they
/// already hand back a result object.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
class EsdeImportBusyException implements Exception {
  const EsdeImportBusyException();

  @override
  String toString() => 'EsdeImportBusyException(an import is already running)';
}

/// What [EsdeImportService.resetDetailed] removed, so the settings screen can
/// say how many SAF mirror directories went along with the metadata rows.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
class EsdeResetResult {
  /// Metadata rows the import created that reset deleted.
  final int metadataRowsDeleted;

  /// `esde_media_root` values cleared.
  final int mediaRootsCleared;

  /// Mirror directories under `<user data>/imported_media/` deleted.
  final int mirrorsRemoved;

  const EsdeResetResult({
    this.metadataRowsDeleted = 0,
    this.mediaRootsCleared = 0,
    this.mirrorsRemoved = 0,
  });

  @override
  String toString() =>
      'EsdeResetResult(rows=$metadataRowsDeleted roots=$mediaRootsCleared '
      'mirrors=$mirrorsRemoved)';
}

/// Summary of an ES-DE import run, surfaced to the settings UI.
class EsdeImportResult {
  /// Number of ES-DE system folders matched to a NeoStation system.
  final int systemsMatched;

  /// Number of ES-DE system folders that could not be mapped and were skipped.
  final int systemsUnmatched;

  /// Number of ES-DE system folders that mapped to a NeoStation system but
  /// whose `gamelist.xml` could not be read or parsed (skipped).
  final int systemsSkipped;

  /// Number of `<game>` entries whose metadata was created or filled.
  final int gamesImported;

  /// Number of `<game>` entries with no matching scanned ROM (skipped).
  final int gamesUnmatched;

  /// Number of games whose favorite / play-stat fields were updated.
  final int statsUpdated;

  /// Whether a `gamelists/` directory was found under the picked folder. When
  /// false, the selected folder is almost certainly not an ES-DE installation.
  /// Only meaningful for [GamelistSourceMode.esdeRoot]; in-folder runs report
  /// [noInFolderGamelistsFound] instead.
  final bool gamelistsDirFound;

  /// Which discovery mode produced this result.
  final GamelistSourceMode mode;

  /// Number of system folders holding a `gamelist.xml`, before any matching.
  final int systemsFound;

  /// In-folder mode only: configured ROM folders that are SAF `content://`
  /// trees with no readable real path. They are skipped, never fatal.
  final int foldersSkippedSaf;

  /// Number of systems with artwork but no `gamelist.xml` whose media
  /// location was recorded so the read-time fallback can use it.
  final int mediaOnlyLinked;

  /// In-folder mode only: no configured ROM folder held any
  /// `<system>/gamelist.xml`. Distinct from [gamelistsDirFound], which is
  /// the ES-DE "not an ES-DE folder" outcome.
  final bool noInFolderGamelistsFound;

  /// In-folder mode only: one entry per configured ROM folder saying which
  /// path it took (real, SAF, or skipped). Empty for ES-DE root runs.
  final List<EsdeImportFolderOutcome> folderOutcomes;

  /// In-folder mode only: systems whose `gamelist.xml` was read over SAF
  /// (a subset of [systemsMatched]). These get no media root until the SAF
  /// media mirror records one.
  final int systemsImportedViaSaf;

  /// In-folder mode only: SAF subfolders that resolve to a system and carry a
  /// mapped media category folder but no `gamelist.xml`, left unlinked.
  /// Since the media mirror exists such folders are mirrored and counted in
  /// [mediaOnlyLinked] when they hold files, so this stays 0; kept so
  /// existing readers of the result keep compiling.
  final int safMediaOnlyPending;

  /// In-folder mode only: media files copied out of SAF category folders
  /// into the mirror this run.
  final int safFilesCopied;

  /// In-folder mode only: mirror files left alone because their size already
  /// matched the SAF listing.
  final int safFilesSkippedUnchanged;

  /// In-folder mode only: media files that could not be mirrored (each one
  /// is logged with its URI).
  final int safFilesFailed;

  /// In-folder mode only: bytes written into the mirror this run.
  final int safBytesCopied;

  /// In-folder mode only: SAF systems whose mirror directory holds at least
  /// one file after the run and was recorded as their media root.
  final int safSystemsMirrored;

  /// In-folder mode only: at least one system's mirror was refused because
  /// the pending copy did not fit in free space. Metadata is still imported.
  final bool safBudgetRefused;

  /// In-folder mode only: bytes the refused mirrors needed, summed.
  final int safBudgetRequiredBytes;

  /// In-folder mode only: free bytes on the mirror volume when the first
  /// refusal happened; null when no refusal occurred.
  final int? safBudgetAvailableBytes;

  /// In-folder mode only: SAF system subfolders left out because their own
  /// listing failed (lost grant, provider error) while the ROM folder's root
  /// listing succeeded. Each one is logged with its URI.
  final int safSystemsListingFailed;

  /// The run was stopped by the caller's `shouldStop` between files; the
  /// work done so far is kept and the rest was not attempted.
  final bool cancelled;

  /// The run never started because another import was in progress.
  final bool refusedAlreadyRunning;

  const EsdeImportResult({
    this.systemsMatched = 0,
    this.systemsUnmatched = 0,
    this.systemsSkipped = 0,
    this.gamesImported = 0,
    this.gamesUnmatched = 0,
    this.statsUpdated = 0,
    this.gamelistsDirFound = true,
    this.mode = GamelistSourceMode.esdeRoot,
    this.systemsFound = 0,
    this.foldersSkippedSaf = 0,
    this.mediaOnlyLinked = 0,
    this.noInFolderGamelistsFound = false,
    this.folderOutcomes = const [],
    this.systemsImportedViaSaf = 0,
    this.safMediaOnlyPending = 0,
    this.safFilesCopied = 0,
    this.safFilesSkippedUnchanged = 0,
    this.safFilesFailed = 0,
    this.safBytesCopied = 0,
    this.safSystemsMirrored = 0,
    this.safBudgetRefused = false,
    this.safBudgetRequiredBytes = 0,
    this.safBudgetAvailableBytes,
    this.safSystemsListingFailed = 0,
    this.cancelled = false,
    this.refusedAlreadyRunning = false,
  });

  EsdeImportResult _add({
    int systemsMatched = 0,
    int systemsUnmatched = 0,
    int systemsSkipped = 0,
    int gamesImported = 0,
    int gamesUnmatched = 0,
    int statsUpdated = 0,
    int systemsFound = 0,
    int foldersSkippedSaf = 0,
    int mediaOnlyLinked = 0,
    bool? noInFolderGamelistsFound,
    List<EsdeImportFolderOutcome> folderOutcomes = const [],
    int systemsImportedViaSaf = 0,
    int safMediaOnlyPending = 0,
    int safFilesCopied = 0,
    int safFilesSkippedUnchanged = 0,
    int safFilesFailed = 0,
    int safBytesCopied = 0,
    int safSystemsMirrored = 0,
    bool safBudgetRefused = false,
    int safBudgetRequiredBytes = 0,
    int? safBudgetAvailableBytes,
    int safSystemsListingFailed = 0,
    bool cancelled = false,
  }) {
    return EsdeImportResult(
      systemsMatched: this.systemsMatched + systemsMatched,
      systemsUnmatched: this.systemsUnmatched + systemsUnmatched,
      systemsSkipped: this.systemsSkipped + systemsSkipped,
      gamesImported: this.gamesImported + gamesImported,
      gamesUnmatched: this.gamesUnmatched + gamesUnmatched,
      statsUpdated: this.statsUpdated + statsUpdated,
      gamelistsDirFound: gamelistsDirFound,
      mode: mode,
      systemsFound: this.systemsFound + systemsFound,
      foldersSkippedSaf: this.foldersSkippedSaf + foldersSkippedSaf,
      mediaOnlyLinked: this.mediaOnlyLinked + mediaOnlyLinked,
      noInFolderGamelistsFound:
          noInFolderGamelistsFound ?? this.noInFolderGamelistsFound,
      folderOutcomes: folderOutcomes.isEmpty
          ? this.folderOutcomes
          : List.unmodifiable([...this.folderOutcomes, ...folderOutcomes]),
      systemsImportedViaSaf: this.systemsImportedViaSaf + systemsImportedViaSaf,
      safMediaOnlyPending: this.safMediaOnlyPending + safMediaOnlyPending,
      safFilesCopied: this.safFilesCopied + safFilesCopied,
      safFilesSkippedUnchanged:
          this.safFilesSkippedUnchanged + safFilesSkippedUnchanged,
      safFilesFailed: this.safFilesFailed + safFilesFailed,
      safBytesCopied: this.safBytesCopied + safBytesCopied,
      safSystemsMirrored: this.safSystemsMirrored + safSystemsMirrored,
      safBudgetRefused: this.safBudgetRefused || safBudgetRefused,
      safBudgetRequiredBytes:
          this.safBudgetRequiredBytes + safBudgetRequiredBytes,
      // The budget is checked per system with a fresh free-space reading, so
      // earlier systems may have copied before a later one was refused; the
      // first refusal's reading is the one worth showing, and the required
      // bytes are summed across refused systems.
      safBudgetAvailableBytes:
          this.safBudgetAvailableBytes ?? safBudgetAvailableBytes,
      safSystemsListingFailed:
          this.safSystemsListingFailed + safSystemsListingFailed,
      cancelled: this.cancelled || cancelled,
      refusedAlreadyRunning: refusedAlreadyRunning,
    );
  }

  /// Folds one system's mirror [summary] into the SAF tallies.
  EsdeImportResult _addMirror(
    SafMirrorSummary summary, {
    bool recorded = false,
  }) {
    return _add(
      safFilesCopied: summary.filesCopied,
      safFilesSkippedUnchanged: summary.filesSkippedUnchanged,
      safFilesFailed: summary.filesFailed,
      safBytesCopied: summary.bytesCopied,
      safSystemsMirrored: recorded ? 1 : 0,
      safBudgetRefused: summary.budgetRefused,
      safBudgetRequiredBytes: summary.budgetRefused ? summary.requiredBytes : 0,
      safBudgetAvailableBytes: summary.budgetRefused
          ? summary.availableBytes
          : null,
      cancelled: summary.cancelled,
    );
  }
}

/// A SAF platform subfolder with mapped media category folders but no
/// `gamelist.xml`: nothing to parse, but its artwork is worth mirroring.
class _SafMediaOnlyCandidate {
  final String name;
  final String uri;

  /// Lowercased category name → `content://` folder URI, from the one
  /// listing discovery made of the subfolder.
  final Map<String, String> categoryDirs;

  const _SafMediaOnlyCandidate({
    required this.name,
    required this.uri,
    required this.categoryDirs,
  });
}

/// How a gamelist was discovered, which decides where its media lives and
/// which `user_system_settings` column records that location.
enum GamelistSourceMode {
  /// `<root>/gamelists/<system>/gamelist.xml` with media under one global
  /// `downloaded_media/<system>/` tree; recorded as `esde_media_dir`.
  esdeRoot,

  /// `<romfolder>/<system>/gamelist.xml` with media in sibling category
  /// folders of the platform folder; recorded as `esde_media_root`.
  inFolder,

  /// The in-folder layout inside a SAF `content://` tree with no readable
  /// real path: `gamelist.xml` is read as bytes over SAF and the category
  /// folders are known only as URIs. No media root is recorded until the
  /// media mirror provides a real directory.
  saf,
}

/// One importable gamelist and the layout it was found in. Discovery (ES-DE
/// root, in-folder, or SAF) produces these; the shared importer core consumes
/// only them, so parsing, matching, merge, and provenance know nothing about
/// layout. A source is backed by either a filesystem [gamelistFile] or a SAF
/// [gamelistUri]; the core reads whichever is set and parses the same bytes.
// Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "In-Folder Gamelist Discovery"
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Gamelist Read Over SAF"
class GamelistSource {
  /// The `gamelist.xml` to parse; null for a SAF source.
  final File? gamelistFile;

  /// SAF mode: the `content://` document URI of `gamelist.xml`; null for a
  /// filesystem source.
  final String? gamelistUri;

  /// ES-DE mode: the global media root (`downloaded_media` or the
  /// `MediaDirectory` override). In-folder mode: the absolute platform folder.
  /// SAF mode: the platform folder's `content://` URI.
  final String mediaRoot;

  /// The system folder name as found on disk (`snes`, `segacd`, …); resolved
  /// to a NeoStation system through the folder-alias table.
  final String systemFolderName;

  final GamelistSourceMode mode;

  /// SAF mode: mapped media category folders seen in the platform folder's
  /// one listing, lowercased category name → `content://` URI. Empty for
  /// filesystem sources, which stat category folders on demand.
  final Map<String, String> safCategoryDirs;

  /// SAF mode: the real directory the media mirror copies this system's
  /// category folders into (`<user data>/imported_media/<system folder>`),
  /// or null when no mirror root could be resolved for the run.
  final String? safMirrorDir;

  const GamelistSource({
    this.gamelistFile,
    this.gamelistUri,
    required this.mediaRoot,
    required this.systemFolderName,
    required this.mode,
    this.safCategoryDirs = const {},
    this.safMirrorDir,
  }) : assert(
         (gamelistFile == null) != (gamelistUri == null),
         'exactly one of gamelistFile / gamelistUri must be set',
       );

  /// A gamelist discovered inside a SAF tree: [gamelistUri] is the document
  /// to read, [folderUri] the platform folder it sits in.
  const GamelistSource.saf({
    required String this.gamelistUri,
    required String folderUri,
    required this.systemFolderName,
    this.safCategoryDirs = const {},
    this.safMirrorDir,
  }) : gamelistFile = null,
       mediaRoot = folderUri,
       mode = GamelistSourceMode.saf;

  /// Where the gamelist lives, for logging: a path or a `content://` URI.
  String get location => gamelistFile?.path ?? gamelistUri!;

  /// Directory holding this system's `<category>/` media folders. For a SAF
  /// source this is the mirror directory, so the duplicate-entry media probe
  /// sees whatever an earlier mirror run copied; without a mirror root it
  /// falls back to the `content://` URI, which `dart:io` cannot stat, and
  /// the probe keeps the first entry.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
  String get systemMediaDir => switch (mode) {
    GamelistSourceMode.esdeRoot => path.join(mediaRoot, systemFolderName),
    GamelistSourceMode.inFolder => mediaRoot,
    GamelistSourceMode.saf => safMirrorDir ?? mediaRoot,
  };
}

/// Imports metadata and wires up fallback artwork from an ES-DE
/// (EmulationStation Desktop Edition) installation.
///
/// Metadata is parsed from `gamelists/<system>/gamelist.xml` and merged into
/// NeoStation's `user_screenscraper_metadata` on a fill-gaps-only basis (never
/// clobbering existing NeoStation-scraped values). Artwork is NOT copied: the
/// ES-DE folder path plus a per-system `esde_media_dir` are persisted so
/// [FileProvider] can resolve ES-DE's media files as read-time fallback
/// (a later NeoStation scrape lands in NeoStation's own media folder and takes
/// precedence automatically). Which folder that media sits in is not assumed:
/// see [resolveMediaRoot].
class EsdeImportService {
  static final _log = LoggerService.instance;

  // ── Single-instance guard ───────────────────────────────────────────────
  // One import (or reset) at a time: a second start is refused with a named
  // outcome rather than racing the first on the same metadata rows and
  // mirror files. Shared by every entry point.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
  static bool _running = false;

  /// Whether an import or reset is in progress.
  static bool get isRunning => _running;

  /// Runs [body] under the guard, or returns [refused] when busy.
  static Future<T> _guarded<T>(
    String entryPoint,
    Future<T> Function() body, {
    required T Function() refused,
  }) async {
    if (_running) {
      _log.w('ES-DE import: $entryPoint refused, another run is in progress');
      return refused();
    }
    _running = true;
    try {
      return await body();
    } finally {
      _running = false;
    }
  }

  /// Runs the import against [esdeRoot] (the ES-DE application folder that
  /// contains `gamelists/`, `settings/`, and by default `downloaded_media/`).
  ///
  /// [onProgress] is invoked as `(fraction 0..1, currentSystemLabel)`.
  /// Returns a result flagged [EsdeImportResult.refusedAlreadyRunning] when
  /// another import or reset is in progress.
  static Future<EsdeImportResult> import(
    String esdeRoot, {
    void Function(double progress, String label)? onProgress,
  }) => _guarded(
    'import',
    () => _importEsdeRoot(esdeRoot, onProgress: onProgress),
    refused: () => const EsdeImportResult(refusedAlreadyRunning: true),
  );

  static Future<EsdeImportResult> _importEsdeRoot(
    String esdeRoot, {
    void Function(double progress, String label)? onProgress,
  }) async {
    var result = const EsdeImportResult();
    _mediaIndexCache.clear();
    final mediaRoot = resolveMediaRoot(esdeRoot);

    final gamelistsDir = Directory(path.join(esdeRoot, 'gamelists'));
    if (!gamelistsDir.existsSync()) {
      _log.w('ES-DE import: no gamelists/ dir at $esdeRoot');
      return const EsdeImportResult(gamelistsDirFound: false);
    }

    final systemDirs = gamelistsDir
        .listSync()
        .whereType<Directory>()
        .where((d) => File(path.join(d.path, 'gamelist.xml')).existsSync())
        .toList();

    result = result._add(systemsFound: systemDirs.length);
    final importedDirs = <String>{};
    final preferredLang = await ScraperRepository.getPreferredLanguage();
    final descColumn = _descriptionColumn(preferredLang);

    for (var i = 0; i < systemDirs.length; i++) {
      final systemDir = systemDirs[i];
      final esdeDirName = path.basename(systemDir.path);
      onProgress?.call(i / systemDirs.length, esdeDirName);
      final source = GamelistSource(
        gamelistFile: File(path.join(systemDir.path, 'gamelist.xml')),
        mediaRoot: mediaRoot,
        systemFolderName: esdeDirName,
        mode: GamelistSourceMode.esdeRoot,
      );

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) {
        _log.i(
          'ES-DE import: no NeoStation system for "$esdeDirName", skipping',
        );
        result = result._add(systemsUnmatched: 1);
        continue;
      }

      final appSystemId = system['app_system_id']!;

      // systemsMatched / systemsSkipped are tallied inside _importSystem so a
      // system with an unreadable gamelist.xml counts as skipped, not matched.
      final matchedBefore = result.systemsMatched;
      result = await _importSystem(
        source: source,
        appSystemId: appSystemId,
        descColumn: descColumn,
        accumulator: result,
        // Big systems can hold thousands of entries, so report progress
        // within the system too rather than freezing the bar on its name.
        onGameProgress: onProgress == null
            ? null
            : (fraction) =>
                  onProgress((i + fraction) / systemDirs.length, esdeDirName),
      );

      // Only wire up the read-time media fallback for systems that actually
      // imported (a corrupt/unparseable gamelist.xml is skipped, not matched);
      // otherwise we'd record an esde_media_dir with no matching metadata rows.
      if (result.systemsMatched > matchedBefore) {
        await _recordMediaLocation(source, appSystemId);
        importedDirs.add(esdeDirName.toLowerCase());
      }
    }

    final linked = await _linkMediaOnlySystems(mediaRoot, importedDirs);
    result = result._add(mediaOnlyLinked: linked);

    onProgress?.call(1.0, '');
    _log.i(
      'ES-DE import done: systems matched=${result.systemsMatched} '
      'unmatched=${result.systemsUnmatched} skipped=${result.systemsSkipped}, '
      'games imported=${result.gamesImported} noRomMatch=${result.gamesUnmatched}, '
      'stats updated=${result.statsUpdated}',
    );
    return result;
  }

  /// Runs the in-folder import over the configured [romFolders]: every
  /// immediate `<system>/` subfolder holding a `gamelist.xml` is imported
  /// through the same core as the ES-DE mode, with the platform folder itself
  /// recorded as the system's media root. Enumeration is the ROM scanner's own
  /// listing, and subfolder names resolve through the same folder-alias table,
  /// so the importer sees exactly the system set the library does.
  ///
  /// A ROM folder that resolves to a readable real filesystem path is read
  /// exactly as before. A SAF `content://` folder with no readable real path
  /// is discovered over SAF instead: its subfolders are listed once each,
  /// `gamelist.xml` bytes are read through SAF into the same parser, and its
  /// mapped media category folders are mirrored into
  /// `<user data>/imported_media/<system>/`, which is then recorded as the
  /// system's media root. Only a folder that cannot be listed at all (lost
  /// grant, SAF unavailable) is counted in
  /// [EsdeImportResult.foldersSkippedSaf], logged, and skipped — never fatal.
  ///
  /// [onProgress] is invoked as `(fraction 0..1, currentSystemLabel)`.
  /// [onMirrorProgress] is invoked per mirrored file as
  /// `(systemFolder, copied, total)`. [shouldStop] is polled between mirrored
  /// files and between systems; when it answers true the run stops, keeps
  /// what it has done, and reports [EsdeImportResult.cancelled]. Returns a
  /// result flagged [EsdeImportResult.refusedAlreadyRunning] when another
  /// import or reset is in progress.
  // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "In-Folder Gamelist Discovery"
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "SAF Discovery"
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
  static Future<EsdeImportResult> importInFolder(
    List<String> romFolders, {
    void Function(double progress, String label)? onProgress,
    void Function(String systemFolder, int copied, int total)? onMirrorProgress,
    bool Function()? shouldStop,
  }) => _guarded(
    'importInFolder',
    () => _importInFolder(
      romFolders,
      onProgress: onProgress,
      onMirrorProgress: onMirrorProgress,
      shouldStop: shouldStop ?? _neverStop,
    ),
    refused: () => const EsdeImportResult(
      mode: GamelistSourceMode.inFolder,
      refusedAlreadyRunning: true,
    ),
  );

  static bool _neverStop() => false;

  static Future<EsdeImportResult> _importInFolder(
    List<String> romFolders, {
    required void Function(double progress, String label)? onProgress,
    required void Function(String systemFolder, int copied, int total)?
    onMirrorProgress,
    required bool Function() shouldStop,
  }) async {
    var result = const EsdeImportResult(mode: GamelistSourceMode.inFolder);
    _mediaIndexCache.clear();

    // Real path first: a folder SPEC-0002 can read is imported per SPEC-0002
    // with no SAF involvement; only folders it would have skipped go to SAF.
    // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Real-Path Scope"
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Real-Path Precedence"
    final realFolders = <String>[];
    final safFolders = <String>[];
    for (final folder in romFolders) {
      final real = await _resolveRomFolderPath(folder);
      if (real == null) {
        _log.i(
          'in-folder import: ROM folder has no readable real path, '
          'discovering over SAF uri=$folder',
        );
        if (!safFolders.contains(folder)) safFolders.add(folder);
        continue;
      }
      result = result._add(
        folderOutcomes: [
          EsdeImportFolderOutcome(
            folder: folder,
            kind: EsdeImportPathKind.real,
          ),
        ],
      );
      if (!realFolders.contains(real)) realFolders.add(real);
    }

    final subdirsByFolder = realFolders.isEmpty
        ? const <String, Map<String, String>>{}
        : await GameRepository.getExistingSubdirectories(realFolders);

    // Split the scanner's listing into gamelist-bearing subfolders (imported
    // through the core) and the rest (candidates for media-only linking).
    final sources = <GamelistSource>[];
    final mediaOnlyCandidates = <({String name, String dir})>[];
    for (final romFolder in realFolders) {
      final subdirs = subdirsByFolder[romFolder] ?? const <String, String>{};
      final names = subdirs.keys.toList()..sort();
      for (final name in names) {
        final dir = subdirs[name]!;
        final gamelistFile = File(path.join(dir, 'gamelist.xml'));
        if (gamelistFile.existsSync()) {
          sources.add(
            GamelistSource(
              gamelistFile: gamelistFile,
              mediaRoot: dir,
              systemFolderName: path.basename(dir),
              mode: GamelistSourceMode.inFolder,
            ),
          );
        } else {
          mediaOnlyCandidates.add((name: path.basename(dir), dir: dir));
        }
      }
    }

    // SAF branch: the same shape as above, but every fact comes from one
    // listing per folder because there is no per-document exists primitive.
    // A folder that cannot be listed keeps the SPEC-0002 skipped outcome.
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "SAF Discovery"
    // The mirror root is resolved once, before discovery, so every SAF
    // source knows its mirror directory before its gamelist is imported and
    // the duplicate-entry probe can look at an earlier run's copies.
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
    final mirrorRoot = safFolders.isEmpty ? null : await _resolveMirrorRoot();
    final safMediaOnlyCandidates = <_SafMediaOnlyCandidate>[];
    for (final folderUri in safFolders) {
      final ({
        List<GamelistSource> sources,
        List<_SafMediaOnlyCandidate> mediaOnly,
        int listingFailed,
      })
      discovered;
      try {
        discovered = await _discoverSafFolder(folderUri, mirrorRoot);
      } on EsdeSafAccessException catch (e) {
        _log.w(
          'in-folder import: skipped ROM folder uri=${e.uri} '
          'reason=${e.reason}',
        );
        result = result._add(
          foldersSkippedSaf: 1,
          folderOutcomes: [
            EsdeImportFolderOutcome(
              folder: folderUri,
              kind: EsdeImportPathKind.skippedSaf,
            ),
          ],
        );
        continue;
      } catch (e) {
        // A listing error the SAF service did not classify: the folder is
        // unreadable for this run, which is the skipped outcome, not fatal.
        _log.e(
          'in-folder import: skipped ROM folder uri=$folderUri '
          'reason=SAF listing failed: $e',
        );
        result = result._add(
          foldersSkippedSaf: 1,
          folderOutcomes: [
            EsdeImportFolderOutcome(
              folder: folderUri,
              kind: EsdeImportPathKind.skippedSaf,
            ),
          ],
        );
        continue;
      }
      sources.addAll(discovered.sources);
      safMediaOnlyCandidates.addAll(discovered.mediaOnly);
      result = result._add(
        safSystemsListingFailed: discovered.listingFailed,
        folderOutcomes: [
          EsdeImportFolderOutcome(
            folder: folderUri,
            kind: EsdeImportPathKind.saf,
          ),
        ],
      );
    }

    result = result._add(
      systemsFound: sources.length,
      noInFolderGamelistsFound: sources.isEmpty,
    );
    if (sources.isEmpty) {
      _log.w(
        'in-folder import: no <system>/gamelist.xml found '
        'folders=${realFolders.length} safFolders=${safFolders.length} '
        'skippedSaf=${result.foldersSkippedSaf}',
      );
    }

    final preferredLang = await ScraperRepository.getPreferredLanguage();
    final descColumn = _descriptionColumn(preferredLang);
    final importedSystemIds = <String>{};

    for (var i = 0; i < sources.length; i++) {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
      if (shouldStop()) {
        result = result._add(cancelled: true);
        break;
      }
      final source = sources[i];
      final folderName = source.systemFolderName;
      onProgress?.call(i / sources.length, folderName);

      final system = await ScraperRepository.resolveSystemByFolderName(
        folderName,
      );
      if (system == null) {
        _log.i(
          'in-folder import: no NeoStation system for folder=$folderName '
          'dir=${source.mediaRoot}, skipping',
        );
        result = result._add(systemsUnmatched: 1);
        continue;
      }
      final appSystemId = system['app_system_id']!;

      // Tallied inside _importSystem so an unparseable gamelist.xml counts as
      // skipped, not matched, and gets no media root recorded.
      final matchedBefore = result.systemsMatched;
      result = await _importSystem(
        source: source,
        appSystemId: appSystemId,
        descColumn: descColumn,
        accumulator: result,
        onGameProgress: onProgress == null
            ? null
            : (fraction) =>
                  onProgress((i + fraction) / sources.length, folderName),
      );
      if (result.systemsMatched > matchedBefore) {
        await _recordMediaLocation(source, appSystemId);
        importedSystemIds.add(appSystemId);
        if (source.mode == GamelistSourceMode.saf) {
          result = result._add(systemsImportedViaSaf: 1);
          // Metadata is in; now mirror the artwork and, once the mirror
          // holds a file, point the system's media root at it.
          // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Media Mirror"
          result = await _mirrorSafSystem(
            mirrorRoot: mirrorRoot,
            systemFolder: folderName,
            categoryDirs: source.safCategoryDirs,
            appSystemId: appSystemId,
            accumulator: result,
            onMirrorProgress: onMirrorProgress,
            shouldStop: shouldStop,
          );
        }
      }
    }

    final linked = await _linkInFolderMediaOnlySystems(
      mediaOnlyCandidates,
      importedSystemIds,
    );
    result = result._add(mediaOnlyLinked: linked);

    if (!result.cancelled) {
      result = await _mirrorSafMediaOnlySystems(
        safMediaOnlyCandidates,
        importedSystemIds,
        mirrorRoot: mirrorRoot,
        accumulator: result,
        onMirrorProgress: onMirrorProgress,
        shouldStop: shouldStop,
      );
    }

    onProgress?.call(1.0, '');
    _log.i(
      'in-folder import done: folders=${realFolders.length} '
      'safFolders=${safFolders.length} '
      'skippedSaf=${result.foldersSkippedSaf} '
      'systems found=${result.systemsFound} matched=${result.systemsMatched} '
      'viaSaf=${result.systemsImportedViaSaf} '
      'unmatched=${result.systemsUnmatched} skipped=${result.systemsSkipped}, '
      'games imported=${result.gamesImported} noRomMatch=${result.gamesUnmatched}, '
      'stats updated=${result.statsUpdated} mediaOnlyLinked=${result.mediaOnlyLinked} '
      'safMirrored=${result.safSystemsMirrored} '
      'safCopied=${result.safFilesCopied} '
      'safSkipped=${result.safFilesSkippedUnchanged} '
      'safFailed=${result.safFilesFailed} safBytes=${result.safBytesCopied} '
      'budgetRefused=${result.safBudgetRefused} cancelled=${result.cancelled}',
    );
    return result;
  }

  // ── SAF media mirror ────────────────────────────────────────────────────

  /// `<user data>/imported_media`, the root every SAF mirror lands under.
  /// Tests point this at a temp directory.
  @visibleForTesting
  static String? mirrorRootOverride;

  /// Reads one SAF byte range; stands in for [SafDirectoryService.readRange].
  @visibleForTesting
  static Future<Uint8List?> Function(String uri, int offset, int length)?
  safReadRangeOverride;

  /// Free bytes on the volume holding a path; stands in for
  /// [StorageSpaceService.freeSpaceBytes].
  @visibleForTesting
  static Future<int?> Function(String path)? freeSpaceBytesOverride;

  /// Directory name under the user-data folder that holds SAF mirrors.
  static const String importedMediaDirName = 'imported_media';

  /// The mirror root for this run, or null when the user-data path cannot be
  /// resolved (storage not ready): metadata still imports, nothing mirrors.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
  static Future<String?> _resolveMirrorRoot() async {
    final override = mirrorRootOverride;
    if (override != null) return override;
    try {
      final userData = await ConfigService.getUserDataPath();
      return path.join(userData, importedMediaDirName);
    } catch (e) {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
      _log.e(
        'in-folder import: cannot resolve the user-data path for the SAF '
        'media mirror, metadata only this run: $e',
      );
      return null;
    }
  }

  static Future<Uint8List?> _safReadRange(String uri, int offset, int length) {
    final override = safReadRangeOverride;
    if (override != null) return override(uri, offset, length);
    if (!Platform.isAndroid) {
      throw EsdeSafAccessException(uri, 'SAF is unavailable on this platform');
    }
    return SafDirectoryService.readRange(uri, offset, length);
  }

  static Future<int?> _freeSpaceBytes(String dir) {
    final override = freeSpaceBytesOverride;
    if (override != null) return override(dir);
    return StorageSpaceService.freeSpaceBytes(dir);
  }

  /// Mirrors one SAF system's category folders under [mirrorRoot] and, when
  /// the mirror directory holds at least one file afterwards (copied now or
  /// by an earlier run), records it as the system's `esde_media_root`.
  /// Returns [accumulator] with the mirror tallies folded in, and with
  /// [EsdeImportResult.cancelled] set if the mirror was stopped.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Media Mirror"
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
  static Future<EsdeImportResult> _mirrorSafSystem({
    required String? mirrorRoot,
    required String systemFolder,
    required Map<String, String> categoryDirs,
    required String appSystemId,
    required EsdeImportResult accumulator,
    required void Function(String systemFolder, int copied, int total)?
    onMirrorProgress,
    required bool Function() shouldStop,
  }) async {
    if (mirrorRoot == null) return accumulator;
    final mirror = SafMediaMirror(
      listFiles: _safListFiles,
      readRange: _safReadRange,
      freeSpaceBytes: _freeSpaceBytes,
      mirrorRoot: mirrorRoot,
      shouldStop: shouldStop,
      onProgress: onMirrorProgress == null
          ? null
          : (copied, total, _) => onMirrorProgress(systemFolder, copied, total),
    );
    final summary = await mirror.run(systemFolder, categoryDirs);

    var recorded = false;
    if (summary.filesPresent > 0) {
      // Written through the repository's parameterized upsert.
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Database Operation Standards"
      recorded = await ScraperRepository.recordEsdeMediaRoot(
        appSystemId,
        summary.mirrorDir,
      );
      if (!recorded) {
        _log.w(
          'in-folder import: mirror media root not recorded '
          'system=$appSystemId root=${summary.mirrorDir}',
        );
      }
    } else {
      _log.i(
        'in-folder import: SAF mirror holds no files, no media root recorded '
        'system=$appSystemId folder=$systemFolder dir=${summary.mirrorDir}',
      );
    }
    return accumulator._addMirror(summary, recorded: recorded);
  }

  /// SAF counterpart of [_linkInFolderMediaOnlySystems]: a SAF platform
  /// subfolder with mapped category folders but no gamelist is mirrored, and
  /// linked to its system when the mirror ends up holding a file. The
  /// listing the mirror makes is the file check, so an empty category folder
  /// never acquires a root. Systems already imported this run are left alone
  /// so a second folder's `snes/` cannot clobber the first one's root.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Media Mirror"
  static Future<EsdeImportResult> _mirrorSafMediaOnlySystems(
    List<_SafMediaOnlyCandidate> candidates,
    Set<String> importedSystemIds, {
    required String? mirrorRoot,
    required EsdeImportResult accumulator,
    required void Function(String systemFolder, int copied, int total)?
    onMirrorProgress,
    required bool Function() shouldStop,
  }) async {
    var result = accumulator;
    if (mirrorRoot == null) return result;
    for (final candidate in candidates) {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
      if (shouldStop()) return result._add(cancelled: true);
      final system = await ScraperRepository.resolveSystemByFolderName(
        candidate.name,
      );
      if (system == null) continue;
      final appSystemId = system['app_system_id']!;
      if (importedSystemIds.contains(appSystemId)) continue;

      final mirroredBefore = result.safSystemsMirrored;
      result = await _mirrorSafSystem(
        mirrorRoot: mirrorRoot,
        systemFolder: candidate.name,
        categoryDirs: candidate.categoryDirs,
        appSystemId: appSystemId,
        accumulator: result,
        onMirrorProgress: onMirrorProgress,
        shouldStop: shouldStop,
      );
      if (result.safSystemsMirrored > mirroredBefore) {
        importedSystemIds.add(appSystemId);
        result = result._add(mediaOnlyLinked: 1);
        _log.i(
          'in-folder import: linked art-only SAF system '
          'folder=${candidate.name} uri=${candidate.uri} '
          'to system=$appSystemId',
        );
      }
      if (result.cancelled) return result;
    }
    return result;
  }

  // ── SAF operations ──────────────────────────────────────────────────────
  // The importer touches the SAF tree through these three wrappers only, all
  // read-only, so a test can substitute a recording fake with no platform
  // channel and prove nothing else was ever called.

  /// Lists one SAF directory; stands in for [SafDirectoryService.listFiles].
  @visibleForTesting
  static Future<List<Map<String, dynamic>>> Function(String uri)?
  safListFilesOverride;

  /// Reads one SAF document; stands in for [SafDirectoryService.readFile].
  @visibleForTesting
  static Future<Uint8List?> Function(String uri)? safReadFileOverride;

  /// Checks a persisted grant; stands in for
  /// [SafDirectoryService.hasPermission].
  @visibleForTesting
  static Future<bool> Function(String uri)? safHasPermissionOverride;

  static Future<List<Map<String, dynamic>>> _safListFiles(String uri) {
    final override = safListFilesOverride;
    if (override != null) return override(uri);
    if (!Platform.isAndroid) {
      // Off Android the service answers every listing with an empty list,
      // which would read as an empty tree rather than the truth: this
      // platform cannot open a content:// tree at all.
      throw EsdeSafAccessException(uri, 'SAF is unavailable on this platform');
    }
    return SafDirectoryService.listFiles(uri);
  }

  static Future<Uint8List?> _safReadFile(String uri) {
    final override = safReadFileOverride;
    if (override != null) return override(uri);
    if (!Platform.isAndroid) {
      throw EsdeSafAccessException(uri, 'SAF is unavailable on this platform');
    }
    return SafDirectoryService.readFile(uri);
  }

  static Future<bool> _safHasPermission(String uri) {
    final override = safHasPermissionOverride;
    if (override != null) return override(uri);
    return SafDirectoryService.hasPermission(uri);
  }

  /// Discovers the importable systems inside one SAF ROM folder [folderUri]:
  /// one listing of the root gives the system subfolders, one listing of each
  /// subfolder tells whether it holds `gamelist.xml` and which mapped media
  /// category folders sit beside it. Never lists deeper and never probes a
  /// single document, because SAF has no cheap exists check.
  ///
  /// Throws [EsdeSafAccessException] when the root itself cannot be read (no
  /// persisted grant, listing failure) so the caller can count the folder as
  /// skipped. A subfolder that fails to list is logged, counted in
  /// `listingFailed`, and left out; the other subfolders still import.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "SAF Discovery"
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
  static Future<
    ({
      List<GamelistSource> sources,
      List<_SafMediaOnlyCandidate> mediaOnly,
      int listingFailed,
    })
  >
  _discoverSafFolder(String folderUri, String? mirrorRoot) async {
    if (!await _safHasPermission(folderUri)) {
      throw EsdeSafAccessException(folderUri, 'no persisted SAF grant');
    }

    // The same filter the ROM scanner's SAF listing applies: immediate
    // directories, keyed by lowercased name, in a stable order.
    final rootChildren = await _safListFiles(folderUri);
    final subfolders = <({String name, String uri})>[];
    for (final child in rootChildren) {
      if (child['isDirectory'] != true) continue;
      final name = child['name']?.toString() ?? '';
      final uri = child['uri']?.toString() ?? '';
      if (name.isEmpty || uri.isEmpty) continue;
      subfolders.add((name: name, uri: uri));
    }
    subfolders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final sources = <GamelistSource>[];
    final mediaOnly = <_SafMediaOnlyCandidate>[];
    var listingFailed = 0;
    for (final sub in subfolders) {
      List<Map<String, dynamic>> children;
      try {
        children = await _safListFiles(sub.uri);
      } catch (e) {
        _log.w(
          'in-folder import: cannot list SAF system folder '
          'folder=${sub.name} uri=${sub.uri} error=$e',
        );
        listingFailed++;
        continue;
      }

      String? gamelistUri;
      final categoryDirs = <String, String>{};
      for (final child in children) {
        final name = child['name']?.toString() ?? '';
        final uri = child['uri']?.toString() ?? '';
        if (name.isEmpty || uri.isEmpty) continue;
        final lower = name.toLowerCase();
        if (child['isDirectory'] == true) {
          if (_inFolderMediaCategories.contains(lower)) {
            categoryDirs.putIfAbsent(lower, () => uri);
          }
        } else if (lower == 'gamelist.xml') {
          gamelistUri ??= uri;
        }
      }

      if (gamelistUri != null) {
        sources.add(
          GamelistSource.saf(
            gamelistUri: gamelistUri,
            folderUri: sub.uri,
            systemFolderName: sub.name,
            safCategoryDirs: Map.unmodifiable(categoryDirs),
            safMirrorDir: mirrorRoot == null
                ? null
                : path.normalize(path.join(mirrorRoot, sub.name)),
          ),
        );
      } else if (categoryDirs.isNotEmpty) {
        mediaOnly.add(
          _SafMediaOnlyCandidate(
            name: sub.name,
            uri: sub.uri,
            categoryDirs: Map.unmodifiable(categoryDirs),
          ),
        );
      }
    }
    _log.i(
      'in-folder import: SAF discovery uri=$folderUri '
      'subfolders=${subfolders.length} gamelists=${sources.length} '
      'mediaOnly=${mediaOnly.length} listingFailed=$listingFailed',
    );
    return (
      sources: sources,
      mediaOnly: mediaOnly,
      listingFailed: listingFailed,
    );
  }

  /// Resolves a SAF `content://` ROM folder to a real filesystem path, or null
  /// when none is readable. Tests inject a fake so `content://` resolution can
  /// be exercised off-device; plain paths never go through it.
  @visibleForTesting
  static Future<String?> Function(String contentUri)?
  safRomFolderResolverOverride;

  /// The real path to read [romFolder] from: plain paths as-is, `content://`
  /// trees through the same SAF-to-real-path resolution the ES-DE picker uses.
  /// Null when the folder is a SAF tree the importer's `dart:io` core cannot
  /// read (no all-files access, a non-external-storage provider, or a real
  /// path that isn't there).
  // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Real-Path Scope"
  static Future<String?> _resolveRomFolderPath(String romFolder) async {
    if (!romFolder.startsWith('content://')) return romFolder;
    final override = safRomFolderResolverOverride;
    final real = override != null
        ? await override(romFolder)
        : await _resolveSafRomFolder(romFolder);
    if (real == null || real.trim().isEmpty) return null;
    if (!Directory(real).existsSync()) {
      _log.w(
        'in-folder import: resolved real path is not readable '
        'uri=$romFolder path=$real',
      );
      return null;
    }
    return real;
  }

  static Future<String?> _resolveSafRomFolder(String contentUri) async {
    final real = UserDataLocationService.safUriToRealPath(contentUri);
    if (real == null) return null;
    // A real path under /storage is only readable with all-files access; the
    // app requests it but cannot assume it, so treat its absence as "no real
    // path" rather than failing later on an opaque listing error.
    if (Platform.isAndroid && !await PermissionService.hasAllFilesAccess()) {
      _log.w(
        'in-folder import: all-files access not granted, '
        'cannot read uri=$contentUri path=$real',
      );
      return null;
    }
    return real;
  }

  /// Clears all ES-DE-imported data so the import can be re-run from scratch.
  /// Deletes only metadata rows the ES-DE import itself created
  /// (`esde_imported = 1`) that a later NeoStation scrape hasn't upgraded
  /// (`is_fully_scraped = 0`) — never NeoStation's own partially-scraped rows,
  /// which also sit at `is_fully_scraped = 0`. Clears every system's
  /// `esde_media_dir` so the read-time media fallback stops. The selected ES-DE
  /// folder path lives in `user_config` / SqliteConfigProvider and is cleared by
  /// the caller (so the cached config and UI update too); favorites /
  /// last-played are left untouched (indistinguishable from the user's own).
  /// Both discovery modes share the provenance flag, so one reset clears the
  /// rows of either; the in-folder `esde_media_root` is cleared alongside
  /// `esde_media_dir`. SAF mirror directories recorded as media roots under
  /// `<user data>/imported_media/` are deleted first (see [resetDetailed]).
  /// Returns the number of metadata rows removed. Throws
  /// [EsdeImportBusyException] while an import is running.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
  static Future<int> reset() async =>
      (await resetDetailed()).metadataRowsDeleted;

  /// [reset] with the full tally: metadata rows, media roots cleared, and
  /// SAF mirror directories removed. Throws [EsdeImportBusyException] while
  /// an import is running.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
  static Future<EsdeResetResult> resetDetailed() => _guarded(
    'reset',
    _reset,
    refused: () => throw const EsdeImportBusyException(),
  );

  static Future<EsdeResetResult> _reset() async {
    // Mirrors go first: the prefix check reads `esde_media_root`, which the
    // column clear below wipes.
    final mirrorsRemoved = await _deleteMirrorDirectories();
    final db = await SqliteService.getDatabase();
    final deleted = await db.delete(
      'user_screenscraper_metadata',
      where: 'esde_imported = 1 AND is_fully_scraped = 0',
    );
    await db.update('user_system_settings', {
      'esde_media_dir': null,
    }, where: 'esde_media_dir IS NOT NULL');
    // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Fill-Gaps Merge and Provenance"
    final rootsCleared = await ScraperRepository.clearEsdeMediaRoots();
    _log.i(
      'ES-DE reset: cleared $deleted metadata rows, media dirs, '
      '$rootsCleared in-folder media roots, and removed $mirrorsRemoved '
      'SAF mirror directories',
    );
    return EsdeResetResult(
      metadataRowsDeleted: deleted,
      mediaRootsCleared: rootsCleared,
      mirrorsRemoved: mirrorsRemoved,
    );
  }

  /// Deletes the mirror directory of every system whose recorded
  /// `esde_media_root` lies strictly under the resolved `imported_media`
  /// root. The check is on the normalized path prefix, never on the column
  /// value alone: a real platform folder from SPEC-0002, a `content://` URI,
  /// or the mirror root itself is never deleted. No SAF call is made here;
  /// the SAF tree is only ever read by the importer. Returns the number of
  /// directories removed; a directory that fails to delete is logged and
  /// skipped so the column clear still runs.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
  static Future<int> _deleteMirrorDirectories() async {
    final mirrorRoot = await _resolveMirrorRoot();
    if (mirrorRoot == null) {
      _log.w(
        'ES-DE reset: mirror root unresolved, no mirror directories removed',
      );
      return 0;
    }
    final normalizedRoot = path.normalize(mirrorRoot);
    final locations = await ScraperRepository.getEsdeMediaLocations();
    var removed = 0;
    for (final location in locations) {
      final root = location.esdeMediaRoot;
      if (root == null || root.contains('://')) continue;
      final candidate = path.normalize(root);
      if (!isUnderMirrorRoot(candidate, normalizedRoot)) {
        _log.d(
          'ES-DE reset: media root outside the mirror prefix, kept '
          'system=${location.folderName} root=$candidate',
        );
        continue;
      }
      final dir = Directory(candidate);
      if (!dir.existsSync()) continue;
      try {
        dir.deleteSync(recursive: true);
        removed++;
        _log.i(
          'ES-DE reset: removed mirror system=${location.folderName} '
          'dir=$candidate',
        );
      } catch (e) {
        _log.e(
          'ES-DE reset: failed to remove mirror system=${location.folderName} '
          'dir=$candidate error=$e',
        );
      }
    }
    return removed;
  }

  /// True when [candidate] is strictly inside [mirrorRoot] (both normalized):
  /// the root itself, its siblings, and prefix look-alikes such as
  /// `imported_media2` are all outside. Exposed so the check can be tested
  /// without a database.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
  @visibleForTesting
  static bool isUnderMirrorRoot(String candidate, String mirrorRoot) {
    if (candidate.startsWith('content://')) return false;
    final root = path.normalize(mirrorRoot);
    final child = path.normalize(candidate);
    if (path.equals(root, child)) return false;
    return path.isWithin(root, child);
  }

  /// Default media folder name inside an ES-DE application folder.
  static const String defaultMediaDirName = 'downloaded_media';

  /// Absolute path to the folder ES-DE actually writes downloaded artwork
  /// into for the application folder [esdeRoot].
  ///
  /// ES-DE lets the user move that folder anywhere; the choice lives in
  /// `settings/es_settings.xml` as `<string name="MediaDirectory" value="…" />`
  /// and, when set, REPLACES `<esdeRoot>/downloaded_media` outright (the value
  /// is the media folder itself, not a parent holding one). Without reading it
  /// an import of such an install finds no artwork at all — issue #456.
  ///
  /// ES-DE expands `~` and `%ESPATH%` inside the value, so we do too.
  /// `%ESPATH%` is the ES-DE *binary's* directory, which we can't know from
  /// the picked folder, so both the ES-DE folder and its parent are tried (the
  /// usual portable layout puts `ES-DE.exe` next to the `ES-DE/` data folder).
  ///
  /// Falls back to `<esdeRoot>/downloaded_media` whenever the setting is
  /// absent, blank, unreadable, or names a folder that isn't there — a stale
  /// setting must not cost the user the media they do have.
  static String resolveMediaRoot(String esdeRoot) {
    final fallback = path.join(esdeRoot, defaultMediaDirName);
    final settingsFile = File(
      path.join(esdeRoot, 'settings', 'es_settings.xml'),
    );
    if (!settingsFile.existsSync()) return fallback;

    String? raw;
    try {
      // Parsed as a fragment and decoded leniently for the same reasons
      // gamelist.xml is: ES-DE's own parser is lenient, and one bad byte in an
      // unrelated setting must not cost us the media directory.
      final doc = XmlDocumentFragment.parse(
        utf8.decode(settingsFile.readAsBytesSync(), allowMalformed: true),
      );
      for (final e in doc.findAllElements('string')) {
        if (e.getAttribute('name') == 'MediaDirectory') {
          raw = e.getAttribute('value');
          break;
        }
      }
    } catch (e) {
      _log.w('ES-DE: failed to read ${settingsFile.path}: $e');
      return fallback;
    }

    if (raw == null || raw.trim().isEmpty) return fallback;

    for (final candidate in _expandEsdePath(raw.trim(), esdeRoot)) {
      if (Directory(candidate).existsSync()) {
        if (candidate != fallback) {
          _log.i('ES-DE: using custom MediaDirectory "$candidate"');
        }
        return candidate;
      }
    }

    _log.w(
      'ES-DE: MediaDirectory "$raw" does not exist, '
      'falling back to $fallback',
    );
    return fallback;
  }

  /// Expansions of an ES-DE settings path [raw], most-likely first. `~` uses
  /// the user's home directory; `%ESPATH%` has no single answer from a picked
  /// data folder, so it yields one candidate per plausible binary location.
  static List<String> _expandEsdePath(String raw, String esdeRoot) {
    var value = raw.replaceAll('\\', '/');

    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      if (value == '~') {
        value = home;
      } else if (value.startsWith('~/')) {
        value = path.join(home, value.substring(2));
      }
    }

    final esPaths = value.contains('%ESPATH%')
        ? [path.dirname(esdeRoot), esdeRoot]
        : const <String?>[null];

    final candidates = <String>[];
    for (final esPath in esPaths) {
      var expanded = esPath == null
          ? value
          : value.replaceAll('%ESPATH%', esPath.replaceAll('\\', '/'));
      // ES-DE tolerates a trailing separator; path.join would keep it and the
      // resulting media paths would carry a doubled separator.
      while (expanded.length > 1 && expanded.endsWith('/')) {
        expanded = expanded.substring(0, expanded.length - 1);
      }
      if (expanded.isEmpty) continue;
      final normalized = path.normalize(expanded);
      if (!candidates.contains(normalized)) candidates.add(normalized);
    }
    return candidates;
  }

  /// Wires up the artwork fallback for ES-DE systems that have a
  /// `<mediaRoot>/<system>/` tree but no `gamelists/<system>/gamelist.xml`
  /// — a normal state in ES-DE (media survives a gamelist the user deleted, and
  /// some systems are scraped for art without ever being played).
  ///
  /// There is no metadata to import for these, but their art is perfectly
  /// usable: recording `esde_media_dir` lets [FileProvider] resolve it for any
  /// ROM NeoStation has scanned. Without this the whole system's art is
  /// invisible even though the files are right there.
  static Future<int> _linkMediaOnlySystems(
    String mediaRoot,
    Set<String> importedDirs,
  ) async {
    final mediaDir = Directory(mediaRoot);
    if (!mediaDir.existsSync()) return 0;

    var linked = 0;
    for (final dir in mediaDir.listSync().whereType<Directory>()) {
      final esdeDirName = path.basename(dir.path);
      if (importedDirs.contains(esdeDirName.toLowerCase())) continue;

      final system = await ScraperRepository.resolveSystemByFolderName(
        esdeDirName,
      );
      if (system == null) continue;

      await _recordEsdeMediaDir(
        mediaRoot,
        esdeDirName,
        system['app_system_id']!,
      );
      linked++;
      _log.i(
        'ES-DE import: linked art-only system "$esdeDirName" '
        '(no gamelist.xml) to ${system['app_system_id']}',
      );
    }
    return linked;
  }

  /// Media folder names an in-folder platform folder may carry that map to a
  /// NeoStation media slot (the `FileProvider` category map plus RomM's
  /// generic `images` and `thumbnails`). Anything else — `manuals`,
  /// `miximages`, `bezels`, ROM subfolders — is not media evidence.
  static const List<String> _inFolderMediaCategories = [
    'covers',
    '3dboxes',
    'marquees',
    'screenshots',
    'titlescreens',
    'fanart',
    'videos',
    'images',
    'thumbnails',
  ];

  /// In-folder counterpart of [_linkMediaOnlySystems]: a platform subfolder
  /// with no `gamelist.xml` still gets its media root recorded when it
  /// resolves to a system and at least one mapped category folder holds a
  /// file. Gating on real files keeps empty folders from acquiring a root.
  /// Systems already imported from a gamelist in this run are left alone so a
  /// second ROM folder's empty `snes/` cannot clobber the first one's root.
  // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "In-Folder Gamelist Discovery"
  static Future<int> _linkInFolderMediaOnlySystems(
    List<({String name, String dir})> candidates,
    Set<String> importedSystemIds,
  ) async {
    var linked = 0;
    for (final candidate in candidates) {
      if (!_hasInFolderMedia(candidate.dir)) continue;

      final system = await ScraperRepository.resolveSystemByFolderName(
        candidate.name,
      );
      if (system == null) continue;
      final appSystemId = system['app_system_id']!;
      if (importedSystemIds.contains(appSystemId)) continue;

      final recorded = await ScraperRepository.recordEsdeMediaRoot(
        appSystemId,
        candidate.dir,
      );
      if (!recorded) continue;
      importedSystemIds.add(appSystemId);
      linked++;
      _log.i(
        'in-folder import: linked art-only system folder=${candidate.name} '
        '(no gamelist.xml) to system=$appSystemId root=${candidate.dir}',
      );
    }
    return linked;
  }

  /// Whether any mapped media category folder directly under [dir] contains
  /// at least one file. Read-only: only lists, never creates.
  static bool _hasInFolderMedia(String dir) {
    for (final category in _inFolderMediaCategories) {
      final categoryDir = Directory(path.join(dir, category));
      if (!categoryDir.existsSync()) continue;
      try {
        if (categoryDir.listSync().any((e) => e is File)) return true;
      } on FileSystemException catch (e) {
        _log.w(
          'in-folder import: cannot list media folder '
          'dir=${categoryDir.path} error=${e.message}',
        );
      }
    }
    return false;
  }

  /// Records where the media for [source]'s system lives, in the column its
  /// discovery mode owns: ES-DE keeps the folder-name form (`esde_media_dir`),
  /// in-folder stores the absolute platform folder (`esde_media_root`).
  // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Fill-Gaps Merge and Provenance"
  static Future<void> _recordMediaLocation(
    GamelistSource source,
    String appSystemId,
  ) async {
    switch (source.mode) {
      case GamelistSourceMode.esdeRoot:
        await _recordEsdeMediaDir(
          source.mediaRoot,
          source.systemFolderName,
          appSystemId,
        );
      case GamelistSourceMode.inFolder:
        final recorded = await ScraperRepository.recordEsdeMediaRoot(
          appSystemId,
          source.mediaRoot,
        );
        if (!recorded) {
          _log.w(
            'in-folder import: media root not recorded '
            'system=$appSystemId root=${source.mediaRoot}',
          );
        }
      // A content:// folder is not a directory the media resolver can stat,
      // so nothing is recorded here; [_mirrorSafSystem] records the mirror
      // directory once it holds a copied file.
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
      case GamelistSourceMode.saf:
        _log.d(
          'in-folder import: media root for SAF system=$appSystemId '
          'folder=${source.mediaRoot} '
          'categories=${source.safCategoryDirs.keys.join(',')} '
          'is recorded by the media mirror',
        );
    }
  }

  /// The raw `gamelist.xml` bytes for [source]: a whole-file SAF read for a
  /// SAF source, a plain file read otherwise. Both feed the same parser.
  ///
  /// Throws [EsdeSafAccessException] when the SAF read yields nothing, so the
  /// caller's isolation logs the URI and counts the system as skipped.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Gamelist Read Over SAF"
  static Future<Uint8List> _readGamelistBytes(GamelistSource source) async {
    final uri = source.gamelistUri;
    if (uri != null) {
      final bytes = await _safReadFile(uri);
      if (bytes == null) {
        throw EsdeSafAccessException(uri, 'SAF read returned no data');
      }
      return bytes;
    }
    return source.gamelistFile!.readAsBytes();
  }

  static Future<EsdeImportResult> _importSystem({
    required GamelistSource source,
    required String appSystemId,
    required String descColumn,
    required EsdeImportResult accumulator,
    void Function(double fraction)? onGameProgress,
  }) async {
    var result = accumulator;
    // Parsed as a fragment, not a document: when the user picks a non-default
    // emulator for a system, ES-DE writes an `<alternativeEmulator>` element as
    // a SECOND root alongside `<gameList>`. That is invalid XML which ES-DE's
    // own (lenient) parser accepts, and `XmlDocument.parse` rejects outright
    // with "Unexpected root element" — silently skipping every such system.
    XmlDocumentFragment doc;
    try {
      // Decoded leniently: gamelist.xml is declared UTF-8 but ES-DE happily
      // writes whatever bytes a scraper handed it, and a single bad byte in
      // one <desc> would otherwise throw away the whole system's metadata.
      // The bytes come from a file or a SAF document; from here on the
      // source's layout no longer matters.
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Gamelist Read Over SAF"
      doc = XmlDocumentFragment.parse(
        utf8.decode(await _readGamelistBytes(source), allowMalformed: true),
      );
    } catch (e) {
      // One unreadable or unparseable gamelist costs only its own system:
      // counted as skipped with its location, and the run moves on.
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
      _log.e(
        'gamelist import: skipped system=${source.systemFolderName} '
        'mode=${source.mode.name} file=${source.location} '
        'reason=could not read or parse gamelist: $e',
      );
      return result._add(systemsSkipped: 1);
    }
    // gamelist.xml read and parsed: this system counts as matched.
    result = result._add(systemsMatched: 1);

    final db = await SqliteService.getDatabase();

    // Both tables are read once per system and indexed case-insensitively in
    // memory. Querying per `<game>` instead costs two round-trips per entry,
    // which on a large library is tens of thousands of queries on the UI
    // isolate — the single biggest cost of an import.
    final romsByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_roms',
      columns: ['filename', 'is_favorite', 'last_played', 'play_time'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      romsByName.putIfAbsent(name.toLowerCase(), () => row);
    }
    final metaByName = <String, Map<String, Object?>>{};
    for (final row in await db.query(
      'user_screenscraper_metadata',
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
    )) {
      final name = row['filename']?.toString();
      if (name == null || name.isEmpty) continue;
      metaByName.putIfAbsent(name.toLowerCase(), () => row);
    }

    // Writes go out as one batch per system rather than one implicit
    // transaction (and fsync) per game.
    final batch = db.batch();

    final games = _selectGames(doc, source.systemMediaDir);
    for (var g = 0; g < games.length; g++) {
      if (g % 100 == 0) onGameProgress?.call(g / games.length);
      final game = games[g];
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;

      // `<hidden>true</hidden>` is deliberately NOT honoured: hiding a game in
      // ES-DE says nothing about whether the user wants it in NeoStation, and
      // silently dropping it makes the import look broken to anyone who has
      // forgotten what they hid. NeoStation has its own hidden-game handling.
      final normalizedPath = rawPath.replaceAll('\\', '/');
      final filename = path.basename(normalizedPath);
      // ES-DE mirrors the ROM's subfolder (relative to the system's ROM dir)
      // inside downloaded_media, e.g. `<sys>/covers/<subdir>/<base>.png`. Capture
      // that subdir (empty when the ROM sits directly in the system folder) so
      // the read-time fallback can find nested artwork.
      final mediaSubdir = _mediaSubdir(normalizedPath);

      // Only import for ROMs NeoStation has already scanned.
      final rom = romsByName[filename.toLowerCase()];
      if (rom == null) {
        result = result._add(gamesUnmatched: 1);
        continue;
      }

      // The gamelist basename can differ in case from the scanned ROM filename.
      // Match happens case-insensitively above, but metadata is written and
      // later joined case-sensitively (user_roms.filename = metadata.filename),
      // so key everything on the actual scanned filename to avoid orphaning the
      // imported row and its media subdir.
      final canonicalFilename =
          (rom['filename'] as String?)?.trim().isNotEmpty == true
          ? rom['filename'] as String
          : filename;

      // --- Metadata (fill-gaps merge into user_screenscraper_metadata) ---
      final esdeMeta = <String, dynamic>{
        'real_name': _text(game, 'name'),
        descColumn: _text(game, 'desc'),
        'developer': _text(game, 'developer'),
        'publisher': _text(game, 'publisher'),
        'genre': _text(game, 'genre'),
        'players': _text(game, 'players'),
        'rating': _parseRating(_text(game, 'rating')),
        'release_date': _parseEsdeDateTime(
          _text(game, 'releasedate'),
        )?.toIso8601String(),
      };
      final existingMeta = metaByName[canonicalFilename.toLowerCase()];
      final metaWrite = ScraperRepository.buildEsdeMetadataWrite(
        appSystemId: appSystemId,
        filename: canonicalFilename,
        row: existingMeta,
        esde: esdeMeta,
        mediaSubdir: mediaSubdir,
      );
      if (metaWrite != null) {
        if (existingMeta == null) {
          batch.insert(
            'user_screenscraper_metadata',
            metaWrite,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else {
          batch.update(
            'user_screenscraper_metadata',
            metaWrite,
            where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
            whereArgs: [appSystemId, canonicalFilename],
          );
        }
        result = result._add(gamesImported: 1);
      }

      // --- Favorites / play stats (fill-gaps into user_roms) ---
      final favorite = _flag(game, 'favorite');
      final lastPlayed = _parseEsdeDateTime(_text(game, 'lastplayed'));
      final update = <String, dynamic>{};

      final currentlyFavorite = (rom['is_favorite'] as int? ?? 0) == 1;
      if (favorite && !currentlyFavorite) update['is_favorite'] = 1;

      final curLastPlayed = rom['last_played'];
      final lastPlayedEmpty =
          curLastPlayed == null ||
          (curLastPlayed is String && curLastPlayed.trim().isEmpty) ||
          (curLastPlayed is num && curLastPlayed == 0);
      if (lastPlayed != null && lastPlayedEmpty) {
        update['last_played'] = lastPlayed.toIso8601String();
      }

      // ES-DE's `<playtime>` is in seconds, same unit as user_roms.play_time.
      // Only fill when NeoStation has never timed this ROM, so an import can
      // never overwrite (or double-count onto) time the user accrued here.
      final esdePlayTime = int.tryParse(_text(game, 'playtime') ?? '');
      final curPlayTime =
          int.tryParse(rom['play_time']?.toString() ?? '0') ?? 0;
      if (esdePlayTime != null && esdePlayTime > 0 && curPlayTime == 0) {
        update['play_time'] = esdePlayTime;
      }

      if (update.isNotEmpty) {
        batch.update(
          'user_roms',
          update,
          where: 'app_system_id = ? AND filename = ? COLLATE NOCASE',
          whereArgs: [appSystemId, canonicalFilename],
        );
        result = result._add(statsUpdated: 1);
      }
    }

    await batch.commit(noResult: true);
    onGameProgress?.call(1.0);
    return result;
  }

  /// Persists which ES-DE media subfolder backs a NeoStation system so
  /// read-time fallback can resolve artwork. Prefers a folder that actually
  /// contains a `<mediaRoot>/<dir>` tree; otherwise only sets it when not
  /// already populated.
  static Future<void> _recordEsdeMediaDir(
    String mediaRoot,
    String esdeDirName,
    String appSystemId,
  ) async {
    final db = await SqliteService.getDatabase();
    final hasMedia = Directory(path.join(mediaRoot, esdeDirName)).existsSync();

    final existing = await db.query(
      'user_system_settings',
      columns: ['app_system_id', 'esde_media_dir'],
      where: 'app_system_id = ?',
      whereArgs: [appSystemId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('user_system_settings', {
        'app_system_id': appSystemId,
        'esde_media_dir': esdeDirName,
      });
      return;
    }

    final current = existing.first['esde_media_dir'];
    final currentEmpty =
        current == null || (current is String && current.trim().isEmpty);
    if (hasMedia || currentEmpty) {
      await db.update(
        'user_system_settings',
        {'esde_media_dir': esdeDirName},
        where: 'app_system_id = ?',
        whereArgs: [appSystemId],
      );
    }
  }

  /// Maps a preferred language code to a `user_screenscraper_metadata`
  /// description column, defaulting to English when unsupported.
  static String _descriptionColumn(String lang) {
    const supported = {'en', 'es', 'fr', 'de', 'it', 'pt'};
    final code = lang.toLowerCase();
    return supported.contains(code) ? 'description_$code' : 'description_en';
  }

  /// ES-DE stores rating as a 0..1 float string; NeoStation stores it on
  /// ScreenScraper's 0..20 scale (displayed as `rating / 2` out of 10), so
  /// scale the ES-DE value up by 20.
  static double? _parseRating(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = double.tryParse(raw.trim());
    if (v == null) return null;
    return v.clamp(0.0, 1.0) * 20.0;
  }

  /// Parses ES-DE's basic ISO datetime (`yyyyMMddTHHmmss`, e.g.
  /// `19950311T000000`) into a [DateTime]. Returns null on failure or
  /// placeholder/zero dates.
  static DateTime? _parseEsdeDateTime(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 8) return null;
    try {
      final year = int.parse(s.substring(0, 4));
      final month = int.parse(s.substring(4, 6));
      final day = int.parse(s.substring(6, 8));
      if (year <= 1 || month < 1 || month > 12 || day < 1 || day > 31) {
        return null;
      }
      var hour = 0, minute = 0, second = 0;
      if (s.length >= 15 && s[8] == 'T') {
        hour = int.parse(s.substring(9, 11));
        minute = int.parse(s.substring(11, 13));
        second = int.parse(s.substring(13, 15));
      }
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// Extracts the ES-DE media subfolder from a gamelist `<path>` — the ROM's
  /// directory relative to the system folder, with a leading `./` stripped.
  /// Returns `''` when the ROM sits directly in the system folder.
  /// De-duplicates a gamelist's `<game>` entries by ROM filename.
  ///
  /// ES-DE can list the same filename in several subfolders of one system
  /// (e.g. a base ROM plus copies under `Hacks/`, `Translations/`, or
  /// `All but the Best (…)/`). They all collapse onto a single NeoStation
  /// metadata row keyed by `(app_system_id, filename)`, so importing every one
  /// makes them fight over `esde_media_subdir` on each run (the churn behind the
  /// "N games imported" count never dropping to zero). Keep one entry per
  /// filename, preferring whichever subfolder actually holds downloaded media so
  /// the artwork fallback resolves correctly; otherwise keep the first seen.
  static List<XmlElement> _selectGames(XmlNode doc, String systemMediaDir) {
    final chosen = <String, XmlElement>{};
    for (final game in doc.findAllElements('game')) {
      final rawPath = _text(game, 'path');
      if (rawPath == null || rawPath.isEmpty) continue;
      final normalized = rawPath.replaceAll('\\', '/');
      final key = path.basename(normalized).toLowerCase();

      final existing = chosen[key];
      if (existing == null) {
        chosen[key] = game;
        continue;
      }

      final filename = path.basename(normalized);
      final existingSubdir = _mediaSubdir(
        (_text(existing, 'path') ?? '').replaceAll('\\', '/'),
      );
      final newSubdir = _mediaSubdir(normalized);
      if (!_esdeMediaExists(systemMediaDir, filename, existingSubdir) &&
          _esdeMediaExists(systemMediaDir, filename, newSubdir)) {
        chosen[key] = game;
      }
    }
    return chosen.values.toList();
  }

  /// Whether any `<systemMediaDir>/<category>/<subdir>/` folder holds a file
  /// whose name (sans extension) matches [filename]'s base — i.e. scraped
  /// artwork for this ROM under [subdir].
  static bool _esdeMediaExists(
    String systemMediaDir,
    String filename,
    String subdir,
  ) {
    final dot = filename.lastIndexOf('.');
    final base = (dot > 0 ? filename.substring(0, dot) : filename)
        .toLowerCase();
    for (final category in const [
      'covers',
      'screenshots',
      'marquees',
      'fanart',
    ]) {
      final dir = path.join(systemMediaDir, category, subdir);
      if (_mediaIndex(dir).contains(base)) return true;
    }
    return false;
  }

  /// Extension-less, lowercased names of the files directly in [dir].
  ///
  /// Cached for the duration of an import: duplicate ROM names are checked
  /// against the same handful of media folders over and over, and each miss
  /// would otherwise re-list the whole directory from storage.
  static final Map<String, Set<String>> _mediaIndexCache = {};

  static Set<String> _mediaIndex(String dir) {
    return _mediaIndexCache.putIfAbsent(dir, () {
      final names = <String>{};
      final directory = Directory(dir);
      if (!directory.existsSync()) return names;
      for (final entry in directory.listSync()) {
        if (entry is! File) continue;
        final name = path.basename(entry.path);
        final d = name.lastIndexOf('.');
        names.add((d > 0 ? name.substring(0, d) : name).toLowerCase());
      }
      return names;
    });
  }

  static String _mediaSubdir(String normalizedPath) {
    var p = normalizedPath;
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    final dir = path.dirname(p);
    if (dir == '.' || dir == '/' || dir.isEmpty) return '';
    return dir.startsWith('/') ? dir.substring(1) : dir;
  }

  /// Reads an ES-DE boolean metadata tag (`<favorite>`, `<hidden>`, …).
  /// ES-DE writes these as the literal strings `true` / `false`.
  static bool _flag(XmlElement parent, String tag) =>
      _text(parent, tag)?.toLowerCase() == 'true';

  static String? _text(XmlElement parent, String tag) {
    final el = parent.getElement(tag);
    if (el == null) return null;
    final t = el.innerText.trim();
    return t.isEmpty ? null : t;
  }

  // ── Test seams ──────────────────────────────────────────────────────────
  // Thin wrappers so unit tests can exercise the pure parsing/selection logic
  // without going through a full on-disk import.

  @visibleForTesting
  static double? parseRatingForTest(String? raw) => _parseRating(raw);

  @visibleForTesting
  static DateTime? parseEsdeDateTimeForTest(String? raw) =>
      _parseEsdeDateTime(raw);

  @visibleForTesting
  static String mediaSubdirForTest(String normalizedPath) =>
      _mediaSubdir(normalizedPath);

  /// Runs SAF discovery on one ROM folder and returns the gamelist sources it
  /// found, so a test can inspect the category folders each source carries.
  /// [mirrorRoot] stands in for the resolved `imported_media` directory.
  @visibleForTesting
  static Future<List<GamelistSource>> discoverSafSourcesForTest(
    String folderUri, {
    String? mirrorRoot,
  }) async => (await _discoverSafFolder(folderUri, mirrorRoot)).sources;

  @visibleForTesting
  static List<XmlElement> selectGamesForTest(
    XmlNode doc,
    String mediaRoot,
    String esdeDirName,
  ) => _selectGames(doc, path.join(mediaRoot, esdeDirName));
}
