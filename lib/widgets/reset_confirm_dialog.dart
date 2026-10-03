import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/game_service.dart'
    show GamepadNavigationManager;
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/login_form_selection.dart';

// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Typed Confirmation"
/// Confirmation for the in-app reset: names what will be deleted and what is
/// kept, and requires the word RESET typed before the destructive button
/// enables. A held gamepad button is too easy to produce by accident on a
/// device in a bag; typing is the one deliberate act a pad cannot do.
///
/// Owns its own gamepad layer while open. B leaves a focused text field first
/// and closes the dialog on the next press; nothing is deleted unless the
/// button itself is pressed with the word typed.
class ResetConfirmDialog extends StatefulWidget {
  const ResetConfirmDialog({super.key});

  /// Opens the dialog. Resolves to true only when the user typed RESET and
  /// pressed the reset button.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      // A stray tap outside must not confirm anything destructive.
      barrierDismissible: false,
      builder: (_) => const ResetConfirmDialog(),
    );
    return result ?? false;
  }

  @override
  State<ResetConfirmDialog> createState() => _ResetConfirmDialogState();
}

class _ResetConfirmDialogState extends State<ResetConfirmDialog>
    with LoginFormSelection<ResetConfirmDialog> {
  static const String _layerId = 'reset_confirm_dialog';

  /// The word the user must type. The same in every language; the field hint
  /// shows it (SPEC-0021 REQ "Localized User-Facing Text").
  static const String _confirmationWord = 'RESET';

  GamepadNavigation? _gamepadNav;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();

  @override
  List<FocusNode?> get selectionSlots => [_fieldFocus, null];

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _initControllerNavigation();
  }

  void _initControllerNavigation() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onSelectItem: _selectCurrent,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
      onBack: _handleBack,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav!.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav?.activate(),
        onDeactivate: () => _gamepadNav?.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav?.dispose();
    detachFocusSelectionListeners();
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  bool _navigateUp() => moveSelection(-1);

  bool _navigateDown() => moveSelection(1);

  void _selectCurrent() {
    if (focusSelectedField()) return;
    _confirm();
  }

  /// B's contract: out of the focused field first, then close the dialog.
  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
    } else {
      Navigator.of(context).pop(false);
    }
  }

  /// Whether the destructive action may run: only when the field holds exactly
  /// the word RESET, compared case-insensitively — "reset please" does not
  /// count.
  bool get _isConfirmed =>
      _controller.text.trim().toUpperCase() == _confirmationWord;

  void _confirm() {
    if (!_isConfirmed) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.scaffoldBackgroundColor,
      insetPadding: EdgeInsets.all(16.r),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(16.r),
        child: Container(
          constraints: BoxConstraints(maxWidth: 360.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocale.resetDialogTitle.getString(context),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.error,
                  fontSize: 14.r,
                ),
              ),
              SizedBox(height: 10.r),
              _buildListText(
                context,
                Icons.delete_outline_rounded,
                AppLocale.resetDialogDeletes.getString(context),
                theme,
              ),
              SizedBox(height: 6.r),
              _buildListText(
                context,
                Icons.shield_outlined,
                AppLocale.resetDialogKeeps.getString(context),
                theme,
              ),
              SizedBox(height: 12.r),
              _buildConfirmField(context, theme),
              SizedBox(height: 12.r),
              _buildResetButton(context, theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListText(
    BuildContext context,
    IconData icon,
    String text,
    ThemeData theme,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 14.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 9.r,
            ),
            softWrap: true,
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmField(BuildContext context, ThemeData theme) {
    return Container(
      constraints: BoxConstraints(maxWidth: 260.r),
      decoration: isSelected(0)
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        height: 36.r,
        child: TextField(
          controller: _controller,
          focusNode: _fieldFocus,
          decoration: InputDecoration(
            hintText: AppLocale.resetDialogHint.getString(context),
            hintStyle: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 10.r,
            ),
            filled: true,
            fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: isSelected(0)
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0.1),
                width: isSelected(0) ? 2.r : 1.r,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.r,
              ),
            ),
          ),
          style: TextStyle(fontSize: 11.r),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _confirm(),
        ),
      ),
    );
  }

  Widget _buildResetButton(BuildContext context, ThemeData theme) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final enabled = _isConfirmed;
        return Container(
          decoration: isSelected(1)
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(8.r),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.35),
                      blurRadius: 6.r,
                      spreadRadius: 1.r,
                    ),
                  ],
                )
              : null,
          child: FilledButton(
            key: const ValueKey('reset_confirm_button'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            // Disabled until the field holds the word (SPEC-0021 REQ
            // "Typed Confirmation").
            onPressed: enabled ? _confirm : null,
            child: Text(
              AppLocale.resetDialogButton.getString(context),
              style: TextStyle(fontSize: 11.r),
            ),
          ),
        );
      },
    );
  }
}

// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Relaunch"
/// The notice shown when the platform could not restart the process by
/// itself: the state is already wiped and consistent, so the app says to
/// start it again and exits once the notice is dismissed.
class ResetRestartNoticeDialog extends StatefulWidget {
  const ResetRestartNoticeDialog({super.key});

  /// Shows the notice and resolves when it is dismissed; the caller then
  /// exits the process.
  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ResetRestartNoticeDialog(),
    );
  }

  @override
  State<ResetRestartNoticeDialog> createState() =>
      _ResetRestartNoticeDialogState();
}

class _ResetRestartNoticeDialogState extends State<ResetRestartNoticeDialog> {
  static const String _layerId = 'reset_restart_notice';

  GamepadNavigation? _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: _close,
      onBack: _close,
      allowRepeat: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav!.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav?.activate(),
        onDeactivate: () => _gamepadNav?.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav?.dispose();
    super.dispose();
  }

  void _close() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
      content: Text(
        AppLocale.resetRestartNotice.getString(context),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
          fontSize: 10.r,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _close,
          child: Text(
            AppLocale.close.getString(context),
            style: TextStyle(fontSize: 11.r),
          ),
        ),
      ],
    );
  }
}
