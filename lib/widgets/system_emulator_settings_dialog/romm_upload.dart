part of '../system_emulator_settings_dialog.dart';

/// The per-system "Upload games missing from RomM" row on the General tab.
///
/// The last General row (index [_rommUploadIndex]), offered only while the
/// provider's gate is open when the dialog opens: connected, the server not
/// known to predate the upload session, this login not known to lack
/// `roms.write`, and the server not known to be offline. While a batch runs
/// the row shows the file in flight and turns into the Cancel affordance,
/// whichever surface started it.
///
/// The batch itself is started detached from this dialog (see
/// [RommRomUploadRunner]): it reports progress, cancel and the summary
/// through the global notification, so closing the dialog neither cancels
/// it nor silences it.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
extension _RommUpload on _SystemEmulatorSettingsDialogState {
  /// The provider's gate, read once at open. False when no provider is in
  /// the tree (a bare test host), which is the same as "not offered".
  bool _rommUploadGateOpen() {
    try {
      return context.read<RommProvider>().canUploadRoms;
    } on ProviderNotFoundException {
      return false;
    }
  }

  Widget _buildRommUploadItem({required int index, required Key key}) {
    final romm = context.watch<RommProvider>();
    return ListenableBuilder(
      listenable: romm.romUpload,
      builder: (context, _) {
        final upload = romm.romUpload;
        if (upload.isRunning) {
          return _buildRommUploadRow(
            index: index,
            key: key,
            enabled: true,
            subtitle: AppLocale.rommUploadSystemRowRunning
                .getString(context)
                .replaceFirst('{name}', upload.currentFileName ?? '')
                .replaceFirst('{current}', '${upload.done + 1}')
                .replaceFirst('{total}', '${upload.total}'),
            trailing: _buildRommFetchPill(
              AppLocale.cancel.getString(context),
              icon: Symbols.cancel_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return _buildRommUploadRow(
          index: index,
          key: key,
          enabled: romm.canUploadRoms,
          subtitle: AppLocale.rommUploadSystemRowSubtitle.getString(context),
          trailing: Icon(
            Symbols.cloud_upload_rounded,
            size: 16.r,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      },
    );
  }

  Widget _buildRommUploadRow({
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
                _activateRommUpload();
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
                        AppLocale.rommUploadSystemRowTitle.getString(context),
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

  /// A press on the row: cancels the running batch, or starts this system's
  /// — the runner confirms the count and size first.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
  void _activateRommUpload() {
    final romm = context.read<RommProvider>();
    if (romm.romUpload.isRunning) {
      romm.romUpload.cancel();
      return;
    }
    if (!romm.canUploadRoms) return;
    unawaited(RommRomUploadRunner.uploadSystem(context, _system));
  }
}
