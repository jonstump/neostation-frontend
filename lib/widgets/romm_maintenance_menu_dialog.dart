import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_locale.dart';
import '../services/game_service.dart' show GamepadNavigationManager;
import '../services/sfx_service.dart';
import '../utils/gamepad_nav.dart';

/// The RomM server actions this menu offers: the three tasks NeoStation can
/// ask the server to queue, named as RomM's `tasks/registry` publishes them,
/// and the read-only scan status check.
///
/// Names are the wire contract of `POST /api/tasks/run/{name}` and are not
/// localized; the label and the confirmation body beside them are.
///
/// [scanStatus] runs nothing, which is why its [taskName] is empty and its
/// [confirmBodyKey] null. It exists because on a stock RomM server a library
/// scan cannot be started over REST at all (issue #236) — the user starts one
/// in RomM's web interface, and this is how they see what it did without
/// leaving the app.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"
enum RommMaintenanceTask {
  rescanLibrary('scan_library'),
  syncFolderScan('sync_folder_scan'),
  cleanupMissingRoms('cleanup_missing_roms'),
  scanStatus('');

  const RommMaintenanceTask(this.taskName);

  /// The `{name}` in `POST /api/tasks/run/{name}`, or empty for an entry that
  /// queues nothing.
  final String taskName;

  /// Whether picking this sends a task-run request (and so needs confirming).
  bool get queuesTask => taskName.isNotEmpty;

  /// Whether this task is a library scan, and so worth watching afterwards.
  bool get isScan =>
      this == RommMaintenanceTask.rescanLibrary ||
      this == RommMaintenanceTask.syncFolderScan;

  /// The `AppLocale` key for this task's menu row.
  String get labelKey {
    switch (this) {
      case RommMaintenanceTask.rescanLibrary:
        return AppLocale.rommMaintenanceRescan;
      case RommMaintenanceTask.syncFolderScan:
        return AppLocale.rommMaintenanceSyncFolders;
      case RommMaintenanceTask.cleanupMissingRoms:
        return AppLocale.rommMaintenanceCleanup;
      case RommMaintenanceTask.scanStatus:
        return AppLocale.rommScanStatus;
    }
  }

  /// The `AppLocale` key for the body of this task's confirmation, or null
  /// for an entry that changes nothing on the server and so is not confirmed.
  String? get confirmBodyKey {
    switch (this) {
      case RommMaintenanceTask.rescanLibrary:
        return AppLocale.rommMaintenanceRescanConfirm;
      case RommMaintenanceTask.syncFolderScan:
        return AppLocale.rommMaintenanceSyncFoldersConfirm;
      case RommMaintenanceTask.cleanupMissingRoms:
        return AppLocale.rommMaintenanceCleanupConfirm;
      case RommMaintenanceTask.scanStatus:
        return null;
    }
  }

  IconData get icon {
    switch (this) {
      case RommMaintenanceTask.rescanLibrary:
        return Symbols.refresh_rounded;
      case RommMaintenanceTask.syncFolderScan:
        return Symbols.folder_open_rounded;
      case RommMaintenanceTask.cleanupMissingRoms:
        return Symbols.cleaning_services_rounded;
      case RommMaintenanceTask.scanStatus:
        return Symbols.monitor_heart_rounded;
    }
  }
}

/// The "Server maintenance" menu on the connected RomM screen's header.
///
/// One row per [RommMaintenanceTask]: Up/Down walks them, A picks the focused
/// one, B closes. Returns the chosen task, or null on cancel — the *caller*
/// then confirms it (via `ConfirmActionDialog`) and sends the request, so this
/// dialog stays a chooser and the confirmation keeps the one wording the rest
/// of the app uses for a consequential action. An entry that queues nothing
/// ([RommMaintenanceTask.scanStatus]) has no confirmation to keep, and the
/// caller skips it.
///
/// New entries are *appended* to the enum, never inserted: the rows are drawn
/// in enum order and the focus index is an ordinal, so inserting one moves
/// every row the user has learned the position of.
///
/// Gamepad wiring follows [ConfirmActionDialog]: layer pushed in the same
/// post-frame callback as `initialize()`, popped in `dispose()`.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Maintenance Tasks"
class RommMaintenanceMenuDialog extends StatefulWidget {
  const RommMaintenanceMenuDialog({super.key});

  static Future<RommMaintenanceTask?> show(BuildContext context) {
    return showDialog<RommMaintenanceTask>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const RommMaintenanceMenuDialog(),
    );
  }

  @override
  State<RommMaintenanceMenuDialog> createState() =>
      _RommMaintenanceMenuDialogState();
}

class _RommMaintenanceMenuDialogState extends State<RommMaintenanceMenuDialog> {
  static const _layerName = 'romm_maintenance_menu_dialog';
  static const _tasks = RommMaintenanceTask.values;

  late final GamepadNavigation _gamepadNav;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: () => _pick(_tasks[_selected]),
      onBack: _cancel,
      allowRepeat: false,
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
      _selected = (_selected + delta + _tasks.length) % _tasks.length;
    });
  }

  void _pick(RommMaintenanceTask task) {
    if (!mounted) return;
    Navigator.of(context).pop(task);
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
          Icon(Symbols.build_rounded, color: accent, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              AppLocale.rommMaintenanceTitle.getString(context),
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
            for (var i = 0; i < _tasks.length; i++) ...[
              if (i > 0) SizedBox(height: 6.r),
              _buildRow(theme, _tasks[i], i),
            ],
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
      ],
    );
  }

  Widget _buildRow(ThemeData theme, RommMaintenanceTask task, int index) {
    final scheme = theme.colorScheme;
    final focused = _selected == index;
    return InkWell(
      onTap: () => _pick(task),
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 1.5.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              task.icon,
              size: 18.r,
              color: scheme.onSurface.withValues(alpha: 0.8),
            ),
            SizedBox(width: 10.r),
            Expanded(
              child: Text(
                task.labelKey.getString(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.r,
                  fontWeight: focused ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
