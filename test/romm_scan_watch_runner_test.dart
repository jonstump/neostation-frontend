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
    List<RommScanTaskStatus?> answers, {
    bool awaitStart = false,
    Duration maxDuration = const Duration(minutes: 20),
    Duration startGrace = const Duration(seconds: 15),
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
      interval: Duration.zero,
      startGrace: startGrace,
      maxDuration: maxDuration,
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

  test('a running scan shows a determinate bar', () async {
    var seen = <double?>[];
    await watch(
      [running, finishedWithNothing],
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
      [noTotal, finishedWithNothing],
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
    await watch([finishedWithResults]);
    final end = row();
    expect(end.message, 'new 4 identified 2');
    expect(end.type, GlobalNotificationType.success);
    expect(end.progress, isNull, reason: 'a terminal row carries no bar');
    expect(end.ongoing, isFalse);
  });

  test('done with nothing is its own answer, with no bar', () async {
    await watch([finishedWithNothing]);
    final end = row();
    expect(end.message, 'nothing');
    expect(end.type, GlobalNotificationType.info);
    expect(end.progress, isNull);
    expect(end.ongoing, isFalse);
  });

  test('a failed scan reports the failure, with no bar', () async {
    await watch([failed]);
    final end = row();
    expect(end.message, 'failed');
    expect(end.type, GlobalNotificationType.error);
    expect(end.progress, isNull);
  });

  test('a running scan that ends clears the bar it was showing', () async {
    await watch([running, running, finishedWithResults]);
    final end = row();
    expect(end.message, 'new 4 identified 2');
    expect(
      end.progress,
      isNull,
      reason: 'the running fraction must not survive into the summary',
    );
  });

  test('no scan on the server says so rather than inventing one', () async {
    await watch([null]);
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
        [
          finishedWithResults,
          finishedWithResults,
          running,
          finishedWithNothing,
        ],
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
    await watch([running], maxDuration: Duration.zero);
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
        return finishedWithResults;
      },
      interval: Duration.zero,
      sleep: (_) async {},
    );
    expect(notifications.notifier.value, isEmpty);
  });

  test('a disconnect stops the watch and takes its row away', () async {
    await RommScanWatchRunner.runDetached(
      strings: strings,
      poll: () async => running,
      shouldStop: () => true,
      interval: Duration.zero,
      sleep: (_) async {},
    );
    expect(notifications.notifier.value, isEmpty);
    expect(RommScanWatchRunner.isRunning, isFalse);
  });
}
