import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:neostation/models/romm_search_result.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

/// Which of the two fix-up flows a [RommFixMatchController] is driving.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
enum RommFixMode {
  /// "Fix match on RomM": search the server's metadata providers and write the
  /// chosen candidate's provider ids back onto the RomM entry.
  match,

  /// "Change cover": list cover art and write the chosen URL as `url_cover`.
  cover,
}

/// Where the fix-up surface stands.
enum RommFixStatus {
  /// Nothing searched yet.
  idle,

  /// A search is in flight.
  loading,

  /// [RommFixMatchController.results] answers the last search.
  ready,

  /// The last search failed; see [RommFixMatchController.lastErrorKind].
  error,

  /// A candidate is being written to the server. No second write starts while
  /// this is the status.
  applying,
}

/// One row the fix-up surface offers, flattened from either a
/// [RommSearchResult] or a [RommCoverResult] so the dialog paints one kind of
/// row for both flows.
class RommFixCandidate {
  /// The headline — the candidate's game name.
  final String name;

  /// A second line (the provider ids, or the cover's source name), or null.
  final String? detail;

  /// Art to paint beside the row, or null when the candidate has none.
  final String? previewUrl;

  /// Set in [RommFixMode.match]: the candidate to apply.
  final RommSearchResult? match;

  /// Set in [RommFixMode.cover]: the URL to write as `url_cover`.
  final String? coverUrl;

  const RommFixCandidate({
    required this.name,
    this.detail,
    this.previewUrl,
    this.match,
    this.coverUrl,
  });

  /// Builds a row for a metadata candidate; the detail line names the
  /// providers the candidate came from, which is how two same-named entries
  /// are told apart.
  factory RommFixCandidate.fromMatch(RommSearchResult result) {
    final providers = result.providerIds.entries
        .map((e) => '${e.key.replaceAll('_id', '')} ${e.value}')
        .join(' · ');
    return RommFixCandidate(
      name: result.name,
      detail: providers.isEmpty ? null : providers,
      previewUrl: result.coverUrl,
      match: result,
    );
  }

  /// Builds a row for one cover image.
  factory RommFixCandidate.fromCover(RommCoverResult cover) => RommFixCandidate(
    name: cover.name,
    detail: null,
    previewUrl: cover.previewUrl,
    coverUrl: cover.url,
  );
}

/// Runs one search against the server's metadata providers.
typedef RommFixSearch = Future<List<RommFixCandidate>> Function(String term);

/// Writes [candidate] to the RomM entry. Returns false when the write was
/// refused locally (the `romsWrite` group is denied), which is not an error.
typedef RommFixApplier = Future<bool> Function(RommFixCandidate candidate);

/// Re-reads the game's metadata from RomM after a successful write — the
/// replace-mode fetch in the app, a counter in tests.
typedef RommFixRefresher = Future<void> Function();

/// The search-and-apply logic behind "Fix match on RomM" and "Change cover",
/// kept out of the dialog so the serial guard, the single refresh after a
/// write, and the re-entrancy guard that keeps a second button press from
/// writing twice are unit-testable with hand-written fakes.
///
/// The dialog owns focus, layout, and the confirmation step; this owns what
/// reaches the server.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
class RommFixMatchController extends ChangeNotifier {
  static final _log = LoggerService.instance;

  final RommFixMode mode;

  /// The RomM ROM being fixed — logged with every failure so a report names
  /// the entry that was being written.
  final int romId;

  final RommFixSearch search;
  final RommFixApplier applyCandidate;
  final RommFixRefresher refreshLocal;

  RommFixMatchController({
    required this.mode,
    required this.romId,
    required this.search,
    required this.applyCandidate,
    required this.refreshLocal,
  });

  List<RommFixCandidate> _results = const [];
  RommFixStatus _status = RommFixStatus.idle;
  RommErrorKind? _lastErrorKind;
  Object? _lastError;
  bool _lastApplyFailed = false;
  int _requestSerial = 0;
  bool _disposed = false;

