import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_metadata_fetch.dart';
import '../../models/system_model.dart';
import '../../providers/file_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/scraping_provider.dart';
import '../../repositories/game_repository.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../services/global_notification_service.dart';
import '../../services/logger_service.dart';
import '../../services/romm/romm_metadata_fetch.dart';
import '../../widgets/custom_notification.dart';

/// The localized text a detached RomM metadata fetch reports with, resolved
/// up front so the run never needs a [BuildContext]. The `{system}`
/// placeholder of the per-system strings takes [of]'s [subject] — a system's
/// display name, or the collection name of a target run.
class RommMetadataFetchStrings {
  final String started;
  final String preparing;
  final String progressTemplate;
  final String summaryTemplate;
  final String cancelledTemplate;
  final String busyTemplate;
  final String failedToStartTemplate;

  const RommMetadataFetchStrings({
    required this.started,
    required this.preparing,
    required this.progressTemplate,
    required this.summaryTemplate,
    required this.cancelledTemplate,
    required this.busyTemplate,
    required this.failedToStartTemplate,
  });

  factory RommMetadataFetchStrings.of(BuildContext context, String subject) {
    return RommMetadataFetchStrings(
      started: AppLocale.rommSystemFetchStarted
          .getString(context)
          .replaceFirst('{system}', subject),
      preparing: AppLocale.rommSystemFetchPreparing
          .getString(context)
          .replaceFirst('{system}', subject),
      progressTemplate: AppLocale.rommSystemFetchProgress
          .getString(context)
          .replaceFirst('{system}', subject),
      summaryTemplate: AppLocale.rommSystemFetchSummary
          .getString(context)
          .replaceFirst('{system}', subject),
      cancelledTemplate: AppLocale.rommSystemFetchCancelled.getString(context),
      busyTemplate: AppLocale.rommSystemFetchBusy.getString(context),
      failedToStartTemplate: AppLocale.rommSystemFetchFailedToStart
          .getString(context)
          .replaceFirst('{system}', subject),
    );
  }

  /// Names the pass that is still running, not the one refused.
  String busy(String runningSubject) =>
      busyTemplate.replaceFirst('{system}', runningSubject);

  String progress(int done, int total) => progressTemplate
      .replaceFirst('{done}', '$done')
      .replaceFirst('{total}', '$total');

  String summary(RommMetadataFetchSummary s) {
    final text = summaryTemplate
        .replaceFirst('{linked}', '${s.linked}')
        .replaceFirst('{filled}', '${s.filled}')
        .replaceFirst('{replaced}', '${s.replaced}')
        .replaceFirst('{unlinked}', '${s.unlinkedSkipped}')
        .replaceFirst('{notFound}', '${s.notFound}')
        .replaceFirst('{failed}', '${s.failed}');
    if (!s.cancelled) return text;
    return cancelledTemplate.replaceFirst('{summary}', text);
  }

  String failedToStart(Object error) =>
      failedToStartTemplate.replaceFirst('{error}', '$error');
}

/// Starts a RomM metadata fetch detached from the widget that asked for it,
/// with progress and the summary in the global notification.
///
/// Everything the run needs — strings, providers — is resolved from
/// [BuildContext] before it starts; the run itself holds no widget, context
/// or element, so the dialog or screen that started it can close while it
/// keeps going and keeps reporting. Once, after the pass, the artwork caches
/// are dropped and the affected systems' libraries refreshed.
///
/// [runSystem] is the system settings' "Fetch metadata from RomM" action;
/// [runTargets] runs the same pass over the members a collection sync linked.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
class RommMetadataFetchRunner {
  static final _log = LoggerService.instance;

  const RommMetadataFetchRunner._();

  /// Fetches metadata for every linked game of [system] in [mode], announcing
  /// the start with an in-app toast and then reporting through the global
  /// notification. The caller has already asked for the mode and checked
  /// that no pass is running.
  static void runSystem(
    BuildContext context,
    SystemModel system,
    RommMetadataMode mode,
  ) {
    // Everything the detached run needs is resolved here, while the context
    // is alive; nothing below reads the widget again.
    final strings = RommMetadataFetchStrings.of(context, system.realName);
    final romm = context.read<RommProvider>();
    final files = context.read<FileProvider>();
    final scraping = context.read<ScrapingProvider>();

    AppNotification.showNotification(
      context,
      strings.started,
      type: NotificationType.info,
    );
    unawaited(
      _runDetached(
        notificationId: 'romm_metadata_fetch_${system.folderName}',
        start: (pass) => pass.run(system, mode),
        refreshSystems: [system],
        romm: romm,
        files: files,
        scraping: scraping,
        strings: strings,
      ),
    );
  }

