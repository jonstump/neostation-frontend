import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// Mode chooser for the per-system "Fetch metadata from RomM" pass.
///
/// Two rows: fill gaps (the recommended default, focused first) and replace
/// all, whose row carries the warning that non-English descriptions are
/// cleared and RomM provides no publisher. D-pad moves between them, A
/// confirms, B cancels; a tap on a row confirms it. Returns the chosen mode or
/// null on cancel.
///
/// Gamepad wiring follows [ConfirmActionDialog]: the layer is pushed in a
/// post-frame callback and activation is left to the manager.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-System Fetch Pass"
class RommSystemFetchModeDialog extends StatefulWidget {
  /// The system's display name, for the title.
  final String systemName;

  const RommSystemFetchModeDialog({super.key, required this.systemName});

  static Future<RommMetadataMode?> show(
    BuildContext context, {
    required String systemName,
  }) {
    return showDialog<RommMetadataMode>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommSystemFetchModeDialog(systemName: systemName),
    );
  }

  @override
  State<RommSystemFetchModeDialog> createState() =>
      _RommSystemFetchModeDialogState();
}

class _RommSystemFetchModeDialogState extends State<RommSystemFetchModeDialog> {
  static const _layerName = 'romm_system_fetch_mode_dialog';
  static const _modes = [RommMetadataMode.fillGaps, RommMetadataMode.replace];

  late final GamepadNavigation _gamepadNav;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: () => _confirm(_modes[_selected]),
      onBack: _cancel,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerName,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerName);
    _gamepadNav.dispose();
    super.dispose();
  }

  void _move(int delta) {
    SfxService().playNavSound();
    setState(() {
      _selected = (_selected + delta + _modes.length) % _modes.length;
    });
  }

  void _confirm(RommMetadataMode mode) {
    if (!mounted) return;
    Navigator.of(context).pop(mode);
  }

  void _cancel() {
    if (!mounted) return;
    SfxService().playBackSound();
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(color: accent.withValues(alpha: 0.3)),
      ),
      title: Row(
        children: [
          Icon(Symbols.cloud_download_rounded, color: accent, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              AppLocale.rommSystemFetchChooserTitle
                  .getString(context)
                  .replaceFirst('{system}', widget.systemName),
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 14.r,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOption(
              index: 0,
              icon: Symbols.auto_fix_high_rounded,
              title: AppLocale.rommSystemFetchModeFillGaps.getString(context),
              body: AppLocale.rommSystemFetchModeFillGapsHint.getString(
                context,
              ),
            ),
            SizedBox(height: 6.r),
            _buildOption(
              index: 1,
              icon: Symbols.sync_rounded,
              title: AppLocale.rommSystemFetchModeReplace.getString(context),
              body: AppLocale.rommSystemFetchModeReplaceWarning.getString(
                context,
              ),
              warning: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_B_button.png',
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                AppLocale.cancel.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12.r,
                ),
              ),
            ],
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: theme.colorScheme.onPrimary,
            padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6.r),
            ),
          ),
          onPressed: () => _confirm(_modes[_selected]),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18.r,
                height: 18.r,
                child: Image.asset(
                  'assets/images/gamepad/Xbox_A_button.png',
                  color: theme.colorScheme.onPrimary,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
              SizedBox(width: 4.r),
              Text(
                AppLocale.select.getString(context),
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 12.r,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOption({
    required int index,
    required IconData icon,
    required String title,
    required String body,
    bool warning = false,
  }) {
    final theme = Theme.of(context);
    final focused = _selected == index;
    final accent = warning
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return InkWell(
      onTap: () {
        SfxService().playNavSound();
        setState(() => _selected = index);
        _confirm(_modes[index]);
      },
      borderRadius: BorderRadius.circular(9.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: focused ? accent.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(9.r),
          border: Border.all(
            color: focused
                ? accent.withValues(alpha: 0.6)
                : theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16.r, color: accent),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11.r,
                      fontWeight: FontWeight.w600,
                      color: focused ? accent : theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    body,
                    style: TextStyle(
                      fontSize: 9.r,
                      color: warning
                          ? theme.colorScheme.error.withValues(alpha: 0.9)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
