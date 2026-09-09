import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../providers/romm_provider.dart';
import '../../providers/romm_rom_upload.dart';
import '../../services/global_notification_service.dart';
import '../../services/logger_service.dart';
import '../../utils/byte_size_format.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../../widgets/custom_notification.dart';

/// The localized text a detached ROM upload reports with, resolved up front
/// so the run never needs a [BuildContext] once it has started.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Localized User-Facing Text"
class RommUploadStrings {
  final String title;
  final String preparing;
  final String progressTemplate;
  final String summaryTemplate;
  final String cancelledTemplate;
  final String disconnectedTemplate;
  final String scanRequested;
  final String scanPending;
  final String linkNow;
  final String linkNowResultTemplate;
  final String linkNowNothing;
  final String skippedLineTemplate;
  final String failedLineTemplate;
  final String moreTemplate;
  final String cancel;
  final String confirmBodyTemplate;
  final String confirmAction;
  final String noPlatformTemplate;
  final String nothingToUploadTemplate;
  final String alreadyLinked;
  final String busy;
  final String notOffered;
  final Map<RommUploadSkipReason, String> skipReasons;
  final Map<RommUploadFailure, String> failReasons;

  const RommUploadStrings({
    required this.title,
    required this.preparing,
    required this.progressTemplate,
    required this.summaryTemplate,
    required this.cancelledTemplate,
    required this.disconnectedTemplate,
    required this.scanRequested,
    required this.scanPending,
    required this.linkNow,
    required this.linkNowResultTemplate,
    required this.linkNowNothing,
    required this.skippedLineTemplate,
    required this.failedLineTemplate,
    required this.moreTemplate,
    required this.cancel,
    required this.confirmBodyTemplate,
    required this.confirmAction,
    required this.noPlatformTemplate,
    required this.nothingToUploadTemplate,
    required this.alreadyLinked,
    required this.busy,
    required this.notOffered,
    required this.skipReasons,
    required this.failReasons,
  });

  factory RommUploadStrings.of(BuildContext context) {
    String s(String key) => key.getString(context);
    return RommUploadStrings(
      title: s(AppLocale.rommUploadTitle),
      preparing: s(AppLocale.rommUploadPreparing),
      progressTemplate: s(AppLocale.rommUploadProgress),
      summaryTemplate: s(AppLocale.rommUploadSummary),
      cancelledTemplate: s(AppLocale.rommUploadSummaryCancelled),
      disconnectedTemplate: s(AppLocale.rommUploadSummaryDisconnected),
      scanRequested: s(AppLocale.rommUploadScanRequested),
      scanPending: s(AppLocale.rommUploadScanPending),
      linkNow: s(AppLocale.rommUploadLinkNow),
      linkNowResultTemplate: s(AppLocale.rommUploadLinkNowResult),
      linkNowNothing: s(AppLocale.rommUploadLinkNowNothing),
      skippedLineTemplate: s(AppLocale.rommUploadSkippedLine),
      failedLineTemplate: s(AppLocale.rommUploadFailedLine),
      moreTemplate: s(AppLocale.rommUploadMore),
      cancel: s(AppLocale.cancel),
      confirmBodyTemplate: s(AppLocale.rommUploadConfirmBody),
      confirmAction: s(AppLocale.rommUploadConfirmAction),
      noPlatformTemplate: s(AppLocale.rommUploadNoPlatform),
      nothingToUploadTemplate: s(AppLocale.rommUploadNothingToUpload),
      alreadyLinked: s(AppLocale.rommUploadAlreadyLinked),
      busy: s(AppLocale.rommUploadBusy),
      notOffered: s(AppLocale.rommUploadNotOffered),
      skipReasons: {
        RommUploadSkipReason.multiFile: s(AppLocale.rommUploadSkipMultiFile),
        RommUploadSkipReason.discContainer: s(
          AppLocale.rommUploadSkipDiscContainer,
        ),
        RommUploadSkipReason.missing: s(AppLocale.rommUploadSkipMissing),
        RommUploadSkipReason.empty: s(AppLocale.rommUploadSkipEmpty),
        RommUploadSkipReason.unsendableName: s(
          AppLocale.rommUploadSkipUnsendableName,
        ),
        RommUploadSkipReason.alreadyExists: s(
          AppLocale.rommUploadSkipAlreadyExists,
        ),
      },
      failReasons: {
        RommUploadFailure.scopeDenied: s(AppLocale.rommUploadFailScopeDenied),
        RommUploadFailure.cancelled: s(AppLocale.rommUploadFailCancelled),
        RommUploadFailure.busy: s(AppLocale.rommUploadFailBusy),
        RommUploadFailure.gated: s(AppLocale.rommUploadFailGated),
        RommUploadFailure.other: s(AppLocale.rommUploadFailOther),
      },
    );
  }

