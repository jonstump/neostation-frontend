part of '../system_emulator_settings_dialog.dart';

/// The per-system "Fetch metadata from RomM" action on the General tab.
///
/// The row is the last General item (index [_rommFetchIndex]) so every
/// existing index is unchanged. It is enabled only while RomM is connected;
/// while a pass is running for *this* system it turns into the Cancel
/// affordance, and while one runs for another system it names that system
/// and refuses (one pass at a time across all systems).
///
/// The pass itself is started detached from this dialog: it holds no widget,
/// context or provider reference past the moment it starts, so closing the
/// dialog neither cancels it nor stops the global notification from
/// reporting progress and completion.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
extension _RommFetch on _SystemEmulatorSettingsDialogState {
  Widget _buildRommFetchItem({required int index, required Key key}) {
    final connected = context.watch<RommProvider>().isConnected;
    return ValueListenableBuilder<RommMetadataFetch?>(
      valueListenable: RommMetadataFetch.activeNotifier,
      builder: (context, active, _) {
        if (active == null) {
          return _buildRommFetchRow(
            index: index,
            key: key,
            enabled: connected,
            subtitle: connected
                ? AppLocale.rommSystemFetchActionSubtitle.getString(context)
                : AppLocale.rommSystemFetchRequiresConnection.getString(
                    context,
                  ),
            trailing: Icon(
              Symbols.cloud_download_rounded,
              size: 16.r,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        }
        final mine = active.system?.folderName == _system.folderName;
        return ListenableBuilder(
          listenable: active,
          builder: (context, _) {
            if (mine) {
              return _buildRommFetchRow(
                index: index,
                key: key,
                enabled: true,
                subtitle: AppLocale.rommSystemFetchRowRunning
                    .getString(context)
                    .replaceFirst('{done}', '${active.done}')
                    .replaceFirst('{total}', '${active.total}'),
                trailing: _buildRommFetchPill(
                  AppLocale.cancel.getString(context),
                  icon: Symbols.cancel_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
              );
            }
            return _buildRommFetchRow(
              index: index,
              key: key,
              enabled: false,
              subtitle: AppLocale.rommSystemFetchBusy
                  .getString(context)
                  .replaceFirst(
                    '{system}',
                    active.system?.realName ?? active.system?.folderName ?? '',
                  ),
              trailing: Icon(
                Symbols.hourglass_top_rounded,
                size: 16.r,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRommFetchRow({
    required int index,
    required Key key,
    required bool enabled,
    required String subtitle,
    required Widget trailing,
  }) {
    final bool isFocused = _generalIndex == index;
    final theme = Theme.of(context);
    final double contentOpacity = enabled ? 1.0 : 0.4;
    final radius =
        theme.extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(9.r);

    return Container(
      key: key,
      decoration: BoxDecoration(
        color: isFocused
            ? theme.colorScheme.primary.withValues(alpha: 0.2)
            : Colors.transparent,
        borderRadius: radius,
      ),
      child: InkWell(
        onTap: enabled
            ? () {
                SfxService().playNavSound();
                rebuild(() => _generalIndex = index);
                _activateRommFetch();
              }
            : null,
        borderRadius: radius,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          child: Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocale.rommSystemFetchAction.getString(context),
                        style: TextStyle(
                          fontSize: 10.r,
                          fontWeight: FontWeight.w600,
                          color: isFocused
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 9.r,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 8.r),
              Opacity(opacity: contentOpacity, child: trailing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRommFetchPill(
    String label, {
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4.r),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.r, color: color),
          SizedBox(width: 4.r),
          Text(
            label,
            style: TextStyle(
              fontSize: 9.r,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// A press on the row: cancels this system's running pass, refuses while
  /// another system's pass runs, and otherwise asks for the mode and starts.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
  Future<void> _activateRommFetch() async {
    final active = RommMetadataFetch.active;
    if (active != null) {
      if (active.system?.folderName == _system.folderName) {
        active.cancel();
        return;
      }
      // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
      AppNotification.showNotification(
        context,
        AppLocale.rommSystemFetchBusy
            .getString(context)
            .replaceFirst(
              '{system}',
              active.system?.realName ?? active.system?.folderName ?? '',
            ),
        type: NotificationType.error,
      );
      return;
    }
    final romm = context.read<RommProvider>();
    if (!romm.isConnected) return;

    final mode = await RommSystemFetchModeDialog.show(
      context,
      systemName: _system.realName,
    );
    if (mode == null || !mounted) return;

    // Everything the detached run needs is resolved here, while the context
    // is alive; nothing below reads the widget again.
    final strings = _RommFetchStrings.of(context, _system);
    final files = context.read<FileProvider>();
    final scraping = context.read<ScrapingProvider>();
    final system = _system;

    AppNotification.showNotification(
      context,
      strings.started,
      type: NotificationType.info,
    );
    unawaited(
      _runRommFetchDetached(
        system: system,
        mode: mode,
        romm: romm,
        files: files,
        scraping: scraping,
        strings: strings,
      ),
    );
  }
}

/// The localized text the detached run reports with, resolved up front so
/// the run never needs a [BuildContext].
class _RommFetchStrings {
  final String started;
  final String preparing;
  final String progressTemplate;
  final String summaryTemplate;
  final String cancelledTemplate;
  final String busy;
  final String failedToStartTemplate;

  const _RommFetchStrings({
    required this.started,
    required this.preparing,
    required this.progressTemplate,
    required this.summaryTemplate,
    required this.cancelledTemplate,
    required this.busy,
    required this.failedToStartTemplate,
  });

  factory _RommFetchStrings.of(BuildContext context, SystemModel system) {
    final name = system.realName;
    return _RommFetchStrings(
      started: AppLocale.rommSystemFetchStarted
          .getString(context)
          .replaceFirst('{system}', name),
      preparing: AppLocale.rommSystemFetchPreparing
          .getString(context)
          .replaceFirst('{system}', name),
      progressTemplate: AppLocale.rommSystemFetchProgress
          .getString(context)
          .replaceFirst('{system}', name),
      summaryTemplate: AppLocale.rommSystemFetchSummary
          .getString(context)
          .replaceFirst('{system}', name),
      cancelledTemplate: AppLocale.rommSystemFetchCancelled.getString(context),
      busy: AppLocale.rommSystemFetchBusy
          .getString(context)
          .replaceFirst('{system}', name),
      failedToStartTemplate: AppLocale.rommSystemFetchFailedToStart
          .getString(context)
          .replaceFirst('{system}', name),
    );
  }

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

/// Runs one pass to completion with progress and the summary in the global
/// notification. Holds providers and pre-resolved strings only — no widget,
/// no context — so it outlives the dialog that started it.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
Future<void> _runRommFetchDetached({
  required SystemModel system,
  required RommMetadataMode mode,
  required RommProvider romm,
  required FileProvider files,
  required ScrapingProvider scraping,
  required _RommFetchStrings strings,
}) async {
  final notifications = GlobalNotificationService();
  final notificationId = 'romm_metadata_fetch_${system.folderName}';
  final log = _SystemEmulatorSettingsDialogState._log;

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
    final summary = await pass.run(system, mode);
    if (summary.wroteSomething) {
      // Once, after the pass, through the owners' existing paths: the games
      // list drops its artwork caches and reloads on the revision bump, and
      // the provider's settle rescans the system for a library that isn't
      // showing it right now.
      // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Concurrency Safety"
      scraping.markArtworkUpdated();
      romm.scheduleLibraryRefresh(system);
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
    log.w('$e');
    notifications.update(
      id: notificationId,
      message: strings.busy,
      type: GlobalNotificationType.error,
      progress: null,
    );
  } catch (e, st) {
    log.e('RomM metadata fetch pass did not run', error: e, stackTrace: st);
    notifications.update(
      id: notificationId,
      message: strings.failedToStart(e),
      type: GlobalNotificationType.error,
      progress: null,
    );
  }
}
