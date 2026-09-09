import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/screens/romm_screen/romm_metadata_fetch_runner.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';

/// The row a RomM metadata fetch ends on must not carry the running pass's
/// progress bar.
///
/// The runner used to end with `GlobalNotificationService.update(progress:
/// null, ...)`, and `update` resolves progress as `progress ?? existing
/// .progress` — so passing null kept the last fraction and the summary sat
/// under a bar left full by a completed pass or frozen part-way by a cancel.
/// #224 fixed the same shape in the ROM upload runner by routing terminal
/// rows through `show`, which replaces the row wholesale.
///
/// These drive the runner's own terminal paths rather than asserting on the
/// helper, so the bar is measured where a user would see it.
///
/// The pass's `onProgress` field is private with no getter, so the injected
/// `start` sets the bar with the same `update` call the runner's own
/// `onProgress` closure makes rather than firing that closure. What is under
/// test is the terminal row, not the progress plumbing: the precondition test
/// below pins that the running row really does carry a non-null bar for the
/// terminal row to have to clear. Issue #226, related #224.
///
/// No assertion runs inside the injected `start`. `runDetached` awaits it
/// inside a blanket `catch (e, st)`, which swallows the `TestFailure` an
/// `expect` throws: a failing assertion in there is logged and the test
/// still reports green. Observations are captured into locals and asserted
/// after the run returns.
void main() {
  const notificationId = 'romm_metadata_fetch_test';

  const strings = RommMetadataFetchStrings(
    started: 'started',
    preparing: 'preparing',
    progressTemplate: '{done}/{total}',
    summaryTemplate: 'summary',
    cancelledTemplate: 'cancelled',
    busyTemplate: 'busy {system}',
    failedToStartTemplate: 'failed {error}',
  );

  late GlobalNotificationService notifications;

  setUp(() {
    notifications = GlobalNotificationService();
    notifications.notifier.value = [];
  });

  tearDown(() => GlobalNotificationService().notifier.value = []);

  GlobalNotificationData rowFor(String id) =>
      notifications.notifier.value.firstWhere((n) => n.id == id);

  Future<void> run(
    Future<RommMetadataFetchSummary> Function(RommMetadataFetch pass) start,
  ) => RommMetadataFetchRunner.runDetached(
    notificationId: notificationId,
    start: start,
    refreshSystems: const [],
    romm: RommProvider(),
    files: FileProvider(),
    scraping: ScrapingProvider(),
    strings: strings,
  );

  /// Mirrors the body of the runner's `onProgress` closure.
  void reportProgress(double fraction) => notifications.update(
    id: notificationId,
    message: 'progress',
    type: GlobalNotificationType.info,
    progress: fraction,
    ongoing: true,
  );

  test('the running row carries a bar — the state being cleared', () async {
    // Captured, not asserted, inside the closure: `runDetached` awaits it
    // inside a blanket `catch (e, st)`, which swallows the `TestFailure` an
    // `expect` throws and turns a red test green. Everything the pass observes
    // has to come back out and be asserted after the run returns.
    double? opening;
    double? reported;

    await run((pass) async {
      opening = rowFor(notificationId).progress;
      reportProgress(0.75);
      reported = rowFor(notificationId).progress;
      return const RommMetadataFetchSummary();
    });

    expect(
      opening,
      0,
      reason:
          "the runner's opening row is a zeroed bar, not a null one — "
          'which is why `update(progress: null)` retained anything at all',
    );
    expect(
      reported,
      closeTo(0.75, 1e-9),
      reason: 'a running pass advances the bar the terminal row must clear',
    );
  });

  test('a completed pass ends with no progress bar', () async {
    await run((pass) async {
      reportProgress(1);
      return const RommMetadataFetchSummary(linked: 4, filled: 0);
    });

    final row = rowFor(notificationId);
    expect(row.progress, isNull, reason: 'summary must not sit under a bar');
    expect(row.type, GlobalNotificationType.success);
    expect(row.ongoing, isFalse);
  });

  test('a cancelled pass ends with no progress bar', () async {
    await run((pass) async {
      reportProgress(0.25);
      return const RommMetadataFetchSummary(linked: 4, cancelled: true);
    });

    final row = rowFor(notificationId);
    expect(
      row.progress,
      isNull,
      reason: 'a cancel must not freeze the bar part-way',
    );
    expect(row.type, GlobalNotificationType.info);
  });

  test('a pass that failed games ends with no progress bar', () async {
    await run((pass) async {
      reportProgress(1);
      return const RommMetadataFetchSummary(linked: 4, failed: 2);
    });

    final row = rowFor(notificationId);
    expect(row.progress, isNull);
    expect(row.type, GlobalNotificationType.error);
  });

  test('a pass that threw ends with no progress bar', () async {
    await run((pass) async {
      reportProgress(0.5);
      throw StateError('boom');
    });

    final row = rowFor(notificationId);
    expect(row.progress, isNull, reason: 'the failure row clears the bar too');
    expect(row.type, GlobalNotificationType.error);
  });

  test('a row the user dismissed mid-pass is not resurrected', () async {
    await run((pass) async {
      reportProgress(0.5);
      // The X on the bell, pressed while the pass is still running: the row
      // goes, and `update` is a no-op on an id that is no longer listed.
      notifications.dismiss(notificationId);
      return const RommMetadataFetchSummary(linked: 4);
    });

    expect(
      notifications.notifier.value.where((n) => n.id == notificationId),
      isEmpty,
      reason:
          'the summary went through `show` while it was working around the '
          'old `progress ?? existing.progress` carry-over, and `show` appends '
          'a row whose id has since been dismissed — so a summary the user '
          'had closed came back. Issue #231',
    );
  });

  test('a busy pass ends with no progress bar', () async {
    await run((pass) async {
      reportProgress(0.5);
      throw const RommMetadataFetchBusyException(
        runningSystemFolder: 'nes',
        requestedSystemFolder: 'snes',
      );
    });

    final row = rowFor(notificationId);
    expect(row.progress, isNull);
    expect(row.type, GlobalNotificationType.error);
  });
}