  /// Per-file lines the summary names before folding the rest into "+N
  /// more": the bell shows six lines, and two are the counts and the scan.
  static const int namedOutcomes = 3;

  String progress(RommUploadProgress p) => progressTemplate
      .replaceFirst('{name}', p.fileName)
      .replaceFirst('{current}', '${p.index + 1}')
      .replaceFirst('{total}', '${p.count}');

  String confirmBody(int count, int totalBytes) => confirmBodyTemplate
      .replaceFirst('{count}', '$count')
      .replaceFirst('{size}', formatByteSize(totalBytes));

  String noPlatform(String system) =>
      noPlatformTemplate.replaceFirst('{system}', system);

  String nothingToUpload(String system) =>
      nothingToUploadTemplate.replaceFirst('{system}', system);

  String linkNowResult(int count) =>
      linkNowResultTemplate.replaceFirst('{count}', '$count');

  String reasonFor(RommUploadFileOutcome outcome) {
    if (outcome.skipped case final reason?) return skipReasons[reason] ?? '';
    if (outcome.failed case final cause?) return failReasons[cause] ?? '';
    return '';
  }

  /// The counts, how the batch ended, the scan state, and the first few
  /// skipped and failed files with their reasons.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces",
  // REQ "Scan And Link After Upload"
  String summary(RommUploadSummary s) {
    var counts = summaryTemplate
        .replaceFirst('{uploaded}', '${s.uploaded.length}')
        .replaceFirst('{skipped}', '${s.skipped.length}')
        .replaceFirst('{failed}', '${s.failed.length}');
    counts = switch (s.end) {
      RommUploadEnd.cancelled => cancelledTemplate.replaceFirst(
        '{summary}',
        counts,
      ),
      RommUploadEnd.disconnected => disconnectedTemplate.replaceFirst(
        '{summary}',
        counts,
      ),
      _ => counts,
    };
    final lines = <String>[counts];
    switch (s.scan) {
      case RommUploadScanState.requested:
        lines.add(scanRequested);
      case RommUploadScanState.pending:
        lines.add(scanPending);
      case RommUploadScanState.none:
        break;
    }
    final named = <String>[
      for (final o in s.skipped)
        skippedLineTemplate
            .replaceFirst('{name}', o.fileName)
            .replaceFirst('{reason}', reasonFor(o)),
      for (final o in s.failed)
        failedLineTemplate
            .replaceFirst('{name}', o.fileName)
            .replaceFirst('{reason}', reasonFor(o)),
    ];
    lines.addAll(named.take(namedOutcomes));
    if (named.length > namedOutcomes) {
      lines.add(
        moreTemplate.replaceFirst('{count}', '${named.length - namedOutcomes}'),
      );
    }
    return lines.join('\n');
  }
}

/// Starts a ROM upload detached from the widget that asked for it, with
/// per-file progress and Cancel in the global notification, and the summary
/// — with "Link now" when anything landed — in the same notification when
/// the batch ends.
///
/// Everything the run needs is resolved from [BuildContext] before it starts;
/// the batch itself holds no widget, so the menu or dialog that started it
/// can close while it keeps going. The one thing that still needs the
/// context is the bulk confirmation, which happens right after the files are
/// opened and is skipped (as a decline) if the context is gone by then.
///
/// [uploadGame] is the context menu's "Upload to RomM"; [uploadSystem] the
/// system settings' "Upload games missing from RomM".
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces",
// REQ "Scan And Link After Upload"
class RommRomUploadRunner {
  static final _log = LoggerService.instance;

  /// One notification for every batch: a second batch cannot start while
  /// the first runs, and the summary of the last one is what the next one
  /// replaces.
  static const String notificationId = 'romm_rom_upload';

  const RommRomUploadRunner._();

  /// Uploads [game] to its system's platform. No confirmation: the menu
  /// press is the intent, and the file is one.
  static Future<void> uploadGame(
    BuildContext context,
    GameModel game, {
    String? systemFolder,
  }) {
    final romm = context.read<RommProvider>();
    return _run(
      context,
      subject: game.systemRealName ?? game.systemFolderName ?? '',
      singleGame: true,
      start: (onProgress) => romm.uploadToRomm(
        game,
        systemFolder: systemFolder,
        onProgress: onProgress,
      ),
    );
  }