  List<RommFixCandidate> get results => _results;
  RommFixStatus get status => _status;

  /// The sentinel of the last failed search, so the dialog can show "this
  /// server has no metadata source" rather than a generic failure.
  RommErrorKind? get lastErrorKind => _lastErrorKind;

  /// The raw failure behind [lastErrorKind], for the dialog's log line.
  Object? get lastError => _lastError;

  /// True when the last [apply] reached the server and did not take.
  bool get lastApplyFailed => _lastApplyFailed;

  /// True while a write is in flight — the dialog must not start another.
  bool get isApplying => _status == RommFixStatus.applying;

  /// Runs [term] against the server, dropping a response that a newer search
  /// has already superseded.
  Future<void> searchNow(String term) async {
    if (_status == RommFixStatus.applying) return;
    final serial = ++_requestSerial;
    _status = RommFixStatus.loading;
    _lastApplyFailed = false;
    if (!_disposed) notifyListeners();

    try {
      final found = await search(term.trim());
      if (_disposed || serial != _requestSerial) return;
      _results = List.unmodifiable(found);
      _lastErrorKind = null;
      _lastError = null;
      _status = RommFixStatus.ready;
    } catch (e, st) {
      if (_disposed || serial != _requestSerial) return;
      _results = const [];
      _lastError = e;
      _lastErrorKind = e is RommException ? e.kind : RommErrorKind.other;
      _status = RommFixStatus.error;
      _log.e(
        'RomM fix-up search failed: mode=${mode.name} rom=$romId '
        'query="${term.trim()}" kind=${_lastErrorKind?.name}',
        error: e,
        stackTrace: st,
      );
    }
    notifyListeners();
  }

  /// Writes [candidate] to the server and, only when the server took it,
  /// refreshes the local metadata exactly once.
  ///
  /// Returns false — with nothing refreshed — when a write is already in
  /// flight, when the service refused the write locally, or when it threw. The
  /// in-flight guard is the second half of the protection around this write:
  /// the dialog confirms first, and a repeated button press that slips past
  /// the confirmation still cannot send a second `PUT`.
  // Governing: ADR-0019, SPEC-0018 REQ "Fix Match In The Picker"
  Future<bool> apply(RommFixCandidate candidate) async {
    if (_status == RommFixStatus.applying) {
      _log.w(
        'RomM fix-up apply ignored: mode=${mode.name} rom=$romId '
        'reason=already_applying',
      );
      return false;
    }
    _status = RommFixStatus.applying;
    _lastApplyFailed = false;
    if (!_disposed) notifyListeners();

    var applied = false;
    try {
      applied = await applyCandidate(candidate);
      if (!applied) {
        _log.w(
          'RomM fix-up apply refused: mode=${mode.name} rom=$romId '
          'candidate="${candidate.name}"',
        );
      }
    } catch (e, st) {
      _lastError = e;
      _lastErrorKind = e is RommException ? e.kind : RommErrorKind.other;
      _log.e(
        'RomM fix-up apply failed: mode=${mode.name} rom=$romId '
        'candidate="${candidate.name}"',
        error: e,
        stackTrace: st,
      );
    }

    if (applied) {
      // The local row is only replaced once the server confirmed the write,
      // and exactly once per apply: a replace-mode fetch overwrites the user's
      // local metadata, so it must not run for a write that did not land.
      // Governing: ADR-0005 (RomM metadata source), SPEC-0018 REQ "Fix Match In The Picker"
      try {
        await refreshLocal();
      } catch (e, st) {
        _log.e(
          'RomM fix-up refresh failed after a successful write: '
          'mode=${mode.name} rom=$romId',
          error: e,
          stackTrace: st,
        );
      }
      _log.i('RomM fix-up applied: mode=${mode.name} rom=$romId');
    }

    _lastApplyFailed = !applied;
    _status = RommFixStatus.ready;
    if (!_disposed) notifyListeners();
    return applied;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
