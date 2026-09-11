import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_rom_upload.dart';
import 'package:neostation/screens/romm_screen/romm_rom_upload_runner.dart';
import 'package:neostation/services/global_notification_service.dart';

/// The row a ROM upload batch ends on.
///
/// It went through `GlobalNotificationService.show` from #224 until #229,
/// because `update` resolved progress as `progress ?? existing.progress` and
/// the summary would otherwise sit under a bar left full by a completed batch
/// or frozen part-way by a cancel. #229 made `update` clear the bar unless the
/// call names one, so the workaround is gone — and with it `show`'s side
/// effect of appending the row again after the user dismissed it with X.
/// Issue #231.
///
/// [RommRomUploadRunner.showTerminal] is the seam: reaching it through the
/// batch needs a connected `RommProvider` and a live widget tree, and the
/// behaviour worth pinning is this row, not the upload that leads to it.
///
/// Placeholder copy — these care about the shape of the row, not its wording.
const _strings = RommUploadStrings(
  title: 'upload-title',
  preparing: 'preparing',
  progressTemplate: '{name} {current}/{total}',
  summaryTemplate: '{uploaded}/{skipped}/{failed}',
  cancelledTemplate: 'cancelled {summary}',
  disconnectedTemplate: 'disconnected {summary}',
  scanRequested: 'scan-requested',
  scanPending: 'scan-pending',
  linkNow: 'link-now',
  linkNowResultTemplate: 'linked {count}',
  linkNowNothing: 'linked-nothing',
  linkFailed: 'link-failed',
  skippedLineTemplate: '{name}: {reason}',
  failedLineTemplate: '{name}: {reason}',
  moreTemplate: '+{count} more',
  cancel: 'cancel',
  confirmBodyTemplate: '{count} {size}',
  confirmAction: 'confirm',
  noPlatformTemplate: 'no-platform {system}',
  nothingToUploadTemplate: 'nothing-to-upload {system}',
  alreadyLinked: 'already-linked',
  busy: 'busy',
  notOffered: 'not-offered',
  skipReasons: <RommUploadSkipReason, String>{},
  failReasons: <RommUploadFailure, String>{},
);

void main() {
  const id = RommRomUploadRunner.notificationId;

  late GlobalNotificationService notifications;

  setUp(() {
    notifications = GlobalNotificationService();
    notifications.notifier.value = [];
  });

  tearDown(() => GlobalNotificationService().notifier.value = []);

  Iterable<GlobalNotificationData> rows() =>
      notifications.notifier.value.where((n) => n.id == id);

  /// The row the batch puts up, advanced part-way with Cancel on it — the
  /// state the summary has to replace.
  void startRunning({double at = 0.6}) {
    notifications.show(
      id: id,
      title: _strings.title,
      message: _strings.preparing,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
      action: GlobalNotificationAction(
        label: _strings.cancel,
        onPressed: () {},
      ),
    );
    notifications.update(
      id: id,
      message: 'Game.zip 3/5',
      type: GlobalNotificationType.info,
      progress: at,
      ongoing: true,
      action: GlobalNotificationAction(
        label: _strings.cancel,
        onPressed: () {},
      ),
    );
  }

  test('a row the user dismissed is not resurrected by the summary', () {
    startRunning();

    // The X on the bell: the user is done with this job, whatever it goes on
    // to report.
    notifications.dismiss(id);
    expect(rows(), isEmpty, reason: 'precondition: the X really removed it');

    RommRomUploadRunner.showTerminal(
      notifications,
      _strings,
      message: '3/1/1',
      type: GlobalNotificationType.success,
    );

    expect(
      rows(),
      isEmpty,
      reason:
          'the summary went through `show` while it was working around the '
          'old carry-over, and `show` appends a row whose id has since been '
          'dismissed — so the bell filled back up behind the user. Issue #231',
    );
  });

  test('the summary replaces the running row in place', () {
    startRunning();

    RommRomUploadRunner.showTerminal(
      notifications,
      _strings,
      message: '3/1/1',
      type: GlobalNotificationType.success,
    );

    final row = rows().single;
    expect(row.message, '3/1/1');
    expect(row.title, _strings.title, reason: 'identity carries over');
    expect(row.type, GlobalNotificationType.success);
    expect(
      row.progress,
      isNull,
      reason: 'the summary must not sit under the batch bar (#226/#229)',
    );
    expect(row.ongoing, isFalse, reason: '"Clear all" may now tidy it away');
    expect(row.action, isNull, reason: 'Cancel outlives nothing');
  });

  test('the summary can still carry an action of its own', () {
    startRunning();

    RommRomUploadRunner.showTerminal(
      notifications,
      _strings,
      message: '3/0/0',
      type: GlobalNotificationType.success,
      action: GlobalNotificationAction(
        label: _strings.linkNow,
        onPressed: () {},
      ),
    );

    expect(rows().single.action?.label, _strings.linkNow);
    expect(rows().single.progress, isNull);
  });
}