  /// Fetches metadata for [targets] in [mode] under [label] — the collection
  /// a sync linked them for — reporting through the global notification
  /// only: the sync's own toasts are showing at the moment this starts, and
  /// the notification's "preparing" line appears at once. [systemsByFolder]
  /// holds each target's system by its game's system folder.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Metadata For Linked Members"
  static void runTargets(
    BuildContext context, {
    required String label,
    required List<RommMetadataFetchTarget> targets,
    required RommMetadataMode mode,
    required Map<String, SystemModel> systemsByFolder,
  }) {
    if (targets.isEmpty) return;
    final strings = RommMetadataFetchStrings.of(context, label);
    final romm = context.read<RommProvider>();
    final files = context.read<FileProvider>();
    final scraping = context.read<ScrapingProvider>();
    SystemModel systemOf(RommMetadataFetchTarget target) =>
        systemsByFolder[target.game.systemFolderName]!;
    final systems = <String, SystemModel>{
      for (final target in targets)
        systemOf(target).folderName: systemOf(target),
    };

    unawaited(
      _runDetached(
        // Per label, like the per-system id, so a refused second collection
        // run reports in its own notification rather than over the running
        // one's progress.
        notificationId: 'romm_metadata_fetch_collection_${label.hashCode}',
        start: (pass) => pass.runTargets(
          targets,
          mode: mode,
          systemOf: systemOf,
          label: label,
        ),
        refreshSystems: systems.values,
        romm: romm,
        files: files,
        scraping: scraping,
        strings: strings,
      ),
    );
  }

  /// Runs one pass to completion with progress and the summary in the global
  /// notification. Holds providers and pre-resolved strings only — no widget,
  /// no context — so it outlives whatever started it.
  static Future<void> _runDetached({
    required String notificationId,
    required Future<RommMetadataFetchSummary> Function(RommMetadataFetch pass)
    start,
    required Iterable<SystemModel> refreshSystems,
    required RommProvider romm,
    required FileProvider files,
    required ScrapingProvider scraping,
    required RommMetadataFetchStrings strings,
  }) async {
    final notifications = GlobalNotificationService();

    final pass = RommMetadataFetch(
      listGames: GameRepository.loadGamesForSystem,
      linkIndex: RommSaveMapRepository.getRomIdIndex,
      fetchOne: (target, system, mode) => romm.fetchMetadataForRomId(
        romId: target.romId,
        system: system,
        fileProvider: files,
        indexedName: target.indexedName,
        mode: mode,
      ),
      // A disconnect mid-pass would otherwise fail every remaining game
      // against the cleared config; stop between games instead.
      // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
      shouldStop: () => !romm.isConnected,
      onProgress: (done, total) => notifications.update(
        id: notificationId,
        message: strings.progress(done, total),
        type: GlobalNotificationType.info,
        progress: total == 0 ? 0 : done / total,
        ongoing: true,
      ),
    );

    notifications.show(
      id: notificationId,
      message: strings.preparing,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    try {
      final summary = await start(pass);
      if (summary.wroteSomething) {
        // Once, after the pass, through the owners' existing paths: the games
        // list drops its artwork caches and reloads on the revision bump, and
        // the provider's settle rescans each system for a library that isn't
        // showing it right now.
        // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
        scraping.markArtworkUpdated();
        for (final system in refreshSystems) {
          romm.scheduleLibraryRefresh(system);
        }
      }
      notifications.update(
        id: notificationId,
        message: strings.summary(summary),
        type: summary.cancelled
            ? GlobalNotificationType.info
            : (summary.failed > 0
                  ? GlobalNotificationType.error
                  : GlobalNotificationType.success),
        progress: null,
      );
    } on RommMetadataFetchBusyException catch (e) {
      _log.w('$e');
      notifications.update(
        id: notificationId,
        message: strings.busy(e.runningSystemFolder),
        type: GlobalNotificationType.error,
        progress: null,
      );
    } catch (e, st) {
      _log.e('RomM metadata fetch pass did not run', error: e, stackTrace: st);
      notifications.update(
        id: notificationId,
        message: strings.failedToStart(e),
        type: GlobalNotificationType.error,
        progress: null,
      );
    }
  }
}
