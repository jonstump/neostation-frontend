import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:neostation/models/rom_fingerprint.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/romm_link_state.dart';

/// The server search the picker runs — `RommService.getRomsPage` in the app,
/// a fake in tests.
typedef RommMatchSearch =
    Future<RommRomPage> Function({
      required String search,
      required List<int> platformIds,
      required int limit,
    });

/// Resolves a local system's real name to the RomM platform ids to scope by.
typedef RommMatchPlatformIds = Future<List<int>> Function(String realName);

/// Reads the game's current mapping row, if any.
typedef RommMatchMappingReader = Future<RommSaveMapping?> Function();

/// Writes the manual row — `RommSaveMapRepository.putManualMapping`.
typedef RommMatchMappingWriter =
    Future<bool> Function({
      required String romname,
      required String systemFolder,
      required int rommRomId,
      String? fsName,
    });

/// Drops the sync provider's cached state for one game after the row changed.
typedef RommMatchSyncInvalidator = void Function(String romname);

/// Fills the game's metadata gaps from the ROM it was just linked to —
/// `RommProvider.fetchMetadata` in fill-gaps mode in the app, a fake in tests.
typedef RommMatchMetadataFetcher =
    Future<RommMetadataOutcome> Function(RommRom rom);

/// Fingerprints the game's file at full effort —
/// `RomFingerprintService.computeInBackground` in the app, a fake in tests.
/// A null fingerprint carries the skip reason (a disc image, an unreadable
/// file) in the record's second field.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
typedef RommMatchFingerprinter =
    Future<({RomFingerprint? fingerprint, String? skipReason})> Function();

/// Asks the server which ROM carries [fingerprint]'s hashes —
/// `RommService.getRomByHash` in the app. Null is a miss; a throw is a failure.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
typedef RommMatchHashLookup =
    Future<RommRom?> Function(RomFingerprint fingerprint);

/// A picker search that did not complete, with the query it was for and the
/// underlying failure. A sentinel type so the dialog can tell a failed search
/// apart from an empty one and offer a retry rather than "no results".
class RommMatchSearchException implements Exception {
  final String query;
  final List<int> platformIds;
  final Object cause;

  const RommMatchSearchException({
    required this.query,
    required this.platformIds,
    required this.cause,
  });

  @override
  String toString() =>
      'RomM link search failed: query="$query" '
      'platformIds=$platformIds cause=$cause';
}

/// Where the picker's result list stands.
enum RommMatchPickerStatus {
  /// Nothing searched yet.
  idle,

  /// A search is in flight.
  loading,

  /// [RommMatchPickerController.results] is the answer to the last search.
  ready,

  /// The last search failed; see [RommMatchPickerController.lastError].
  error,
}

/// Where the picker's "Match by hash" action stands.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
enum RommMatchByHashStatus {
  /// Not run, or the last run was cancelled.
  idle,

  /// The file is being fingerprinted or the server asked.
  busy,

  /// The server named a ROM; it is first in the results and preselected.
  hit,

  /// The server knows no ROM with these hashes.
  miss,

  /// The file could not be fingerprinted; see
  /// [RommMatchPickerController.hashSkipReason].
  skipped,

  /// The fingerprint or the lookup threw; see
  /// [RommMatchPickerController.hashError].
  error,
}

/// The picker's search-and-confirm logic, separated from the dialog so the
/// scoping, debounce, write key, and single invalidation are unit-testable
/// with hand-written fakes. The dialog owns focus and layout only.
///
/// Two names for one game travel through here: [linkKey] is the on-disk
/// filename (`Game.sfc`, or the `.m3u`) the mapping row is keyed by, exactly
/// as the download path and `RommProvider.linkLocalCopy` write it, so the
/// manual row replaces theirs instead of sitting beside it; [syncKey] is the
/// extension-stripped `GameModel.romname` the sync provider caches state under.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
class RommMatchPickerController extends ChangeNotifier {
  static final _log = LoggerService.instance;

  final String linkKey;
  final String syncKey;
  final String systemFolder;
  final String systemRealName;
  final RommMatchSearch searchRoms;
  final RommMatchPlatformIds platformIdsFor;
  final RommMatchMappingReader readMapping;
  final RommMatchMappingWriter writeMapping;
  final RommMatchSyncInvalidator invalidateSyncState;
  final RommMatchMetadataFetcher fetchMetadata;
  final Duration debounce;
  final int pageLimit;

  /// A result to pin at the top of the list and pre-select — the search
  /// screen opens the picker on the remote ROM the user was already looking at.
  final RommRom? preselected;

  /// Fingerprints the game's file for [matchByHash]; null when the caller
  /// offers no hash matching, which hides the action.
  final RommMatchFingerprinter? fingerprintFile;

