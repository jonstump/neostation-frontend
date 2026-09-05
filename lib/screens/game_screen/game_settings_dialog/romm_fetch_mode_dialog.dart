import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// The mode chooser behind "Fetch metadata from RomM": fill gaps (default,
/// recommended) or replace all, each with a description so the replace
/// option can say what it costs — non-English descriptions are cleared and
/// the publisher is left empty, since RomM provides neither.
///
/// Gamepad wiring mirrors [ConfirmActionDialog]: the layer is pushed in a
/// post-frame callback and activated by the [GamepadNavigationManager]. D-pad
/// moves between the two options, A confirms the focused one, B cancels.
/// Pops with the chosen [RommMetadataMode], or null when cancelled.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-Game Fetch Action"
class RommFetchModeDialog extends StatefulWidget {
  const RommFetchModeDialog({super.key});

  static Future<RommMetadataMode?> show(BuildContext context) {
    return showDialog<RommMetadataMode>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RommFetchModeDialog(),
    );
  }

  @override
  State<RommFetchModeDialog> createState() => _RommFetchModeDialogState();
}

class _RommFetchModeDialogState extends State<RommFetchModeDialog> {
  static const String _layerId = 'romm_fetch_mode_dialog';
  static const List<RommMetadataMode> _modes = [
    RommMetadataMode.fillGaps,
    RommMetadataMode.replace,
  ];

  late final GamepadNavigation _gamepadNav;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _confirm,
      onBack: () {
        if (mounted) Navigator.of(context).pop();
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final next = (_selectedIndex + delta).clamp(0, _modes.length - 1);
    if (next == _selectedIndex) return;
    SfxService().playNavSound();
    setState(() => _selectedIndex = next);
  }

  void _confirm() {
    if (!mounted) return;
    SfxService().playEnterSound();
    Navigator.of(context).pop(_modes[_selectedIndex]);
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
              AppLocale.rommFetchMetadataChooserTitle.getString(context),
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 14.r,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 360.r,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModeOption(
              focused: _selectedIndex == 0,
              icon: Symbols.auto_fix_high_rounded,
              title: AppLocale.rommFetchMetadataFillGapsOption.getString(
                context,
              ),
              description: AppLocale.rommFetchMetadataFillGapsDescription
                  .getString(context),
              accent: accent,
              onTap: () {
                setState(() => _selectedIndex = 0);
                _confirm();
              },
            ),
            SizedBox(height: 8.r),
            _ModeOption(
              focused: _selectedIndex == 1,
              icon: Symbols.sync_rounded,
              title: AppLocale.rommFetchMetadataReplaceOption.getString(
                context,
              ),
              description: AppLocale.rommFetchMetadataReplaceDescription
                  .getString(context),
              accent: theme.colorScheme.error,
              onTap: () {
                setState(() => _selectedIndex = 1);
                _confirm();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
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
          onPressed: _confirm,
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
                AppLocale.rommFetchMetadataAction.getString(context),
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
}

/// One selectable mode: icon, title, and the description that tells the user
/// what the mode keeps or throws away. Highlighted while [focused].
class _ModeOption extends StatelessWidget {
  final bool focused;
  final IconData icon;
  final String title;
  final String description;
  final Color accent;
  final VoidCallback onTap;

  const _ModeOption({
    required this.focused,
    required this.icon,
    required this.title,
    required this.description,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: focused
              ? accent.withValues(alpha: 0.12)
              : onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: focused
                ? accent.withValues(alpha: 0.6)
                : onSurface.withValues(alpha: 0.1),
            width: 1.r,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 18.r,
              color: focused ? accent : onSurface.withValues(alpha: 0.6),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.r,
                      fontWeight: FontWeight.w600,
                      color: focused ? accent : onSurface,
                    ),
                  ),
                  SizedBox(height: 3.r),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 10.r,
                      height: 1.3,
                      color: onSurface.withValues(alpha: 0.7),
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