  /// Uploads every unlinked single-file game of [system], after the user
  /// has seen the count and total size.
  static Future<void> uploadSystem(BuildContext context, SystemModel system) {
    final romm = context.read<RommProvider>();
    final strings = RommUploadStrings.of(context);
    return _run(
      context,
      subject: system.realName,
      start: (onProgress) => romm.uploadMissingForSystem(
        system,
        confirm: (count, totalBytes) => _confirm(
          context,
          strings: strings,
          count: count,
          totalBytes: totalBytes,
        ),
        onProgress: onProgress,
      ),
    );
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required RommUploadStrings strings,
    required int count,
    required int totalBytes,
  }) async {
    if (!context.mounted) return false;
    return ConfirmActionDialog.show(
      context,
      title: strings.title,
      body: strings.confirmBody(count, totalBytes),
      confirmLabel: strings.confirmAction,
      icon: Symbols.cloud_upload_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
  }

  /// [singleGame] words "nothing to upload" as the one game being linked
  /// already, which is the only way a single upload comes back empty.
  static Future<void> _run(
    BuildContext context, {
    required String subject,
    required Future<RommUploadSummary> Function(
      RommUploadProgressCallback onProgress,
    )
    start,
    bool singleGame = false,
  }) async {
    final strings = RommUploadStrings.of(context);
    final romm = context.read<RommProvider>();
    final notifications = GlobalNotificationService();

    if (romm.romUpload.isRunning) {
      _toast(context, strings.busy, NotificationType.error);
      return;
    }

    final cancelAction = GlobalNotificationAction(
      label: strings.cancel,
      onPressed: romm.romUpload.cancel,
    );
    notifications.show(
      id: notificationId,
      title: strings.title,
      message: strings.preparing,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
      action: cancelAction,
    );

    final RommUploadSummary summary;
    try {
      summary = await start(
        (p) => notifications.update(
          id: notificationId,
          message: strings.progress(p),
          type: GlobalNotificationType.info,
          progress: p.fraction,
          ongoing: true,
          action: cancelAction,
        ),
      );
    } on RommUploadBusyException catch (e) {
      _log.w('$e');
      notifications.dismiss(notificationId);
      if (context.mounted) {
        _toast(context, strings.busy, NotificationType.error);
      }
      return;
    } catch (e, st) {
      _log.e('RomM upload batch did not run', error: e, stackTrace: st);
      notifications.update(
        id: notificationId,
        message: strings.failReasons[RommUploadFailure.other] ?? '',
        type: GlobalNotificationType.error,
        progress: null,
      );
      return;
    }

    // The early ends never sent anything: the notification would only say
    // so twice. A toast where the surface is still up, the notification
    // otherwise.
    if (summary.neverStarted) {
      notifications.dismiss(notificationId);
      final String? message = switch (summary.end) {
        RommUploadEnd.noPlatform => strings.noPlatform(subject),
        RommUploadEnd.nothingToUpload =>
          singleGame ? strings.alreadyLinked : strings.nothingToUpload(subject),
        RommUploadEnd.notOffered => strings.notOffered,
        RommUploadEnd.declined => null,
        _ => null,
      };
      if (message == null) return;
      if (context.mounted) {
        _toast(context, message, NotificationType.info);
      } else {
        notifications.show(
          id: notificationId,
          title: strings.title,
          message: message,
          type: GlobalNotificationType.info,
        );
      }
      return;
    }

    final text = strings.summary(summary);
    notifications.update(
      id: notificationId,
      message: text,
      type: summary.failed.isNotEmpty
          ? GlobalNotificationType.error
          : (summary.end == RommUploadEnd.completed
                ? GlobalNotificationType.success
                : GlobalNotificationType.info),
      progress: null,
      // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
      action: summary.wroteSomething
          ? GlobalNotificationAction(
              label: strings.linkNow,
              onPressed: () => unawaited(
                _linkNow(romm, strings, notifications, summaryText: text),
              ),
            )
          : null,
    );
  }

  /// "Link now": runs the link pass once and appends what it linked to the
  /// summary. The action is withdrawn while the pass runs so a second press
  /// cannot queue another.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
  static Future<void> _linkNow(
    RommProvider romm,
    RommUploadStrings strings,
    GlobalNotificationService notifications, {
    required String summaryText,
  }) async {
    notifications.update(
      id: notificationId,
      message: summaryText,
      progress: null,
      ongoing: true,
    );
    final result = await romm.linkNow();
    final linked = result?.rowsAdded ?? 0;
    notifications.update(
      id: notificationId,
      message:
          '$summaryText\n'
          '${linked > 0 ? strings.linkNowResult(linked) : strings.linkNowNothing}',
      type: linked > 0 ? GlobalNotificationType.success : null,
      progress: null,
      // The pass can be run again once the server has scanned.
      action: GlobalNotificationAction(
        label: strings.linkNow,
        onPressed: () => unawaited(
          _linkNow(romm, strings, notifications, summaryText: summaryText),
        ),
      ),
    );
  }

  static void _toast(
    BuildContext context,
    String message,
    NotificationType type,
  ) {
    AppNotification.showNotification(context, message, type: type);
  }
}