  /// Looks a fingerprint up on the server for [matchByHash]; null hides the
  /// action.
  final RommMatchHashLookup? lookupByHash;

  /// The capability gate: false when the heartbeat proved the server predates
  /// `GET /api/roms/by-hash`. Unknown counts as available, per ADR-0010.
  final bool _hashLookupGateOpen;

  RommMatchPickerController({
    required this.linkKey,
    required this.syncKey,
    required this.systemFolder,
    required this.systemRealName,
    required this.searchRoms,
    required this.platformIdsFor,
    required this.readMapping,
    required this.writeMapping,
    required this.invalidateSyncState,
    required this.fetchMetadata,
    this.preselected,
    this.fingerprintFile,
    this.lookupByHash,
    bool hashLookupAvailable = false,
    this.debounce = const Duration(milliseconds: 350),
    this.pageLimit = 25,
  }) : _hashLookupGateOpen = hashLookupAvailable;

  List<int> _platformIds = const [];
  List<RommRom> _results = const [];
  RommMatchPickerStatus _status = RommMatchPickerStatus.idle;
  RommMatchSearchException? _lastError;
  int? _currentRomId;
  RommMetadataOutcome? _lastFetchOutcome;
  String _prefilledQuery = '';
  String? _cleanedQuery;
  Timer? _debounceTimer;
  int _requestSerial = 0;
  bool _disposed = false;
  RommMatchByHashStatus _hashStatus = RommMatchByHashStatus.idle;
  String? _hashSkipReason;
  Object? _hashError;
  RommRom? _hashHit;
  int _hashSerial = 0;

  /// RomM platform ids the search is scoped to; empty means unscoped.
  List<int> get platformIds => _platformIds;

  /// False when the game's system resolved to no RomM platform, in which case
  /// every platform is searched and the rows show theirs.
  bool get isScoped => _platformIds.isNotEmpty;

  List<RommRom> get results => _results;
  RommMatchPickerStatus get status => _status;
  RommMatchSearchException? get lastError => _lastError;

  /// Rom id of the row the game is linked to right now, for the check mark.
  int? get currentRomId => _currentRomId;

  /// What the fill-gaps fetch after the last successful [confirm] did, or
  /// null before one ran. A fetch that threw is recorded as a failed outcome.
  RommMetadataOutcome? get lastFetchOutcome => _lastFetchOutcome;

  /// The cleaned form of the query [init] was given — what the dialog's field
  /// should show. Set synchronously at the start of [init], so it can be read
  /// as soon as [init] has been called.
  String get prefilledQuery => _prefilledQuery;

  /// True when [results] answer the cleaned form of the user's query rather
  /// than what they typed — the raw query found nothing and the automatic
  /// retry ran. Cleared by the next search or by editing the field.
  bool get queryWasCleaned => _cleanedQuery != null;

  /// The cleaned query [results] are for while [queryWasCleaned]; null
  /// otherwise.
  String? get cleanedQuery => _cleanedQuery;

  /// Whether the dialog should offer "Match by hash": the server is not
  /// known to lack the endpoint and the caller wired both halves of the run.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  bool get hashLookupAvailable =>
      _hashLookupGateOpen && fingerprintFile != null && lookupByHash != null;

  RommMatchByHashStatus get hashStatus => _hashStatus;

  /// True while [matchByHash] is fingerprinting or asking the server.
  bool get isMatchingByHash => _hashStatus == RommMatchByHashStatus.busy;

  /// The fingerprint service's skip token (`disc`, `oversize`, ...) while
  /// [hashStatus] is [RommMatchByHashStatus.skipped]; null otherwise.
  String? get hashSkipReason => _hashSkipReason;

  /// The failure behind [RommMatchByHashStatus.error], for the dialog's log.
  Object? get hashError => _hashError;

  /// The ROM the last successful [matchByHash] found, or null. It outranks
  /// [preselected] as the pinned row: the server just said this is the file.
  RommRom? get hashHit => _hashHit;

  /// The ROM pinned first in [results] and pre-selected: the hash hit when
  /// there is one, else what the caller pinned.
  RommRom? get pinnedRom => _hashHit ?? preselected;

  /// Index of [pinnedRom] within [results], or -1.
  int get preselectedIndex {
    final pinned = pinnedRom;
    if (pinned == null) return -1;
    return _results.indexWhere((r) => r.id == pinned.id);
  }

