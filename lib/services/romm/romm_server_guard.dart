import '../../models/romm_metadata_fetch.dart';
import '../../models/romm_scrape_step.dart';
import '../logger_service.dart';
import '../romm_service.dart';
import 'romm_metadata_fetch.dart';

/// Keeps a bulk scrape from hammering a RomM server that is down or rate
/// limiting, and from reporting such a server as "RomM has nothing".
///
/// One guard lives for one bulk run and is shared by every worker. Each RomM
/// step asks [waitTurn] before it sends anything and hands its result to
/// [record] afterwards.
///
/// The rule is the per-system pass's, stated once here for the scrape chain:
/// a game contributes **at most one** increment — a transport-class outcome
/// (the detail GET timed out, hit a socket or TLS error, a `5xx` or a `429`,
/// or a media download failed that way) counts once however many requests it
/// cost — and only a *fully* successful game (written, no media failure, no
/// transport flag) resets the streak. A `404`, a game that is not linked, a
/// `404` on one media file and a parse error say nothing about the server's
/// health: they neither count nor reset.
///
/// After [threshold] consecutive transport-class games the guard is
/// [tripped]: [record] stops anything further from being asked of RomM for the
/// rest of the run (the caller answers [RommScrapeStepResult.serverSkipped]
/// without a request) and ScreenScraper, when set up, carries on with the
/// remaining games. A `429` carrying `Retry-After` pauses every worker for that
/// long, capped at [RommService.retryAfterCap], and repeated rate limiting
/// counts toward the trip like any other transport failure.
class RommServerGuard {
  static final _defaultLog = LoggerService.instance;

  /// Consecutive transport-class games that trip the guard. The per-system
  /// pass's own constant, so the two cannot drift apart.
  static const int defaultThreshold =
      RommMetadataFetch.maxConsecutiveTransportFailures;

  final int threshold;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final bool Function() _shouldStop;
  final Duration _pausePollInterval;
  final LoggerService _log;

  int _streak = 0;
  int _transportFailures = 0;
  int _pauses = 0;
  int _skipped = 0;
  Duration _pausedTotal = Duration.zero;
  DateTime? _pauseUntil;
  bool _tripped = false;

  RommServerGuard({
    this.threshold = defaultThreshold,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    bool Function()? shouldStop,
    Duration pausePollInterval = const Duration(milliseconds: 50),
    LoggerService? log,
  }) : _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _shouldStop = shouldStop ?? (() => false),
       _pausePollInterval = pausePollInterval,
       _log = log ?? _defaultLog;

  /// True once [threshold] consecutive games hit a transport-class failure.
  bool get tripped => _tripped;

  /// True when the run was cancelled (the injected stop check).
  bool get stopRequested => _shouldStop();

  /// Games whose outcome counted toward the breaker, over the whole run.
  int get transportFailures => _transportFailures;

  /// Pauses armed by a `429`'s `Retry-After`.
  int get pauses => _pauses;

  /// Games answered [RommScrapeStepResult.serverSkipped] after the trip.
  int get skipped => _skipped;

  /// Time workers spent waiting out pauses, summed over workers.
  Duration get pausedTotal => _pausedTotal;

  /// Records that one game was skipped without a request because the guard
  /// had tripped. Returns the result to hand back.
  RommScrapeStepResult skip() {
    _skipped++;
    return const RommScrapeStepResult.serverSkipped();
  }

  /// Waits out an armed pause before a worker sends anything. Returns at once
  /// when no pause is armed, and early when the run is cancelled or the guard
  /// trips while waiting; the caller re-checks [tripped] afterwards.
  Future<void> waitTurn() async {
    while (!_tripped && !_shouldStop()) {
      final remaining = _pauseUntil?.difference(_clock()) ?? Duration.zero;
      if (remaining <= Duration.zero) return;
      final slice = remaining > _pausePollInterval
          ? _pausePollInterval
          : remaining;
      await _sleep(slice);
      _pausedTotal += slice;
    }
  }

  /// Feeds the guard one game's result. Never throws.
  void record(RommScrapeStepResult result) {
    // A skip made no request, so it says nothing about the server.
    if (result.status == RommScrapeStepStatus.serverSkipped) return;
    final outcome = result.outcome;
    final fullySuccessful =
        outcome != null &&
        (outcome.kind == RommMetadataOutcomeKind.filled ||
            outcome.kind == RommMetadataOutcomeKind.replaced) &&
        outcome.mediaFailed == 0 &&
        !outcome.transportClass;
    if (fullySuccessful) {
      _streak = 0;
      return;
    }
    if (!result.serverUnavailable) return;

    _streak++;
    _transportFailures++;
    final retryAfter = outcome?.retryAfter;
    if (retryAfter != null) _armPause(retryAfter);
    if (!_tripped && _streak >= threshold) {
      _tripped = true;
      _log.w(
        'RomM server guard tripped: $threshold consecutive transport '
        'failures; RomM is skipped for the rest of this run',
      );
    }
  }

  void _armPause(Duration retryAfter) {
    final capped = retryAfter > RommService.retryAfterCap
        ? RommService.retryAfterCap
        : retryAfter;
    if (capped <= Duration.zero) return;
    final until = _clock().add(capped);
    if (_pauseUntil == null || until.isAfter(_pauseUntil!)) {
      _pauseUntil = until;
    }
    _pauses++;
  }
}
