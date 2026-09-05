import 'dart:async';

import 'package:flutter/foundation.dart';

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
  final Duration debounce;
  final int pageLimit;

  /// A result to pin at the top of the list and pre-select — the search
  /// screen opens the picker on the remote ROM the user was already looking at.
  final RommRom? preselected;

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
    this.preselected,
    this.debounce = const Duration(milliseconds: 350),
    this.pageLimit = 25,
  });

  List<int> _platformIds = const [];
  List<RommRom> _results = const [];
  RommMatchPickerStatus _status = RommMatchPickerStatus.idle;
  RommMatchSearchException? _lastError;
  int? _currentRomId;
  String _prefilledQuery = '';
  String? _cleanedQuery;
  Timer? _debounceTimer;
  int _requestSerial = 0;
  bool _disposed = false;

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

  /// Index of [preselected] within [results], or -1.
  int get preselectedIndex {
    final pinned = preselected;
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
    final pinned = preselected;
    if (pinned == null) return items;
    if (items.any((r) => r.id == pinned.id)) return items;
    return [pinned, ...items];
  }

  /// Writes the manual row for [rom] under [linkKey] and invalidates the
  /// game's sync state exactly once. Returns false — with nothing invalidated
  /// — when the repository reported the write failed.
  // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
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
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