  /// Resolves the platform scope and the current link, then runs the first
  /// search for the cleaned form of [initialQuery] (see [cleanRomTitle]) —
  /// the raw filename's region and language tags are what keeps RomM's name
  /// search from matching. Scope resolution failing is logged and leaves the
  /// search unscoped rather than blocking the picker.
  Future<void> init(String initialQuery) async {
    _prefilledQuery = cleanRomTitle(initialQuery);
    try {
      _platformIds = List.unmodifiable(await platformIdsFor(systemRealName));
    } catch (e, st) {
      _log.e(
        'RomM link picker: platform scope failed, searching unscoped '
        '(system=$systemRealName)',
        error: e,
        stackTrace: st,
      );
      _platformIds = const [];
    }
    try {
      _currentRomId = (await readMapping())?.rommRomId;
    } catch (e, st) {
      _log.e(
        'RomM link picker: reading current mapping failed '
        '(linkKey=$linkKey, systemFolder=$systemFolder)',
        error: e,
        stackTrace: st,
      );
    }
    if (_disposed) return;
    notifyListeners();
    await searchNow(_prefilledQuery);
  }

  /// Schedules a search for [query] after [debounce] of quiet, replacing any
  /// search already scheduled, so a burst of keystrokes costs one request.
  /// Editing the field also retires the "results are for the cleaned query"
  /// note, which described the previous results.
  void onQueryChanged(String query) {
    _debounceTimer?.cancel();
    if (_cleanedQuery != null) {
      _cleanedQuery = null;
      if (!_disposed) notifyListeners();
    }
    _debounceTimer = Timer(debounce, () => searchNow(query));
  }

  /// Runs the search immediately (cancelling a pending debounce). A response
  /// that arrives after a newer search started is dropped.
  ///
  /// A raw query that finds nothing is retried once with its cleaned form
  /// when that differs (see [cleanRomTitle]); the retry is a search like any
  /// other for the serial guard, so a newer search supersedes it. The retry
  /// is skipped altogether when a keystroke has already queued a debounced
  /// search: that search is for what the field holds now, and running the
  /// retry would cancel it and show cleaned results for text the user has
  /// moved on from. A failed search is not retried here — that is the
  /// dialog's retry row.
  Future<void> searchNow(String query) => _search(query, isRetry: false);

  Future<void> _search(String query, {required bool isRetry}) async {
    _debounceTimer?.cancel();
    final serial = ++_requestSerial;
    _status = RommMatchPickerStatus.loading;
    if (!_disposed) notifyListeners();

    final trimmed = query.trim();
    try {
      final page = await searchRoms(
        search: trimmed,
        platformIds: _platformIds,
        limit: pageLimit,
      );
      if (_disposed || serial != _requestSerial) return;
      // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
      final pendingKeystroke = _debounceTimer?.isActive ?? false;
      if (!isRetry && page.items.isEmpty && !pendingKeystroke) {
        final cleaned = cleanRomTitle(trimmed);
        if (cleaned != trimmed) {
          _log.i(
            'RomM link picker: no results for "$trimmed", '
            'retrying with "$cleaned"',
          );
          await _search(cleaned, isRetry: true);
          return;
        }
      } else if (!isRetry && page.items.isEmpty) {
        _log.i(
          'RomM link picker: no results for "$trimmed", '
          'skipping the cleaned retry — a newer search is pending',
        );
      }
      _results = List.unmodifiable(_withPreselected(page.items));
      _lastError = null;
      _cleanedQuery = isRetry ? trimmed : null;
      _status = RommMatchPickerStatus.ready;
    } catch (e, st) {
      if (_disposed || serial != _requestSerial) return;
      final failure = RommMatchSearchException(
        query: trimmed,
        platformIds: _platformIds,
        cause: e,
      );
      _log.e(
        'RomM link picker: search failed (query="$trimmed", '
        'platformIds=$_platformIds, linkKey=$linkKey)',
        error: e,
        stackTrace: st,
      );
      _results = const [];
      _lastError = failure;
      _cleanedQuery = null;
      _status = RommMatchPickerStatus.error;
    }
    notifyListeners();
  }

  List<RommRom> _withPreselected(List<RommRom> items) {
    final pinned = pinnedRom;
    if (pinned == null) return items;
    if (items.any((r) => r.id == pinned.id)) return items;
    return [pinned, ...items];
  }

  /// Fingerprints the game's file and asks the server which ROM carries those
  /// hashes. On a hit the ROM goes first in [results] and becomes the pinned
  /// row (see [pinnedRom]); a miss, a fingerprint skip, and a failure each
  /// settle into their own [hashStatus] so the dialog can say which. The
  /// search results stay as they are in every case.
  ///
  /// One run at a time: a press while busy is ignored. A run that
  /// [cancelMatchByHash] retired discards whatever it later produces, so a
  /// late hit cannot re-pin the list after the user moved on. Nothing here
  /// writes: confirming the pinned row goes through [confirm] like any other.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  Future<void> matchByHash() async {
    final fingerprinter = fingerprintFile;
    final lookup = lookupByHash;
    if (!hashLookupAvailable || fingerprinter == null || lookup == null) {
      return;
    }
    if (_hashStatus == RommMatchByHashStatus.busy) return;

