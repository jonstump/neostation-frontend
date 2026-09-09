import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/global_notification_service.dart';

/// `GlobalNotificationService.update` clears the progress bar unless the call
/// names a new one.
///
/// It used to resolve progress as `progress ?? existing.progress`, so the
/// terminal row of a run — which passes `progress: null`, or omits it —
/// inherited the running row's fraction and the summary sat under a bar left
/// full by a completed pass or frozen part-way by a cancel. Three runners were
/// fixed one at a time (#224, #226, #227) by routing their terminal rows
/// through `show` before the default was recognised as backwards.
///
/// `ongoing` and `action` already worked this way for the same reason, stated
/// in `update`'s own doc comment: the last update of a run is the completion
/// message, and that is the call site most likely to forget to clear
/// something. `progress` now matches them. Issue #228.
void main() {
  late GlobalNotificationService notifications;

  setUp(() {
    notifications = GlobalNotificationService();
    notifications.notifier.value = [];
  });

  tearDown(() => GlobalNotificationService().notifier.value = []);

  GlobalNotificationData row(String id) =>
      notifications.notifier.value.firstWhere((n) => n.id == id);

  void startRunning(String id, {double at = 0.75}) {
    notifications.show(
      id: id,
      message: 'working',
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );
    notifications.update(
      id: id,
      message: 'working',
      type: GlobalNotificationType.info,
      progress: at,
      ongoing: true,
    );
  }

  group('the bar clears unless the update names one', () {
    test('an explicit null clears a bar the run had advanced', () {
      startRunning('a');
      expect(row('a').progress, closeTo(0.75, 1e-9));

      notifications.update(id: 'a', message: 'done', progress: null);

      expect(row('a').progress, isNull);
    });

    test('omitting progress clears it too', () {
      startRunning('b');

      notifications.update(id: 'b', message: 'done');

      expect(
        row('b').progress,
        isNull,
        reason: 'three romm_connect_content terminal rows omit it entirely',
      );
    });

    test('a real fraction still replaces the previous one', () {
      startRunning('c', at: 0.25);

      notifications.update(id: 'c', message: 'working', progress: 0.5);

      expect(
        row('c').progress,
        closeTo(0.5, 1e-9),
        reason: 'the 11 callers that pass a fraction are unaffected',
      );
    });

    test('a run reporting 0 is a bar at zero, not a cleared one', () {
      startRunning('d');

      notifications.update(id: 'd', message: 'restarting', progress: 0);

      expect(row('d').progress, 0);
    });
  });

  group('the fallbacks that deliberately stay', () {
    test('title, icon and image still carry over', () {
      notifications.show(
        id: 'e',
        message: 'working',
        title: 'RomM',
        icon: Icons.download,
        progress: 0.5,
        ongoing: true,
      );

      notifications.update(id: 'e', message: 'done');

      final r = row('e');
      expect(r.title, 'RomM', reason: 'identity, not state');
      expect(r.icon, Icons.download, reason: 'identity, not state');
      expect(r.progress, isNull, reason: 'state — and this is the fix');
    });

    test('type still carries over when the update names none', () {
      notifications.show(
        id: 'f',
        message: 'working',
        type: GlobalNotificationType.error,
        progress: 0.5,
      );

      notifications.update(id: 'f', message: 'still failing');

      expect(row('f').type, GlobalNotificationType.error);
    });
  });

  group('the rule progress now matches', () {
    test('ongoing and action are dropped unless restated', () {
      notifications.show(
        id: 'g',
        message: 'working',
        progress: 0.5,
        ongoing: true,
        action: GlobalNotificationAction(label: 'Cancel', onPressed: () {}),
      );

      notifications.update(id: 'g', message: 'done');

      final r = row('g');
      expect(r.ongoing, isFalse);
      expect(r.action, isNull);
      expect(r.progress, isNull, reason: 'progress now behaves like both');
    });
  });

  test('update on an unknown id is still a no-op', () {
    notifications.update(id: 'nope', message: 'x', progress: 0.5);

    expect(notifications.notifier.value, isEmpty);
  });
}
