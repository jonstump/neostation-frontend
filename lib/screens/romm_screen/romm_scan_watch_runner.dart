import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_scan_task_status.dart';
import '../../providers/romm_provider.dart';
import '../../services/global_notification_service.dart';
import '../../services/logger_service.dart';

/// The localized text the scan watcher reports with, resolved up front so the
/// watch never needs a [BuildContext] — the screen or dialog that started it
/// can close while it keeps polling.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Localized User-Facing Text"
class RommScanWatchStrings {
  final String waiting;
  final String progressTemplate;
  final String progressUnknown;
  final String resultsTemplate;
  final String nothing;
  final String failed;
  final String none;
  final String timeoutTemplate;

  /// What the watch ends on when the server stopped answering the question.
  /// Deliberately not [none]: "there is no scan running" is a statement about
  /// the server, and a poll that went unanswered is not one.
  final String unreachable;

  const RommScanWatchStrings({
    required this.waiting,
    required this.progressTemplate,
    required this.progressUnknown,
    required this.resultsTemplate,
    required this.nothing,
    required this.failed,
    required this.none,
    required this.timeoutTemplate,
    required this.unreachable,
  });

  factory RommScanWatchStrings.of(BuildContext context) {
    String s(String key) => key.getString(context);
    return RommScanWatchStrings(
      waiting: s(AppLocale.rommScanWatchWaiting),
      progressTemplate: s(AppLocale.rommScanWatchProgress),
      progressUnknown: s(AppLocale.rommScanWatchProgressUnknown),
      resultsTemplate: s(AppLocale.rommScanWatchResults),
      nothing: s(AppLocale.rommScanWatchNothing),
      failed: s(AppLocale.rommScanWatchFailed),
      none: s(AppLocale.rommScanWatchNone),
      timeoutTemplate: s(AppLocale.rommScanWatchTimeout),
      unreachable: s(AppLocale.rommScanWatchUnreachable),
    );
  }

  String progress(int done, int total) => progressTemplate
      .replaceFirst('{done}', '$done')
      .replaceFirst('{total}', '$total');

  String results(int newRoms, int identified) => resultsTemplate
      .replaceFirst('{new}', '$newRoms')
      .replaceFirst('{identified}', '$identified');

  String timeout(int minutes) =>
      timeoutTemplate.replaceFirst('{minutes}', '$minutes');
}

/// Watches the RomM library scan the server is running and reports the four
/// states the user could not tell apart before: running (with a determinate
/// bar whenever the server says how many ROMs there are), finished having
/// found something, finished having found nothing, and failed.
///
/// Detached like `RommMetadataFetchRunner`: strings and the poll callback are
/// resolved from [BuildContext] before it starts, and the watch itself holds
/// no widget, context or element.
///
/// It watches the *server*, not a request this app made, so it reports a scan
/// the user started from RomM's own web interface exactly like one NeoStation
/// queued. That is the answer to issue #236's real complaint — the user could
/// not tell whether the scan had run — on servers where NeoStation cannot
/// start a scan at all.
///
/// One watch at a time: a second [start] while one is polling is dropped
/// rather than stacked, since both would report into the same notification id.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"
class RommScanWatchRunner {
  static final _log = LoggerService.instance;

  /// One notification for the scan being watched; a later watch replaces the
  /// row rather than adding a second one.
  static const String notificationId = 'romm_scan_watch';

  static bool _running = false;

  const RommScanWatchRunner._();

  /// True while a watch is polling.
  static bool get isRunning => _running;

  /// Starts watching from a widget.
  ///
  /// [awaitStart] is set when a scan has just been queued: the newest entry
  /// the server reports at that moment may still be the *previous* scan, so
  /// the watch waits a few polls for a running one to appear before believing
  /// a finished entry. A plain "Scan status" check passes false and reports
  /// whatever the server says right now.
  ///
  /// [expectTaskId] is the id the server gave the scan that was just queued,
  /// when it gave one: a finished entry that is demonstrably a *different*
  /// job is then never reported as this one's result.
  static void start(
    BuildContext context, {
    bool awaitStart = false,
    String? expectTaskId,
  }) {
    final strings = RommScanWatchStrings.of(context);
    final romm = context.read<RommProvider>();
    unawaited(
      runDetached(
        strings: strings,
        poll: romm.scanTaskStatus,
        shouldStop: () => !romm.isConnected,
        awaitStart: awaitStart,
        expectTaskId: expectTaskId,
      ),
    );
  }

