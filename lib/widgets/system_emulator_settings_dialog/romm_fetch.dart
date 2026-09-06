part of '../system_emulator_settings_dialog.dart';

/// The per-system "Fetch metadata from RomM" action on the General tab.
///
/// The row is the last General item (index [_rommFetchIndex]) so every
/// existing index is unchanged. It is enabled only while RomM is connected;
/// while a pass is running for *this* system it turns into the Cancel
/// affordance, and while one runs for another system it names that system
/// and refuses (one pass at a time across all systems).
///
/// The pass itself is started detached from this dialog (see
/// [RommMetadataFetchRunner]): it holds no widget, context or provider
/// reference past the moment it starts, so closing the dialog neither
/// cancels it nor stops the global notification from reporting progress and
/// completion.
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
                  .replaceFirst('{system}', active.subject),
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
            .replaceFirst('{system}', active.subject),
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

    RommMetadataFetchRunner.runSystem(context, _system, mode);
  }
}
