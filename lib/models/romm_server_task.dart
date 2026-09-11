/// One entry of RomM's `GET /api/tasks`: what the server says about a task it
/// knows, including whether it will let a REST caller start it.
///
/// Why this exists at all: NeoStation asked for `scan_library` after every
/// upload and reported it as queued. On a modern server that request comes
/// back 400 and no scan is ever queued (issue #170 carries the on-device log
/// against RomM 5.1.0, where the route's own OpenAPI documents only 200 and
/// 422 — so the 400 is undocumented). RomM's task registry marks `scan_library`
/// `manual_run=False`, and a task whose `can_run_manually` is false is refused
/// with a 400 whatever the caller does, so the app cannot start that scan on
/// any stock server. Rather than guess from a status code, the app now asks
/// what the server will actually run and believes the answer.
///
/// [manualRun] is deliberately nullable: a server (or a proxy) that answers in
/// a shape this parser does not recognise leaves it null, and null means
/// "unknown", never "refused". The caller falls back to trying, exactly as
/// before, when it cannot read the flag — an honest refusal is only claimed
/// when the server said so.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"
class RommServerTask {
  /// The `{name}` of `POST /api/tasks/run/{name}` — the wire contract.
  final String name;

  /// The server's own label, when it sends one. Only used to recognise a
  /// scan-ish task whose name does not say "scan".
  final String title;

  /// `manual_run` as the server reports it, or null when it did not.
  final bool? manualRun;

  /// `enabled` as the server reports it, or null when it did not. A task the
  /// server has switched off is never picked.
  final bool? enabled;

  const RommServerTask({
    required this.name,
    this.title = '',
    this.manualRun,
    this.enabled,
  });

  /// Whether this task is a library scan of some kind.
  ///
  /// Matched on the name (and the title as a fallback) rather than on a fixed
  /// list, so a rename in a later RomM release still resolves. The cleanup
  /// task is excluded by name: it prunes rows, and running it in place of a
  /// scan would be the opposite of what the caller asked for.
  bool get isScan {
    final haystack = '$name $title'.toLowerCase();
    if (haystack.contains('cleanup')) return false;
    return haystack.contains('scan');
  }

  /// Whether the server will start this task for a REST caller. Unknown
  /// ([manualRun] null) counts as runnable — see the class doc.
  bool get runnable => manualRun != false && enabled != false;

  /// Every task in a `GET /api/tasks` body, whatever shape it arrived in.
  ///
  /// RomM has published this registry as a bare list and as an object keyed by
  /// task group across releases, so the walk is shape-tolerant: any nested map
  /// that names a task is taken, anything else is descended into. A body this
  /// finds nothing in yields an empty list; turning that into the "unknown"
  /// every caller works in terms of is `RommService.listServerTasks`' job, one
  /// layer up, since only it knows the body was supposed to hold something.
  static List<RommServerTask> listFrom(dynamic decoded) {
    final out = <RommServerTask>[];
    final seen = <String>{};

    void walk(dynamic node, String? keyHint, int depth) {
      if (depth > 6) return;
      if (node is List) {
        for (final entry in node) {
          walk(entry, keyHint, depth + 1);
        }
        return;
      }
      if (node is! Map) return;
      final task = _taskOf(node, keyHint);
      if (task != null) {
        if (seen.add(task.name)) out.add(task);
        return;
      }
      for (final entry in node.entries) {
        walk(entry.value, entry.key.toString(), depth + 1);
      }
    }

    walk(decoded, null, 0);
    return out;
  }

  /// The scan task to ask for, or null when the server names none it will run.
  ///
  /// A task the server said it will not run manually is never returned, which
  /// is the whole point: that is the `scan_library` refusal, and asking again
  /// would just produce another 400. Preference goes to a task that says
  /// `manual_run: true` over one that says nothing, and then to the order RomM
  /// itself lists them in.
  static RommServerTask? pickScan(List<RommServerTask> tasks) {
    final candidates = tasks.where((t) => t.isScan && t.runnable).toList();
    if (candidates.isEmpty) return null;
    final declared = candidates.where((t) => t.manualRun == true);
    return declared.isNotEmpty ? declared.first : candidates.first;
  }

  /// A task object, or null when this map is not one.
  ///
  /// [keyHint] is the object key the map hung under, which is the task name in
  /// the map-keyed shape. A map with no name at all is not a task.
  static RommServerTask? _taskOf(Map<dynamic, dynamic> map, String? keyHint) {
    String? text(String key) {
      final value = map[key];
      if (value == null) return null;
      final s = value.toString().trim();
      return s.isEmpty ? null : s;
    }

    final named = text('name') ?? text('task_name') ?? text('func_name');
    // A map keyed by task name only counts as a task when it also carries
    // something a task has; otherwise every wrapper object would parse as one.
    final hasTaskFields =
        map.containsKey('manual_run') ||
        map.containsKey('manualRun') ||
        map.containsKey('cron_string') ||
        map.containsKey('enabled') ||
        map.containsKey('title');
    final name = named ?? (hasTaskFields ? keyHint : null);
    if (name == null || name.isEmpty) return null;

    bool? flag(String snake, String camel) {
      final value = map[snake] ?? map[camel];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final lower = value.toLowerCase();
        if (lower == 'true') return true;
        if (lower == 'false') return false;
      }
      return null;
    }

