part of '../system_emulator_settings_dialog.dart';

/// The per-system "BIOS files from RomM" row on the General tab.
///
/// Sits directly after the metadata-fetch row (index [_rommFirmwareIndex]) and
/// appears only once two things are true: RomM is connected, and this system's
/// name resolves to a RomM platform. The resolution is asynchronous — it may
/// have to load the platform list — so the row materializes when the answer
/// arrives rather than being rendered disabled in the meantime; the general
/// tab's item count grows with it, which is why the key list is allocated one
/// slot longer than the initial count.
///
/// Pressing it opens [RommFirmwarePanel], which owns everything else: presence,
/// verification, downloads and the BIOS folder.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
extension _RommFirmware on _SystemEmulatorSettingsDialogState {
  Widget _buildRommFirmwareItem({required int index, required Key key}) {
    final connected = context.watch<RommProvider>().isConnected;
    return _buildRommFirmwareRow(
      index: index,
      key: key,
      enabled: connected,
      subtitle: connected
          ? AppLocale.rommFirmwareRowSubtitle.getString(context)
          : AppLocale.rommFirmwareRowRequiresConnection.getString(context),
    );
  }

  Widget _buildRommFirmwareRow({
    required int index,
    required Key key,
    required bool enabled,
    required String subtitle,
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
                _activateRommFirmware();
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
                        AppLocale.rommFirmwareRowTitle.getString(context),
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
              Opacity(
                opacity: contentOpacity,
                child: Icon(
                  Symbols.memory_rounded,
                  size: 16.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Resolves this system to a RomM platform once, in the background, and shows
  /// the row when one is found.
  ///
  /// A system RomM has no platform for gets no row at all: the panel would only
  /// ever be able to report an empty list.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  Future<void> _resolveRommFirmwarePlatform() async {
    if (!_offersRommFetch) return;
    final romm = context.read<RommProvider>();
    if (!romm.isConnected) return;
    try {
      final ids = await romm.platformIdsForSystemName(_system.realName);
      if (!mounted || ids.isEmpty) return;
      rebuild(() {
        _rommFirmwarePlatformId = ids.first;
        _totalGeneralItems += 1;
      });
    } catch (e) {
      // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Error Handling Standards"
      _SystemEmulatorSettingsDialogState._log.w(
        'RomM firmware row: platform lookup failed for '
        '${_system.folderName}: $e',
      );
    }
  }

  /// A press on the row: opens the BIOS panel for the resolved platform.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  void _activateRommFirmware() {
    final platformId = _rommFirmwarePlatformId;
    if (platformId == null) return;
    final romm = context.read<RommProvider>();
    if (!romm.isConnected) return;
    RommFirmwarePanel.show(
      context,
      system: _system,
      platformId: platformId,
      service: romm.service,
    );
  }
}
