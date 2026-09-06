import 'dart:async';

/// Debounces a stream of typed search terms into one asynchronous [run] per
/// pause, and drops the outcome of any run that a newer term has overtaken.
///
/// Every [submit] restarts a [delay] timer; when it fires, [run] is called
/// with the most recent term and the request is stamped with a monotonically
/// increasing id. When the run completes, [onResult] (or [onError]) is called
/// only if no newer request has been issued since — so a slow response to
/// "ch" can never land after the response to "chrono". Callers that mutate
/// shared state inside [run] itself need their own guard on that side; this
/// class only vouches for what it surfaces through its callbacks.
///
/// An empty term is a "clear", and a cleared field should show the unfiltered
/// list at once rather than 400 ms later, so `submit('')` cancels any pending
/// timer and runs immediately.
///
/// Free of Flutter widgets so it can be driven under `fakeAsync`.
// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "In-Platform Search Field", REQ "Concurrency Safety"
class DebouncedSearch<T> {
  DebouncedSearch({
    required this.delay,
    required this.run,
    this.onResult,
    this.onError,
  });

  /// How long the term has to sit unchanged before it is searched.
  final Duration delay;

  /// Performs the search for a settled term.
  final Future<T> Function(String term) run;

  /// Receives the outcome of a run that is still the latest request.
  final void Function(String term, T result)? onResult;

  /// Receives the failure of a run that is still the latest request. When
  /// null the error propagates out of the run's future instead, so a failure
  /// is never swallowed either way.
  final void Function(String term, Object error, StackTrace stackTrace)?
  onError;

  Timer? _timer;
  String? _pending;
  int _latestId = 0;

  /// Id of the most recently issued request (0 before the first).
  int get latestId => _latestId;

  /// Whether a run with [id] has been overtaken by a newer request.
  bool isStale(int id) => id != _latestId;

  /// Whether a term is waiting on the timer.
  bool get hasPending => _timer?.isActive ?? false;

  /// Queues [term] to be searched once typing pauses for [delay]; an empty
  /// term runs at once (see the class doc).
  void submit(String term) {
    _timer?.cancel();
    _pending = term;
    if (term.isEmpty) {
      _fire();
      return;
    }
    _timer = Timer(delay, _fire);
  }

  /// Runs the pending term now instead of waiting out the timer. No-op when
  /// nothing is pending.
  void flush() {
    if (!hasPending) return;
    _timer?.cancel();
    _fire();
  }

  /// Drops any pending term and marks every in-flight run stale, so nothing
  /// issued so far can still reach [onResult]. Call from `dispose`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _latestId++;
  }

  void _fire() {
    _timer = null;
    final term = _pending;
    if (term == null) return;
    _pending = null;
    final id = ++_latestId;
    // Not awaited: the caller keeps typing while this is on the wire, and the
    // id check on completion is what keeps the two in order.
    unawaited(_execute(id, term));
  }

  Future<void> _execute(int id, String term) async {
    try {
      final result = await run(term);
      if (isStale(id)) return;
      onResult?.call(term, result);
    } catch (error, stackTrace) {
      // A failure the user has already typed past is dropped on purpose: the
      // request that superseded it reports its own outcome, and surfacing a
      // stale error would describe a search that is no longer on screen.
      if (isStale(id)) return;
      final handler = onError;
      if (handler == null) rethrow;
      handler(term, error, stackTrace);
    }
  }
}