    return RommServerTask(
      name: name,
      title: text('title') ?? text('description') ?? '',
      manualRun: flag('manual_run', 'manualRun'),
      enabled: flag('enabled', 'isEnabled'),
    );
  }

  @override
  String toString() =>
      'RommServerTask(name=$name manual_run=$manualRun enabled=$enabled)';
}

/// How asking the server for a library scan ended.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks", ADR-0014 (chunked ROM upload),
// SPEC-0014 REQ "Scan And Link After Upload"
enum RommScanRequestOutcome {
  /// The server accepted the task; [RommScanRequest.taskName] says which.
  queued,

  /// This login cannot ask (no `tasks.run`). The files are still there and a
  /// scan somebody else starts will index them, so this stays pending.
  notGranted,

  /// A scan is already going — pending for the same reason.
  alreadyRunning,

  /// The request could not be delivered, or was answered by something other
  /// than RomM's own policy: a timeout, an unreachable server, and every
  /// transient status — a proxy's 502/503/504 while RomM restarts, a 429, a
  /// 408. Says nothing about what the server would have done, so also pending.
  /// See [RommScanRequest.isRefusalStatus].
  unavailable,

  /// The server will not let a REST caller start a scan: it names no runnable
  /// scan task, or it answered the one it names with a status that is RomM's
  /// own refusal ([RommScanRequest.isRefusalStatus]). Nothing is pending — the
  /// user has to start the scan from RomM's own web interface.
  refused,
}

/// What [RommScanRequestOutcome] happened, and which task it happened to.
class RommScanRequest {
  final RommScanRequestOutcome outcome;

  /// The task actually asked for, for the log and for the message that names
  /// it. Empty when nothing was sent.
  final String taskName;

  /// The id the server gave the queued task, when it gave one.
  final String? taskId;

  const RommScanRequest(this.outcome, {this.taskName = '', this.taskId});

  /// The id a scan watch may correlate against, or null when the server gave
  /// none.
  ///
  /// [taskId] is not always an id. `RommService.runTask` answers `id ?? name`
  /// so that a caller can tell "accepted" from "gated", which means a 2xx
  /// carrying no parseable id yields the task *name* here. Correlating against
  /// that stand-in rejects the very row it was meant to match: the finished
  /// entry carries the server's real id, the two differ, and the watch reports
  /// "no scan is running" instead of the counts it just watched accumulate.
  /// Null is the honest answer — it falls back to the uncorrelated path a
  /// web-UI-started scan already uses.
  String? get correlationId =>
      taskId == null || taskId!.isEmpty || taskId == taskName ? null : taskId;

  /// Whether a failed `POST /api/tasks/run/{name}` carrying [status] is RomM
  /// refusing to run the task, as opposed to something transient between here
  /// and it.
  ///
  /// [RommScanRequestOutcome.refused] tells the user the files are uploaded
  /// and nothing more will happen until they start a scan from RomM's own web
  /// interface — advice about a permanent policy. A reverse proxy answering
  /// 502 while RomM restarts, a 503, a 504, a rate-limiting 429 say nothing
  /// about that policy, and `runTask`'s own doc already records that a proxy
  /// may answer for RomM. So this is an allowlist of the statuses RomM itself
  /// answers a refusal with, and everything else — every 5xx, 408, 429, an
  /// expired 401, and any status not listed here — stays transient and is
  /// reported as pending, which errs towards waiting rather than towards
  /// sending the user to fix a server that was merely busy.
  ///
  /// 403 never reaches this: `runTask` maps it to
  /// [RommErrorKind.scopeDenied] and the caller reports it as not granted.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Maintenance Tasks", ADR-0014 (chunked ROM upload),
  // SPEC-0014 REQ "Scan And Link After Upload"
  static bool isRefusalStatus(int? status) =>
      status != null && _refusalStatuses.contains(status);

  /// 400 is the refusal issue #170 recorded (a task whose `manual_run` is
  /// false); 404 and 405 are a task name or a route this RomM does not have;
  /// 422 is the route's own documented rejection of what was asked. Asking
  /// again changes none of them.
  ///
  /// 409 is deliberately absent. A conflict is usually transient, and it is
  /// barely reachable here anyway: `runTask` maps a body that says the task is
  /// already running to [RommErrorKind.taskBusy] before any status is
  /// consulted, so a 409 only arrives when its wording escaped that check —
  /// and calling *that* a permanent policy is a guess.
  static const Set<int> _refusalStatuses = {400, 404, 405, 422};

  /// True when a scan is now expected to happen, or already is.
  bool get scanExpected =>
      outcome == RommScanRequestOutcome.queued ||
      outcome == RommScanRequestOutcome.alreadyRunning;

  @override
  String toString() =>
      'RommScanRequest(${outcome.name} task=$taskName id=$taskId)';
}
