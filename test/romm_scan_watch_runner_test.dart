import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_scan_task_status.dart';
import 'package:neostation/screens/romm_screen/romm_scan_watch_runner.dart';
import 'package:neostation/services/global_notification_service.dart';

/// The scan watcher's four states, and the row each ends on.
///
/// Issue #236's actual complaint was that the user could not tell which of
/// them had happened. These drive the watcher's own loop — the poll and the
/// sleep are the seams — so the message, the bar and the notification type
/// are measured where the user would see them.
///
/// The terminal rows must carry **no** progress bar: that is an acceptance
/// criterion of #236 and the shape #228/#229 fixed three runners for.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Maintenance Tasks"
void main() {
  const strings = RommScanWatchStrings(
    waiting: 'waiting',
    progressTemplate: '{done}/{total}',
    progressUnknown: 'scanning',
    resultsTemplate: 'new {new} identified {identified}',
    nothing: 'nothing',
    failed: 'failed',
    none: 'none',
    timeoutTemplate: 'timeout {minutes}',
    unreachable: 'unreachable',
  );

  late GlobalNotificationService notifications;

  setUp(() {
    notifications = GlobalNotificationService();
    notifications.notifier.value = [];
  });

  tearDown(() => GlobalNotificationService().notifier.value = []);

  GlobalNotificationData row() => notifications.notifier.value.firstWhere(
    (n) => n.id == RommScanWatchRunner.notificationId,
  );

  /// Answers each poll from [answers] in order, then repeats the last one.
  Future<void> Function(Duration) noSleep() => (_) async {};

  Future<void> watch(
    List<RommScanPoll> answers, {
    bool awaitStart = false,
    String? expectTaskId,
    Duration maxDuration = const Duration(minutes: 20),
    Duration startGrace = const Duration(seconds: 15),
    int pollFailureTolerance = 5,
    void Function()? onPoll,
  }) {
    var index = 0;
    return RommScanWatchRunner.runDetached(
      strings: strings,
      poll: () async {
        onPoll?.call();
        final answer = answers[index.clamp(0, answers.length - 1)];
        index++;
        return answer;
      },
      awaitStart: awaitStart,
      expectTaskId: expectTaskId,
      interval: Duration.zero,
      startGrace: startGrace,
      maxDuration: maxDuration,
      pollFailureTolerance: pollFailureTolerance,
      sleep: noSleep(),
    );
  }

  const running = RommScanTaskStatus(
    id: 'a',
    status: 'running',
    ongoing: true,
    totalRoms: 200,
    scannedRoms: 50,
  );
  const finishedWithResults = RommScanTaskStatus(
    id: 'a',
    status: 'finished',
    totalRoms: 200,
    scannedRoms: 200,
    newRoms: 4,
    identifiedRoms: 2,
  );
  const finishedWithNothing = RommScanTaskStatus(
    id: 'a',
    status: 'finished',
    totalRoms: 200,
    scannedRoms: 200,
  );
  const failed = RommScanTaskStatus(id: 'a', status: 'failed');

  // The poll answers the watch actually sees. `answered(null)` is the server
  // saying it is running no scan; `unanswered` is the server not saying —
  // the distinction the watch used to collapse.
  const nowRunning = RommScanPoll.answered(running);
  const withResults = RommScanPoll.answered(finishedWithResults);
  const withNothing = RommScanPoll.answered(finishedWithNothing);
  const didFail = RommScanPoll.answered(failed);
  const noScan = RommScanPoll.answered(null);
  const unanswered = RommScanPoll.unanswered();

  test('a running scan shows a determinate bar', () async {
    var seen = <double?>[];
    await watch(
      [nowRunning, withNothing],
      onPoll: () {
        final rows = notifications.notifier.value.where(
          (n) => n.id == RommScanWatchRunner.notificationId,
        );
        if (rows.isNotEmpty) seen.add(rows.first.progress);
      },
    );
    // The first poll sees the "waiting" row at zero; the second sees the
    // running row this test is about.
    expect(seen, [0.0, 0.25]);
  });

  test('a running scan with no total still says it is running', () async {
    const noTotal = RommScanTaskStatus(
      id: 'a',
      status: 'running',
      ongoing: true,
    );
    final messages = <String>[];
    final bars = <double?>[];
    await watch(
      [const RommScanPoll.answered(noTotal), withNothing],
      onPoll: () {
        final rows = notifications.notifier.value.where(
          (n) => n.id == RommScanWatchRunner.notificationId,
        );
        if (rows.isNotEmpty) {
          messages.add(rows.first.message);
          bars.add(rows.first.progress);
        }
      },
    );
    expect(messages, ['waiting', 'scanning']);
    // An unknown total is an explicit zero, never a null that would clear the
    // bar out from under a pass that is still going. Issue #232.
    expect(bars, [0.0, 0.0]);
  });

  test('done with results names the counts, with no bar', () async {
    await watch([withResults]);
    final end = row();
    expect(end.message, 'new 4 identified 2');
    expect(end.type, GlobalNotificationType.success);
    expect(end.progress, isNull, reason: 'a terminal row carries no bar');
    expect(end.ongoing, isFalse);
  });

  test('done with nothing is its own answer, with no bar', () async {
    await watch([withNothing]);
    final end = row();
    expect(end.message, 'nothing');
    expect(end.type, GlobalNotificationType.info);
    expect(end.progress, isNull);
    expect(end.ongoing, isFalse);
  });

  test('a failed scan reports the failure, with no bar', () async {
    await watch([didFail]);
    final end = row();
    expect(end.message, 'failed');
    expect(end.type, GlobalNotificationType.error);
    expect(end.progress, isNull);
  });

  test('a running scan that ends clears the bar it was showing', () async {
    await watch([nowRunning, nowRunning, withResults]);
    final end = row();
    expect(end.message, 'new 4 identified 2');
    expect(
      end.progress,
      isNull,
      reason: 'the running fraction must not survive into the summary',
    );
  });

  test('no scan on the server says so rather than inventing one', () async {
    await watch([noScan]);
    final end = row();
    expect(end.message, 'none');
    expect(end.progress, isNull);
    expect(end.ongoing, isFalse);
  });

  test(
    'a scan just queued waits for it rather than reporting the last one',
    () async {
      var polls = 0;
      await watch(
        [withResults, withResults, nowRunning, withNothing],
        awaitStart: true,
        onPoll: () => polls++,
      );
      expect(
        polls,
        4,
        reason: 'the finished rows before the scan started were not believed',
      );
      expect(row().message, 'nothing');
    },
  );

  test('a watch that outlives its cap stops with an honest row', () async {
    await watch([nowRunning], maxDuration: Duration.zero);
    final end = row();
    expect(end.message, 'timeout 0');
    expect(end.progress, isNull);
    expect(end.ongoing, isFalse);
  });

  test('a row the user dismissed is not resurrected', () async {
    // `update` no-ops on a missing id, which is what keeps a summary from
    // reappearing in the bell after the user closed the running row. #231.
    await RommScanWatchRunner.runDetached(
      strings: strings,
      poll: () async {
        notifications.dismiss(RommScanWatchRunner.notificationId);
        return withResults;
      },
      interval: Duration.zero,
      sleep: (_) async {},
    );
    expect(notifications.notifier.value, isEmpty);
  });

  // ── A poll that could not be asked is not an answer ──────────────────────
  // The watch reads up to four hundred polls; one of them failing is a
  // proxy hiccup, not the server saying it is running no scan. Reporting the
  // second for the first is exactly the false certainty issue #236 is about.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"

  test('one unanswered poll does not end a running watch', () async {
    var polls = 0;
    await watch([
      nowRunning,
      unanswered,
      nowRunning,
      withResults,
    ], onPoll: () => polls++);
    expect(polls, 4, reason: 'the failed poll was waited out, not believed');
    final end = row();
    expect(
      end.message,
      'new 4 identified 2',
      reason: 'a poll that did not answer must not end the watch on "none"',
    );
  });

  test('the first unanswered poll of a status check is not terminal', () async {
    // The "Scan status" row passes awaitStart: false and so has no grace at
    // all — before the split, its very first bad poll was terminal.
    await watch([unanswered, nowRunning, withNothing]);
    expect(row().message, 'nothing');
  });

  test('a run of unanswered polls says so, and never says "none"', () async {
    var polls = 0;
    await watch([unanswered], pollFailureTolerance: 3, onPoll: () => polls++);
    final end = row();
    expect(end.message, 'unreachable');
    expect(
      end.message,
      isNot('none'),
      reason: 'giving up must not claim the server said there was no scan',
    );
    expect(polls, 3, reason: 'it gives up after the tolerance, not before');
    expect(end.progress, isNull);
    expect(end.ongoing, isFalse);
  });

  test('an unanswered run does not consume the whole cap', () async {
    // A server with no /api/tasks/status at all (404 on every poll) ends in
    // seconds on the honest row rather than polling for twenty minutes.
    var polls = 0;
    await watch([unanswered], onPoll: () => polls++);
    expect(polls, 5);
    expect(row().message, 'unreachable');
  });

  test('unanswered polls in between do not add up to a run', () async {
    await watch([
      unanswered,
      nowRunning,
      unanswered,
      nowRunning,
      unanswered,
      withNothing,
    ], pollFailureTolerance: 2);
    expect(
      row().message,
      'nothing',
      reason: 'the counter resets on every poll the server does answer',
    );
  });

  // ── Correlating with the scan that was queued ────────────────────────────
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"

  test('another job\'s finished counts are not reported as ours', () async {
    // The server accepted task 'b'; the newest finished entry is 'a', an
    // hour old. Its "4 new, 2 identified" is not what just happened.
    await watch(
      [withResults],
      awaitStart: true,
      expectTaskId: 'b',
      startGrace: Duration.zero,
    );
    expect(row().message, isNot('new 4 identified 2'));
    expect(row().message, 'none');
  });

  test('the queued scan\'s own result is reported', () async {
    await watch(
      [withResults],
      awaitStart: true,
      expectTaskId: 'a',
      startGrace: Duration.zero,
    );
    expect(row().message, 'new 4 identified 2');
  });

  test('a correlated watch waits out the grace for its own scan', () async {
    var polls = 0;
    await watch(
      [withResults, withResults, nowRunning, withNothing],
      awaitStart: true,
      expectTaskId: 'a',
      onPoll: () => polls++,
    );
    expect(polls, 4);
    expect(row().message, 'nothing');
  });

  test('an entry the server gave no id is still reported', () async {
    // A stock server's web-UI scan is the main case the watch exists for;
    // correlation must not cost us the entries that carry no id.
    const anonymous = RommScanPoll.answered(
      RommScanTaskStatus(status: 'finished', newRoms: 1),
    );
    await watch([anonymous], expectTaskId: 'b');
    expect(row().message, 'new 1 identified 0');
  });

  test('a poll that throws ends the watch and releases it', () async {
    await RommScanWatchRunner.runDetached(
      strings: strings,
      poll: () async => throw StateError('boom'),
      interval: Duration.zero,
      sleep: (_) async {},
    );
    expect(row().message, 'failed');
    expect(
      RommScanWatchRunner.isRunning,
      isFalse,
      reason: 'a watch that threw must not latch the next one out',
    );
  });

  test('a disconnect stops the watch and takes its row away', () async {
    await RommScanWatchRunner.runDetached(
      strings: strings,
      poll: () async => nowRunning,
      shouldStop: () => true,
      interval: Duration.zero,
      sleep: (_) async {},
    );
    expect(notifications.notifier.value, isEmpty);
    expect(RommScanWatchRunner.isRunning, isFalse);
  });
}