    final serial = ++_hashSerial;
    _hashStatus = RommMatchByHashStatus.busy;
    // A run replaces the previous outcome wholesale: a stale hit must not stay
    // pinned under a miss, skip, or error line that says otherwise.
    _hashHit = null;
    _hashSkipReason = null;
    _hashError = null;
    if (!_disposed) notifyListeners();

    try {
      final printed = await fingerprinter();
      if (_disposed || serial != _hashSerial) return;
      final fingerprint = printed.fingerprint;
      if (fingerprint == null) {
        _hashSkipReason = printed.skipReason ?? 'error';
        _hashStatus = RommMatchByHashStatus.skipped;
        _log.i(
          'RomM link picker: match by hash skipped '
          '(linkKey=$linkKey, systemFolder=$systemFolder, '
          'reason=$_hashSkipReason)',
        );
        notifyListeners();
        return;
      }

      final rom = await lookup(fingerprint);
      if (_disposed || serial != _hashSerial) return;
      if (rom == null) {
        _hashStatus = RommMatchByHashStatus.miss;
        _log.i(
          'RomM link picker: match by hash missed '
          '(linkKey=$linkKey, systemFolder=$systemFolder, '
          'crc32=${fingerprint.crc32})',
        );
      } else {
        _hashHit = rom;
        _results = List.unmodifiable([
          rom,
          ..._results.where((r) => r.id != rom.id),
        ]);
        _hashStatus = RommMatchByHashStatus.hit;
        _log.i(
          'RomM link picker: match by hash hit '
          '(linkKey=$linkKey, systemFolder=$systemFolder, '
          'crc32=${fingerprint.crc32}, romId=${rom.id})',
        );
      }
    } catch (e, st) {
      if (_disposed || serial != _hashSerial) return;
      _hashError = e;
      _hashStatus = RommMatchByHashStatus.error;
      _log.e(
        'RomM link picker: match by hash failed '
        '(linkKey=$linkKey, systemFolder=$systemFolder)',
        error: e,
        stackTrace: st,
      );
    }
    notifyListeners();
  }

  /// Retires a busy [matchByHash] run — B while the spinner shows. Returns
  /// true when there was one to cancel, so the dialog knows the press was
  /// consumed and does not also close. The run's eventual result is dropped.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  bool cancelMatchByHash() {
    if (_hashStatus != RommMatchByHashStatus.busy) return false;
    _hashSerial++;
    _hashStatus = RommMatchByHashStatus.idle;
    _log.i(
      'RomM link picker: match by hash cancelled '
      '(linkKey=$linkKey, systemFolder=$systemFolder)',
    );
    if (!_disposed) notifyListeners();
    return true;
  }

  /// Writes the manual row for [rom] under [linkKey], invalidates the game's
  /// sync state exactly once, then fills the game's metadata gaps from [rom].
  /// Returns false — with nothing invalidated and nothing fetched — when the
  /// repository reported the write failed.
  ///
  /// The fetch runs after the row is written so the writer keys the metadata
  /// row off the mapping that now exists, and it never fails the link: its
  /// outcome (or a failed one, when it threw) is kept in [lastFetchOutcome].
  // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fill Gaps On Link Confirm"
  Future<bool> confirm(RommRom rom) async {
    final written = await writeMapping(
      romname: linkKey,
      systemFolder: systemFolder,
      rommRomId: rom.id,
      fsName: rom.fsName,
    );
    if (!written) {
      _log.e(
        'RomM link picker: manual link not written '
        '(linkKey=$linkKey, systemFolder=$systemFolder, romId=${rom.id})',
      );
      return false;
    }
    _log.i(
      'RomM link picker: linked $systemFolder/$linkKey to rom ${rom.id} '
      '(${rom.fsName}) by hand',
    );
    invalidateSyncState(syncKey);
    _currentRomId = rom.id;
    if (!_disposed) notifyListeners();
    try {
      _lastFetchOutcome = await fetchMetadata(rom);
    } catch (e, st) {
      _log.e(
        'RomM link picker: metadata fetch after link threw '
        '(linkKey=$linkKey, systemFolder=$systemFolder, romId=${rom.id})',
        error: e,
        stackTrace: st,
      );
      _lastFetchOutcome = RommMetadataOutcome.failed(
        RommMetadataFetchException(
          stage: 'detail',
          romId: rom.id,
          filename: linkKey,
          cause: e,
        ),
      );
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
