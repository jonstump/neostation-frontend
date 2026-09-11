// What a RomM library scan is doing, as `GET /api/tasks/status` reports it.
//
// The four states are the ones the user could not tell apart before (issue
// #236): a scan that is running, one that finished having found something,
// one that finished having found nothing, and one that failed. They are read
// from the server's own status list, so a scan started from RomM's web UI is
// reported exactly like one NeoStation queued — which matters, because on a
// stock server the web UI is the only place a library scan can be started
// from at all (see `RommServerTask`).
//
// Shape-tolerant on purpose: the status body has been an object of queues
// (`running`/`queued`/`finished`/`failed`) whose entries carry `task_type`, a
// status and a `meta.scan_stats`. Anything this parser cannot read leaves the
// counts at zero and the state falls back to what the queue name said.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"

/// The four outcomes a watched scan can be in.
enum RommScanState {
  /// Still going. Determinate whenever the server reported a total.
  running,

  /// Finished, and it indexed or identified something.
  doneWithResults,

  /// Finished, and it found nothing new — the answer to "did it even run?".
  doneWithNothing,

  /// The server reported the scan as failed.
  failed,
}

/// One answer to `GET /api/tasks/status`: whether the server answered at all,
/// and the scan it named if it did.
///
/// The distinction the watcher cannot work without. A single null used to
/// stand for six different things — the scope gate, a 403, any non-2xx, a
/// timeout, a socket error, and a 200 naming no scan — and the watcher read
/// every one of them as "there is no scan running on the server", which is a
/// claim the server never made. One failed poll out of hundreds ended the
/// watch on it, and a server too old to have the route 404'd into a
/// permanently confident denial.
///
/// [answered] is true only when the server's own body was read. [status] is
/// then the scan it named, or null when it named none — which is the one
/// genuine "no scan is running".
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"
class RommScanPoll {
  /// True when the server answered and its body was parsed.
  final bool answered;

  /// The scan the server named, or null when it named none (and always null
  /// when it did not answer).
  final RommScanTaskStatus? status;

  /// The server answered: [status] is the scan it named, or null for none.
  const RommScanPoll.answered(this.status) : answered = true;

  /// The question could not be asked, or the answer could not be read.
  const RommScanPoll.unanswered() : answered = false, status = null;

  @override
  String toString() =>
      answered ? 'RommScanPoll(answered $status)' : 'RommScanPoll(unanswered)';
}

class RommScanTaskStatus {
  /// The server's id for the job, for the log line only.
  final String id;

  /// The server's own status word, lowercased ('running', 'finished', …), or
  /// the queue it was listed under. Empty when it said neither.
  final String status;

  /// True while the scan is still going.
  final bool ongoing;

  /// `scan_stats`, all zero when the server sent none.
  final int totalRoms;
  final int scannedRoms;
  final int newRoms;
  final int identifiedRoms;

  /// The newest timestamp the entry carried, used only to order entries.
  final DateTime? timestamp;

  const RommScanTaskStatus({
    this.id = '',
    this.status = '',
    this.ongoing = false,
    this.totalRoms = 0,
    this.scannedRoms = 0,
    this.newRoms = 0,
    this.identifiedRoms = 0,
    this.timestamp,
  });

  /// Which of the four the user is told about.
  RommScanState get state {
    if (ongoing) return RommScanState.running;
    if (_failedWords.contains(status)) return RommScanState.failed;
    return (newRoms + identifiedRoms) > 0
        ? RommScanState.doneWithResults
        : RommScanState.doneWithNothing;
  }

  /// The determinate fraction, or null when the server has not said how many
  /// ROMs there are yet. Null is not a bar of zero: the caller decides how to
  /// render "running, total unknown" (see #232).
  double? get fraction {
    if (totalRoms <= 0) return null;
    final value = scannedRoms / totalRoms;
    return value.clamp(0.0, 1.0);
  }

  static const _failedWords = {'failed', 'failure', 'error', 'errored'};
  static const _ongoingWords = {
    'running',
    'started',
    'starting',
    'queued',
    'pending',
    'in_progress',
    'scheduled',
    'deferred',
  };

  /// The scan entry a watcher should report, or null when the body names no
  /// scan at all.
  ///
  /// A scan that is still going wins over a finished one whatever the
  /// timestamps say — it is by definition the newest — and finished entries
  /// are ordered by the latest timestamp they carry, falling back to the order
  /// the server listed them in.
  static RommScanTaskStatus? newestScanFrom(dynamic decoded) {
    final found = <RommScanTaskStatus>[];

    void walk(dynamic node, String? keyHint, int depth) {
      if (depth > 6) return;
      if (node is List) {
        for (final entry in node) {
          walk(entry, keyHint, depth + 1);
        }
        return;
      }
      if (node is! Map) return;
      if (_isScanEntry(node)) {
        found.add(_entryOf(node, keyHint));
        return;
      }
      for (final entry in node.entries) {
        walk(entry.value, entry.key.toString(), depth + 1);
      }
    }

    walk(decoded, null, 0);
    if (found.isEmpty) return null;

    RommScanTaskStatus best = found.first;
    for (final candidate in found.skip(1)) {
      if (_isNewer(candidate, best)) best = candidate;
    }
    return best;
  }