  /// Polls [poll] until the scan reaches a terminal state, reporting into the
  /// global notification.
  ///
  /// Public because two callers already hold everything it needs and have no
  /// context left to resolve strings from — the upload runner, when the batch
  /// queued a scan, and [start]. [poll] and [sleep] are also the seams a test
  /// drives every state through, without a widget tree or a server.
  ///
  /// The poll is bounded twice over — [interval] between calls and
  /// [maxDuration] in total — because `GET /api/tasks/status` walks the
  /// server's whole job registry and a scan of a large library can run for
  /// longer than anyone will watch it.
  ///
  /// A poll that could not be asked or could not be read is not an answer:
  /// [pollFailureTolerance] of them in a row ends the watch on
  /// [RommScanWatchStrings.unreachable], and a single one is waited out. That
  /// is the difference between "the server says there is no scan" and "the
  /// server did not say" — the second used to be reported as the first, so
  /// one bad poll out of hundreds, or a server too old to have the route at
  /// all, ended the watch claiming no scan was running.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  static Future<void> runDetached({
    required RommScanWatchStrings strings,
    required Future<RommScanPoll> Function() poll,
    bool Function()? shouldStop,
    bool awaitStart = false,
    String? expectTaskId,
    Duration interval = const Duration(seconds: 3),
    Duration startGrace = const Duration(seconds: 15),
    Duration maxDuration = const Duration(minutes: 20),
    int pollFailureTolerance = 5,
    Future<void> Function(Duration)? sleep,
  }) async {
    if (_running) {
      _log.i('RomM scan watch already running; second start dropped');
      return;
    }
    _running = true;

    final notifications = GlobalNotificationService();
    final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
    final started = DateTime.now();
    var seenRunning = false;
    var unanswered = 0;

    try {
      notifications.show(
        id: notificationId,
        message: strings.waiting,
        type: GlobalNotificationType.info,
        progress: 0,
        ongoing: true,
      );

      while (true) {
        if (shouldStop?.call() ?? false) {
          _log.i('RomM scan watch stopped: reason=disconnected');
          notifications.dismiss(notificationId);
          return;
        }

        final answer = await poll();
        final elapsed = DateTime.now().difference(started);
        final withinGrace = elapsed < startGrace;

        // A poll the server did not answer says nothing at all — not that
        // there is no scan. A watch runs for up to four hundred polls and a
        // proxy hiccup, a rate limit or a route an older server does not have
        // must not end it on a claim the server never made. Only a run of
        // them is worth giving up over, and giving up then says so.
        if (!answer.answered) {
          unanswered++;
          if (unanswered >= pollFailureTolerance) {
            _log.w('RomM scan watch ended: state=unanswered polls=$unanswered');
            _terminal(
              notifications,
              strings.unreachable,
              GlobalNotificationType.info,
            );
            return;
          }
          await wait(interval);
          continue;
        }
        unanswered = 0;

        final status = answer.status;
        if (status == null) {
          // The server answered and named no scan. Before the grace is up
          // that just means the job it accepted has not been listed yet.
          if (awaitStart && withinGrace) {
            await wait(interval);
            continue;
          }
          _log.i('RomM scan watch ended: state=no_scan_reported');
          _terminal(notifications, strings.none, GlobalNotificationType.info);
          return;
        }

        if (status.state == RommScanState.running) {
          seenRunning = true;
          final fraction = status.fraction;
          notifications.update(
            id: notificationId,
            // A total the server has not reported yet is not a bar of zero
            // progress dressed up as one: the message says the scan is
            // running and the bar sits at an explicit zero (#232).
            message: fraction == null
                ? strings.progressUnknown
                : strings.progress(status.scannedRoms, status.totalRoms),
            type: GlobalNotificationType.info,
            progress: fraction ?? 0,
            ongoing: true,
          );
          if (elapsed >= maxDuration) {
            _log.i(
              'RomM scan watch ended: state=still_running '
              'elapsed_min=${elapsed.inMinutes}',
            );
            _terminal(
              notifications,
              strings.timeout(maxDuration.inMinutes),
              GlobalNotificationType.info,
            );
            return;
          }
          await wait(interval);
          continue;
        }

        // A finished entry the server itself identifies as a different job
        // than the one just queued is the *previous* scan, whatever its
        // timestamp says and whether or not a running row was ever seen.
        // Without this, a scan that takes longer than the grace to appear
        // lets an hour-old "4 new, 2 identified" be reported as what just
        // happened. Only finished entries are correlated: a scan the watch
        // can see running is worth showing the progress of either way, and a
        // server that gives its jobs no ids (an empty [status.id]) keeps the
        // uncorrelated behaviour a web-UI-started scan depends on.
        final expected = expectTaskId ?? '';
        if (expected.isNotEmpty &&
            status.id.isNotEmpty &&
            status.id != expected) {
          if (withinGrace) {
            await wait(interval);
            continue;
          }
          _log.i(
            'RomM scan watch ended: state=queued_scan_not_listed '
            'newest=${status.id} expected=$expected',
          );
          _terminal(notifications, strings.none, GlobalNotificationType.info);
          return;
        }

        // A finished entry seen before the queued scan has even appeared is
        // the *previous* scan's row; waiting a few polls costs nothing and
        // stops the watch reporting yesterday's counts as today's.
        if (awaitStart && !seenRunning && withinGrace) {
          await wait(interval);
          continue;
        }

        _log.i('RomM scan watch ended: state=${status.state.name} $status');
        switch (status.state) {
          case RommScanState.doneWithResults:
            _terminal(
              notifications,
              strings.results(status.newRoms, status.identifiedRoms),
              GlobalNotificationType.success,
            );
          case RommScanState.doneWithNothing:
            _terminal(
              notifications,
              strings.nothing,
              GlobalNotificationType.info,
            );
          case RommScanState.failed:
            _terminal(
              notifications,
              strings.failed,
              GlobalNotificationType.error,
            );
          case RommScanState.running:
            // Unreachable: handled above, and listed so a state added later
            // fails the switch here rather than silently doing nothing.
            break;
        }
        return;
      }
    } catch (e, st) {
      _log.e('RomM scan watch failed', error: e, stackTrace: st);
      _terminal(notifications, strings.failed, GlobalNotificationType.error);
    } finally {
      _running = false;
    }
  }

  /// The row a watch ends on: no progress bar under a terminal message.
  ///
  /// [GlobalNotificationService.update] clears `progress` and `ongoing`
  /// unless they are restated, so naming neither is what drops the bar
  /// (#228, #229); and `update` no-ops on a row the user has already
  /// dismissed, which is the right answer — they said they were done with it.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  static void _terminal(
    GlobalNotificationService notifications,
    String message,
    GlobalNotificationType type,
  ) {
    notifications.update(id: notificationId, message: message, type: type);
  }
}
