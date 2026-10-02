import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../screens/romm_screen/romm_connect_content.dart';
import '../core_footer.dart';
import '../custom_toggle_switch.dart';

/// The setup wizard's optional RomM step.
///
/// Disconnected, it hosts the RomM tab's own credential form — the same
/// three authentication modes, QR scan included — so there is one login
/// implementation. The form owns the controller while it is shown: the wizard
/// is told through [onFormActive] and stands its own navigator down, and B
/// with no field focused comes back as [onSkip].
///
/// Connected, the form is gone and the controller is the wizard's again: the
/// step shows which server it is and one switch, the unified library, which
/// the wizard toggles through [toggleLibrary].
// Governing: ADR-0021 (RomM in first-run setup), SPEC-0020 REQ "Step Placement"
class RommSetupStep extends StatefulWidget {
  /// B on the form with no field focused: the wizard's Skip.
  final VoidCallback onSkip;

  /// Whether the credential form is on screen and holding the controller.
  final ValueChanged<bool> onFormActive;

  /// Whether a connect request is in flight, so the wizard can hold its
  /// buttons until it settles.
  final ValueChanged<bool> onBusyChanged;

  const RommSetupStep({
    super.key,
    required this.onSkip,
    required this.onFormActive,
    required this.onBusyChanged,
  });

  /// Flips "Show RomM library in my systems". The wizard binds this to X
  /// while the step is in its connected state; the switch itself calls it on
  /// a tap.
  // Governing: ADR-0021 (RomM in first-run setup), SPEC-0020 REQ "Connected State"
  static Future<void> toggleLibrary(BuildContext context) {
    final config = context.read<SqliteConfigProvider>();
    return config.updateRommShowLibrary(!config.config.rommShowLibrary);
  }

  @override
  State<RommSetupStep> createState() => _RommSetupStepState();
}

class _RommSetupStepState extends State<RommSetupStep> {
  /// What the wizard was last told, so it hears each change once.
  bool? _formActive;

  void _reportFormActive(bool active) {
    if (_formActive == active) return;
    _formActive = active;
    // Reported after the frame: the first report comes out of a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFormActive(active);
    });
  }

  @override
  void dispose() {
    // Leaving the step hands the controller back whatever state it was in.
    // Not through the post-frame path: there is no next frame for this state.
    if (_formActive == true) widget.onFormActive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = context.select<RommProvider, bool>((p) => p.isConnected);
    _reportFormActive(!connected);

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final titleSize = isLandscape ? 16.r : 24.r;
    final textSize = isLandscape ? 12.r : 14.r;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (connected) ...[
            Icon(
              Symbols.check_circle_rounded,
              size: isLandscape ? 48.r : 80.r,
              color: Colors.green,
            ),
            SizedBox(height: isLandscape ? 16.r : 24.r),
          ],
          Text(
            AppLocale.wizardRommStepTitle.getString(context),
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 8.r : 16.r),
          Text(
            (connected
                    ? AppLocale.wizardRommStepConnectedDesc
                    : AppLocale.wizardRommStepDesc)
                .getString(context),
            style: TextStyle(
              fontSize: textSize,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.3,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: isLandscape ? 12.r : 24.r),
          if (connected)
            _buildConnected(context, theme, textSize)
          else
            // Governing: ADR-0021 (RomM in first-run setup), SPEC-0020 REQ "Shared Connect Form"
            RommConnectContent(
              embedded: true,
              tabNavigation: false,
              onExit: widget.onSkip,
              onBusyChanged: widget.onBusyChanged,
            ),
        ],
      ),
    );
  }

  /// The server this install is now connected to, and the one choice worth
  /// asking for during setup. No disconnect: that lives on the RomM tab.
  // Governing: ADR-0021 (RomM in first-run setup), SPEC-0020 REQ "Connected State"
  Widget _buildConnected(
    BuildContext context,
    ThemeData theme,
    double textSize,
  ) {
    final provider = context.watch<RommProvider>();
    final showLibrary = context.select<SqliteConfigProvider, bool>(
      (p) => p.config.rommShowLibrary,
    );
    final version = provider.serverVersion;
    final faint = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 420.r),
      child: Column(
        children: [
          Text(
            provider.serverUrl,
            style: TextStyle(
              fontSize: textSize,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (version != null) ...[
            SizedBox(height: 4.r),
            Text(
              AppLocale.rommServerVersionLine
                  .getString(context)
                  .replaceFirst('{version}', version.toString()),
              style: TextStyle(fontSize: textSize - 2.r, color: faint),
            ),
          ],
          SizedBox(height: 20.r),
          InkWell(
            borderRadius: BorderRadius.circular(10.r),
            onTap: () => RommSetupStep.toggleLibrary(context),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 10.r),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocale.rommShowLibrary.getString(context),
                          style: TextStyle(
                            fontSize: textSize,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 2.r),
                        Text(
                          AppLocale.rommShowLibrarySubtitle.getString(context),
                          style: TextStyle(
                            fontSize: textSize - 3.r,
                            color: faint,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 12.r),
                  // The wizard has no cursor to put on this row, so the
                  // button that flips it is named beside it.
                  GamepadControl(
                    iconPath: 'assets/images/gamepad/Xbox_X_button.png',
                    label: '',
                    onTap: () => RommSetupStep.toggleLibrary(context),
                  ),
                  SizedBox(width: 8.r),
                  CustomToggleSwitch(
                    value: showLibrary,
                    onChanged: (_) => RommSetupStep.toggleLibrary(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