  static bool _isNewer(RommScanTaskStatus a, RommScanTaskStatus b) {
    if (a.ongoing != b.ongoing) return a.ongoing;
    final at = a.timestamp;
    final bt = b.timestamp;
    if (at != null && bt != null) return at.isAfter(bt);
    if (at != null) return true;
    return false;
  }

  static bool _isScanEntry(Map<dynamic, dynamic> map) {
    final type = (map['task_type'] ?? map['taskType'] ?? map['type'])
        ?.toString()
        .toLowerCase();
    if (type == null) return false;
    return type.contains('scan');
  }

  static RommScanTaskStatus _entryOf(
    Map<dynamic, dynamic> map,
    String? keyHint,
  ) {
    final stats = _statsOf(map);
    final statusWord = (map['status'] ?? map['state'] ?? keyHint ?? '')
        .toString()
        .toLowerCase()
        .trim();

    final ongoingField = map['ongoing'] ?? map['is_running'] ?? map['running'];
    final bool ongoing;
    if (ongoingField is bool) {
      ongoing = ongoingField;
    } else {
      ongoing = _ongoingWords.contains(statusWord);
    }

    return RommScanTaskStatus(
      id: (map['id'] ?? map['job_id'] ?? map['task_id'] ?? '').toString(),
      status: statusWord,
      ongoing: ongoing,
      totalRoms: _intOf(stats, const ['total_roms', 'totalRoms', 'total']),
      scannedRoms: _intOf(stats, const [
        'scanned_roms',
        'scannedRoms',
        'scanned',
      ]),
      newRoms: _intOf(stats, const ['new_roms', 'newRoms', 'added_roms']),
      identifiedRoms: _intOf(stats, const [
        'identified_roms',
        'identifiedRoms',
        'matched_roms',
      ]),
      timestamp: _timestampOf(map),
    );
  }

  /// `meta.scan_stats`, or the stats at whatever level this server put them.
  static Map<dynamic, dynamic> _statsOf(Map<dynamic, dynamic> map) {
    final meta = map['meta'];
    if (meta is Map) {
      final stats = meta['scan_stats'] ?? meta['scanStats'];
      if (stats is Map) return stats;
      if (meta.containsKey('total_roms') || meta.containsKey('scanned_roms')) {
        return meta;
      }
    }
    final direct = map['scan_stats'] ?? map['scanStats'] ?? map['stats'];
    if (direct is Map) return direct;
    // The entry itself, but only when it carries a count this parser
    // recognises as a scan's. Reading the whole entry unconditionally would
    // take an unrelated top-level `total` — a queue length, a page size — for
    // a ROM count and report progress out of it.
    if (map.keys.any((k) => _statKeys.contains(k.toString()))) return map;
    return const {};
  }

  /// The count keys that make a map scan stats. A bare `total` is not one of
  /// them: it is the field most likely to mean something else entirely.
  static const _statKeys = {
    'total_roms',
    'totalRoms',
    'scanned_roms',
    'scannedRoms',
    'scanned',
    'new_roms',
    'newRoms',
    'added_roms',
    'identified_roms',
    'identifiedRoms',
    'matched_roms',
  };

  static int _intOf(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  static DateTime? _timestampOf(Map<dynamic, dynamic> map) {
    const keys = [
      'ended_at',
      'finished_at',
      'started_at',
      'enqueued_at',
      'created_at',
      'updated_at',
    ];
    DateTime? newest;
    for (final key in keys) {
      final value = map[key];
      DateTime? parsed;
      if (value is String) {
        parsed = DateTime.tryParse(value);
      } else if (value is num) {
        parsed = DateTime.fromMillisecondsSinceEpoch(
          value > 100000000000 ? value.toInt() : (value * 1000).toInt(),
          isUtc: true,
        );
      }
      if (parsed == null) continue;
      if (newest == null || parsed.isAfter(newest)) newest = parsed;
    }
    return newest;
  }

  @override
  String toString() =>
      'RommScanTaskStatus(id=$id status=$status ongoing=$ongoing '
      'scanned=$scannedRoms/$totalRoms new=$newRoms '
      'identified=$identifiedRoms)';
}
