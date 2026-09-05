import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/widgets/info_dialog.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/services/config_service.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/widgets/custom_notification.dart';
import 'package:neostation/widgets/move_user_data_dialog.dart';
import 'package:neostation/widgets/permission_check_wrapper.dart';
import 'package:neostation/widgets/restart_required_dialog.dart';
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'package:neostation/utils/byte_size_format.dart';
import 'in_folder_import_summary.dart';
import 'settings_title.dart';
import 'widgets/settings_section_header.dart';
import 'widgets/settings_action_button.dart';

class DirectoriesSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const DirectoriesSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<DirectoriesSettingsContent> createState() =>
      DirectoriesSettingsContentState();
}

class DirectoriesSettingsContentState
    extends State<DirectoriesSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final AdaptiveScroller _scroller = AdaptiveScroller();

  /// GlobalKeys for the navigable rows, used to keep the focused row visible
  /// during gamepad navigation.
  final List<GlobalKey> _itemKeys = [];

  /// Grows [_itemKeys] to cover the current navigable-item count.
  void _ensureKeys(int count) {
    while (_itemKeys.length < count) {
      _itemKeys.add(GlobalKey());
    }
  }

  List<String> _currentRomFolders = [];
  String? _currentUserDataPath;
  bool _isLoading = true;

  // Migration progress state (shown inline, no dialog).
  bool _isMigrating = false;
  double _migrationProgress = 0.0;
  String _migrationFile = '';

  // ES-DE import progress state (shown inline, no dialog).
  bool _isImporting = false;
  double _importProgress = 0.0;
  String _importLabel = '';
  EsdeImportResult? _lastEsdeResult;

  /// True while the running import is the in-folder (ROM folder) one, so
  /// the shared progress panel can title itself accordingly.
  bool _importingInFolder = false;

  static final _log = LoggerService.instance;

  // Flat list of navigable items used for gamepad index tracking.
  // Layout: user_data | rescan | add_rom | remove_rom:N...
  final List<Map<String, dynamic>> _directoryItems = [];

  @override
  void initState() {
    super.initState();
    _loadCurrentPaths();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void scrollToIndex(int index) {
    // Use the focused row's own key so scrolling tracks its real height —
    // section headers and path-chip cards aren't a uniform height, so a
    // fixed per-row estimate drifts and overshoots as the list scrolls.
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  void _buildDirectoryItems() {
    _directoryItems.clear();

    // 0: User Data Location
    _directoryItems.add({
      'title': AppLocale.userDataLocation,
      'subtitle': AppLocale.userDataLocationSubtitle,
      'action': 'user_data',
    });

    // 1: Rescan All ROM Folders
    _directoryItems.add({
      'title': AppLocale.rescanAllFolders,
      'subtitle': AppLocale.rescanAllFoldersSubtitle,
      'action': 'rescan',
    });

    // 2: Add ROM Folder
    _directoryItems.add({
      'title': AppLocale.addRomFolder,
      'subtitle': AppLocale.romsFolderSubtitle,
      'action': 'add_rom',
    });

    // 3..n+2: Individual ROM folders (removable)
    for (final path in _currentRomFolders) {
      _directoryItems.add({
        'title': path,
        'subtitle': AppLocale.pressToRemoveFolder,
        'action': 'remove_rom',
        'path': path,
      });
    }

    // ES-DE import actions (grouped under their own section header in build).
    _esdeSectionStart = _directoryItems.length;
    _directoryItems.add({
      'title': AppLocale.esdeSelectFolder,
      'subtitle': AppLocale.esdeSelectFolderSubtitle,
      'action': 'esde_select_folder',
    });
    _directoryItems.add({
      'title': AppLocale.esdeRunImport,
      'subtitle': AppLocale.esdeRunImportSubtitle,
      'action': 'esde_run_import',
    });
    _directoryItems.add({
      'title': AppLocale.esdeReset,
      'subtitle': AppLocale.esdeResetSubtitle,
      'action': 'esde_reset',
    });
    // In-folder import: gamelist.xml + artwork found inside the ROM folders
    // themselves (RomM export / Batocera layout). Appended after the ES-DE
    // rows so their gamepad indices are unchanged; it shares the section's
    // ROM-folder gate but needs no ES-DE folder.
    _directoryItems.add({
      'title': AppLocale.inFolderImport,
      'subtitle': AppLocale.inFolderImportSubtitle,
      'action': 'import_rom_folders',
    });
  }

  // Index of the first ES-DE item in [_directoryItems]; used to insert the
  // "ES-DE Import" section header at the right position.
  int _esdeSectionStart = -1;

  // ES-DE import requires at least one ROM directory to match games against,
  // so the whole section is disabled until one is configured.
  bool get _esdeEnabled => _currentRomFolders.isNotEmpty;

  static const Set<String> _esdeActions = {
    'esde_select_folder',
    'esde_run_import',
    'esde_reset',
    'import_rom_folders',
  };

  /// Whether an ES-DE action is currently disabled. Requires a ROM directory
  /// for the whole section, plus a selected ES-DE folder for the import action.
  bool _isEsdeDisabled(String action) {
    if (!_esdeActions.contains(action)) return false;
    if (!_esdeEnabled) return true;
    if (action == 'esde_run_import' && _esdePath.trim().isEmpty) return true;
    return false;
  }

  Future<void> _loadCurrentPaths() async {
    try {
      final foldersFuture = ConfigRepository.getUserRomFolders();
      final userDataFuture = ConfigService.getUserDataPath();
      _currentRomFolders = await foldersFuture;
      _currentUserDataPath = await userDataFuture;
    } catch (e) {
      _log.e('Failed to load directory configuration: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _buildDirectoryItems();
        });
      }
    }
  }

  Future<void> _handleItemTap(Map<String, dynamic> item) async {
    final action = item['action'] as String;
    // Disabled ES-DE actions are inert — no toast, no sound, no work.
    if (_isEsdeDisabled(action)) return;
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    switch (item['action']) {
      case 'user_data':
        await _selectUserDataLocation();
        break;
      case 'rescan':
        await configProvider.scanSystems();
        break;
      case 'add_rom':
        await _selectRomFolder();
        break;
      case 'remove_rom':
        await _removeRomFolder(item['path'] as String);
        break;
      case 'esde_select_folder':
        await _selectEsdeFolder();
        break;
      case 'esde_run_import':
        await _runEsdeImport();
        break;
      case 'esde_reset':
        await _resetEsdeImport();
        break;
      case 'import_rom_folders':
        await _runInFolderImport();
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // ES-DE import
  // ---------------------------------------------------------------------------

  String get _esdePath =>
      context.read<SqliteConfigProvider>().config.esdeFolderPath;

  Future<void> _selectEsdeFolder() async {
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.esdeSelectFolder.getString(context),
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      await context.read<SqliteConfigProvider>().updateEsdeFolderPath(selected);
      // Refresh the fallback map so any already-recorded systems resolve.
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (mounted) setState(() {});
    } catch (e) {
      _log.e('ES-DE folder selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _runEsdeImport() async {
    final root = _esdePath;
    if (root.trim().isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.esdeImportNoFolder.getString(context),
        type: NotificationType.info,
      );
      return;
    }
    if (_isImporting) return;

    const notificationId = 'esde_import_progress';

    // Resolve ES-DE strings before the async import so the progress callback
    // (which may run after this screen was left) can use them safely.
    final localeEsdeImporting = AppLocale.esdeImporting.getString(context);
    final localeEsdeImportNotEsdeFolder = AppLocale.esdeImportNotEsdeFolder
        .getString(context);
    final localeEsdeImportNothingFound = AppLocale.esdeImportNothingFound
        .getString(context);
    final localeEsdeImportComplete = AppLocale.esdeImportComplete.getString(
      context,
    );
    final localeEsdeSummaryGames = AppLocale.esdeSummaryGames.getString(
      context,
    );
    final localeEsdeSummarySystems = AppLocale.esdeSummarySystems.getString(
      context,
    );
    final localeImportAlreadyRunning = AppLocale.inFolderImportAlreadyRunning
        .getString(context);

    setState(() {
      _isImporting = true;
      _importingInFolder = false;
      _importProgress = 0.0;
      _importLabel = '';
      _lastEsdeResult = null;
    });

    GlobalNotificationService().show(
      id: notificationId,
      message: localeEsdeImporting,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    EsdeImportResult? result;
    String? error;
    try {
      result = await EsdeImportService.import(
        root,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _importProgress = p;
              _importLabel = label;
            });
          }
          GlobalNotificationService().update(
            id: notificationId,
            message: label.isEmpty
                ? localeEsdeImporting
                : '$localeEsdeImporting: $label',
            type: GlobalNotificationType.info,
            progress: p,
            ongoing: true,
          );
        },
      );
      // Rebuild the fallback map now that esde_media_dir rows exist.
      if (mounted) await context.read<FileProvider>().refreshEsde();
    } catch (e) {
      error = e.toString();
      _log.e('ES-DE import failed: $e');
    }

    // Report the outcome through the global notification so the header
    // dropdown reflects it even if this screen was left mid-import.
    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null) {
      if (result.refusedAlreadyRunning) {
        // Another run (e.g. the setup wizard's) still holds the guard.
        GlobalNotificationService().update(
          id: notificationId,
          message: localeImportAlreadyRunning,
          type: GlobalNotificationType.error,
          progress: null,
        );
      } else if (!result.gamelistsDirFound) {
        // No gamelists/ dir — the picked folder isn't an ES-DE installation.
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNotEsdeFolder,
          type: GlobalNotificationType.error,
          progress: null,
        );
      } else if (result.gamesImported == 0 && result.systemsMatched == 0) {
        // Valid ES-DE folder, but nothing here mapped to a NeoStation system.
        GlobalNotificationService().update(
          id: notificationId,
          message: localeEsdeImportNothingFound,
          type: GlobalNotificationType.info,
          progress: null,
        );
      } else {
        GlobalNotificationService().update(
          id: notificationId,
          message:
              '$localeEsdeImportComplete: '
              '${result.gamesImported} $localeEsdeSummaryGames, '
              '${result.systemsMatched} $localeEsdeSummarySystems',
          type: GlobalNotificationType.success,
          progress: null,
        );
      }
    }

    if (!mounted) return;
    // Only surface the result summary for an import that actually ran against a
    // real ES-DE folder and touched something — not for an exception, a
    // "not an ES-DE folder" bail-out, or a matched-nothing no-op (those get a
    // notification instead, so a zeroed summary box would just be noise).
    final showSummary =
        error == null &&
        result != null &&
        !result.refusedAlreadyRunning &&
        result.gamelistsDirFound &&
        (result.gamesImported > 0 || result.systemsMatched > 0);
    setState(() {
      _isImporting = false;
      _lastEsdeResult = showSummary ? result : null;
    });
  }

  /// Runs the in-folder import over the configured ROM folders. Mirrors
  /// [_runEsdeImport]: same inline progress panel and global notification,
  /// then a summary the user dismisses with A/B. The row is gated on at least
  /// one ROM folder, so an empty list here is only a defensive no-op.
  // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Import Entry Point and Results"
  Future<void> _runInFolderImport() async {
    if (_isImporting) return;
    final romFolders = List<String>.from(_currentRomFolders);
    if (romFolders.isEmpty) return;

    const notificationId = 'in_folder_import_progress';

    // Resolve strings before the async import so the progress callback (which
    // may run after this screen was left) can use them safely.
    final localeImporting = AppLocale.inFolderImporting.getString(context);
    final localeComplete = AppLocale.inFolderImportComplete.getString(context);
    final localeNoGamelists = AppLocale.inFolderImportNoGamelists.getString(
      context,
    );
    final localeFoldersSkipped = AppLocale.inFolderImportFoldersSkippedSaf
        .getString(context);
    final localeNothingFound = AppLocale.esdeImportNothingFound.getString(
      context,
    );
    final localeGames = AppLocale.esdeSummaryGames.getString(context);
    final localeSystems = AppLocale.esdeSummarySystems.getString(context);
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
    final localeAlreadyRunning = AppLocale.inFolderImportAlreadyRunning
        .getString(context);
    final localeCancelled = AppLocale.inFolderImportCancelled.getString(
      context,
    );
    final localeBudgetRefused = AppLocale.inFolderImportBudgetRefused.getString(
      context,
    );
    final localeFilesCopied = AppLocale.inFolderSummaryFilesCopied.getString(
      context,
    );

    setState(() {
      _isImporting = true;
      _importingInFolder = true;
      _importProgress = 0.0;
      _importLabel = '';
      _lastEsdeResult = null;
    });

    GlobalNotificationService().show(
      id: notificationId,
      message: localeImporting,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    EsdeImportResult? result;
    String? error;
    try {
      result = await EsdeImportService.importInFolder(
        romFolders,
        onProgress: (p, label) {
          if (mounted) {
            setState(() {
              _importProgress = p;
              _importLabel = label;
            });
          }
          GlobalNotificationService().update(
            id: notificationId,
            message: label.isEmpty
                ? localeImporting
                : '$localeImporting: $label',
            type: GlobalNotificationType.info,
            progress: p,
            ongoing: true,
          );
        },
      );
      // Rebuild the fallback map now that esde_media_root rows exist.
      if (mounted) await context.read<FileProvider>().refreshEsde();
    } catch (e) {
      error = e.toString();
      _log.e('in-folder import failed: $e');
    }

    // Report the outcome through the global notification so the header
    // dropdown reflects it even if this screen was left mid-import.
    if (error != null) {
      GlobalNotificationService().update(
        id: notificationId,
        message: error,
        type: GlobalNotificationType.error,
        progress: null,
      );
    } else if (result != null) {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
      switch (inFolderSummaryKind(result)) {
        case InFolderSummaryKind.refusedAlreadyRunning:
          GlobalNotificationService().update(
            id: notificationId,
            message: localeAlreadyRunning,
            type: GlobalNotificationType.error,
            progress: null,
          );
        case InFolderSummaryKind.cancelled:
          // The headline is a full sentence, so the tally goes on its own
          // line; the file count only means something for a SAF run.
          GlobalNotificationService().update(
            id: notificationId,
            message: [
              localeCancelled,
              inFolderResultHasSafActivity(result)
                  ? '${result.gamesImported} $localeGames, '
                        '${result.safFilesCopied} $localeFilesCopied'
                  : '${result.gamesImported} $localeGames',
            ].join('\n'),
            type: GlobalNotificationType.info,
            progress: null,
          );
        case InFolderSummaryKind.budgetRefused:
          GlobalNotificationService().update(
            id: notificationId,
            message: _budgetRefusedText(localeBudgetRefused, result),
            type: GlobalNotificationType.error,
            progress: null,
          );
        case InFolderSummaryKind.foldersSkippedSaf:
          GlobalNotificationService().update(
            id: notificationId,
            message: localeFoldersSkipped.replaceFirst(
              '{count}',
              '${result.foldersSkippedSaf}',
            ),
            type: GlobalNotificationType.error,
            progress: null,
          );
        case InFolderSummaryKind.noGamelistsFound:
          GlobalNotificationService().update(
            id: notificationId,
            message: localeNoGamelists,
            type: GlobalNotificationType.info,
            progress: null,
          );
        case InFolderSummaryKind.counts:
          final imported =
              result.gamesImported > 0 ||
              result.systemsMatched > 0 ||
              result.mediaOnlyLinked > 0;
          GlobalNotificationService().update(
            id: notificationId,
            message: imported
                ? '$localeComplete: '
                      '${result.gamesImported} $localeGames, '
                      '${result.systemsMatched} $localeSystems'
                : localeNothingFound,
            type: imported
                ? GlobalNotificationType.success
                : GlobalNotificationType.info,
            progress: null,
          );
      }
    }

    if (!mounted) return;
    // Unlike the ES-DE path, every completed in-folder run keeps its summary:
    // a skipped-SAF or no-gamelists outcome is exactly what the user needs to
    // see explained, not a zeroed box to hide.
    // A refused start is not a run: the notification says why, and the last
    // real summary is not worth replacing with it.
    final refused = result?.refusedAlreadyRunning ?? false;
    setState(() {
      _isImporting = false;
      _lastEsdeResult = error == null && !refused ? result : null;
    });
    if (error != null || result == null || refused) return;

    // Controller-dismissable summary (A or B closes it); the inline panel
    // stays as the persistent record until the next import or reset.
    await InfoDialog.show(
      context,
      title: localeComplete,
      body: _inFolderSummaryText(result),
      okLabel: AppLocale.ok.getString(context),
      icon: Symbols.drive_folder_upload_rounded,
    );
  }

  /// Summary body for an in-folder result, shared by the inline panel and
  /// the completion dialog. Branches on [inFolderSummaryKind] so an all-SAF
  /// run is never worded as "no gamelists found", a cancel or a budget
  /// refusal gets its own headline above the counts, and a refused start
  /// shows no counts at all.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
  String _inFolderSummaryText(EsdeImportResult r) {
    switch (inFolderSummaryKind(r)) {
      case InFolderSummaryKind.refusedAlreadyRunning:
        return AppLocale.inFolderImportAlreadyRunning.getString(context);
      case InFolderSummaryKind.foldersSkippedSaf:
        return AppLocale.inFolderImportFoldersSkippedSaf
            .getString(context)
            .replaceFirst('{count}', '${r.foldersSkippedSaf}');
      case InFolderSummaryKind.noGamelistsFound:
        return AppLocale.inFolderImportNoGamelists.getString(context);
      case InFolderSummaryKind.cancelled:
        return [
          AppLocale.inFolderImportCancelled.getString(context),
          ..._inFolderCountLines(r),
        ].join('\n');
      case InFolderSummaryKind.budgetRefused:
        return [
          _budgetRefusedText(
            AppLocale.inFolderImportBudgetRefused.getString(context),
            r,
          ),
          ..._inFolderCountLines(r, includeBudgetLine: false),
        ].join('\n');
      case InFolderSummaryKind.counts:
        return _inFolderCountLines(r).join('\n');
    }
  }

  /// The per-count lines of an in-folder summary. SAF mirror tallies appear
  /// only when the run touched SAF at all; the budget line only when a
  /// refusal happened and is not already the headline.
  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
  List<String> _inFolderCountLines(
    EsdeImportResult r, {
    bool includeBudgetLine = true,
  }) {
    final lines = <String>[
      '${AppLocale.inFolderSummarySystemsFound.getString(context)}: ${r.systemsFound}   '
          '${AppLocale.esdeSummarySystemsMatched.getString(context)}: ${r.systemsMatched}   '
          '${AppLocale.esdeSummaryUnmatched.getString(context)}: ${r.systemsUnmatched}   '
          '${AppLocale.esdeSummarySkipped.getString(context)}: ${r.systemsSkipped}',
      '${AppLocale.esdeSummaryGamesImported.getString(context)}: ${r.gamesImported}   '
          '${AppLocale.esdeSummaryNoRomMatch.getString(context)}: ${r.gamesUnmatched}',
      '${AppLocale.inFolderSummaryMediaOnlyLinked.getString(context)}: ${r.mediaOnlyLinked}',
      '${AppLocale.esdeSummaryStatsUpdated.getString(context)}: ${r.statsUpdated}',
      if (r.foldersSkippedSaf > 0)
        '${AppLocale.inFolderSummaryFoldersSkippedSaf.getString(context)}: ${r.foldersSkippedSaf}',
    ];
    if (inFolderResultHasSafActivity(r)) {
      lines.add(
        '${AppLocale.inFolderSummarySafSystemsMirrored.getString(context)}: ${r.safSystemsMirrored}',
      );
      lines.add(
        '${AppLocale.inFolderSummaryFilesCopied.getString(context)}: ${r.safFilesCopied}   '
        '${AppLocale.inFolderSummaryFilesSkippedUnchanged.getString(context)}: ${r.safFilesSkippedUnchanged}   '
        '${AppLocale.inFolderSummaryFilesFailed.getString(context)}: ${r.safFilesFailed}',
      );
      lines.add(
        '${AppLocale.inFolderSummaryBytesCopied.getString(context)}: '
        '${formatByteSize(r.safBytesCopied)}',
      );
      if (r.safSystemsListingFailed > 0) {
        lines.add(
          '${AppLocale.inFolderSummarySystemsListingFailed.getString(context)}: ${r.safSystemsListingFailed}',
        );
      }
      if (includeBudgetLine && r.safBudgetRefused) {
        lines.add(
          _budgetRefusedText(
            AppLocale.inFolderImportBudgetRefused.getString(context),
            r,
          ),
        );
      }
    }
    return lines;
  }

  /// Fills the budget-refused template with the required and available byte
  /// counts. The available reading can be missing when the volume could not
  /// be measured; a dash stands in rather than a misleading zero.
  static String _budgetRefusedText(String template, EsdeImportResult r) {
    final available = r.safBudgetAvailableBytes;
    return template
        .replaceFirst('{required}', formatByteSize(r.safBudgetRequiredBytes))
        .replaceFirst(
          '{available}',
          available == null ? '\u2014' : formatByteSize(available),
        );
  }

  Future<void> _resetEsdeImport() async {
    if (_isImporting) return;

    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.esdeReset.getString(context),
      body: AppLocale.esdeResetConfirmBody.getString(context),
      confirmLabel: AppLocale.esdeReset.getString(context),
      icon: Symbols.restart_alt_rounded,
    );
    if (!confirmed || !mounted) return;

    try {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
      final outcome = await EsdeImportService.resetDetailed();
      // Fully disconnect ES-DE: also clear the selected folder so the section
      // returns to its initial "Select ES-DE Folder" state. Goes through the
      // provider (not the DB directly) so the cached config + UI update too.
      if (mounted) {
        await context.read<SqliteConfigProvider>().updateEsdeFolderPath('');
      }
      if (mounted) await context.read<FileProvider>().refreshEsde();
      if (!mounted) return;
      setState(() => _lastEsdeResult = null);
      // Recorded mirrors and swept orphans alike: every folder that went.
      final mirrorsLine = outcome.directoriesRemoved > 0
          ? ' \u00b7 ${AppLocale.esdeResetMirrorsRemoved.getString(context).replaceFirst('{count}', '${outcome.directoriesRemoved}')}'
          : '';
      AppNotification.showNotification(
        context,
        '${AppLocale.esdeResetComplete.getString(context)} '
        '(${outcome.metadataRowsDeleted})$mirrorsLine',
        type: NotificationType.info,
      );
    } on EsdeImportBusyException {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
      _log.w('ES-DE reset refused: an import is running');
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.esdeResetBusy.getString(context),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      _log.e('ES-DE reset failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '$e',
          type: NotificationType.error,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // ROM folder picker
  // ---------------------------------------------------------------------------

  Future<void> _selectRomFolder() async {
    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );

    if (configProvider.config.romFolders.length >= 5) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.maxRomFoldersReached.getString(context),
          type: NotificationType.info,
        );
      }
      return;
    }

    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (isTV) {
          if (mounted) selected = await TvDirectoryPicker.show(context);
        } else {
          try {
            final uri = await PermissionService.requestFolderAccess();
            selected = uri?.toString();
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectRomsFolder.getString(context),
        );
      }

      if (selected != null) {
        await configProvider.addRomFolder(selected);
        await _loadCurrentPaths();
      }
    } catch (e) {
      _log.e('ROM folder selection failed: $e');
    }
  }

  Future<void> _removeRomFolder(String path) async {
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.removeRomFolder.getString(context),
      body: AppLocale.removeRomFolderConfirmBody.getString(context),
      confirmLabel: AppLocale.removeRomFolder.getString(context),
      icon: Symbols.folder_delete_rounded,
    );
    if (!confirmed || !mounted) return;

    final configProvider = Provider.of<SqliteConfigProvider>(
      context,
      listen: false,
    );
    try {
      await configProvider.removeRomFolder(path);
      await _loadCurrentPaths();
      if (mounted) {
        AppNotification.showNotification(
          context,
          AppLocale.romFolderRemoved.getString(context),
          type: NotificationType.info,
        );
      }
    } catch (e) {
      _log.e('Failed to remove ROM folder: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // User data location picker + migration
  // ---------------------------------------------------------------------------

  Future<void> _selectUserDataLocation() async {
    try {
      String? selected;

      if (Platform.isAndroid) {
        final isTV = await PermissionService.isTelevision();
        if (!mounted) return;
        if (isTV) {
          selected = await TvDirectoryPicker.show(context);
        } else {
          // Regular Android: SAF picker → resolve to accessible path.
          // On Android 15+, SD card volumes require app-specific external
          // storage dirs; resolveAndroidUserDataPath handles this automatically.
          try {
            final uri = await PermissionService.requestFolderAccess();
            if (uri != null) {
              final uriStr = uri.toString();
              final hasFiles = await PermissionService.hasAllFilesAccess();
              selected =
                  await UserDataLocationService.resolveAndroidUserDataPath(
                    uriStr,
                    hasAllFilesAccess: hasFiles,
                  ) ??
                  UserDataLocationService.safUriToRealPath(uriStr);
            }
          } on PlatformException catch (e) {
            if (e.code == 'PICKER_FAILED' && mounted) {
              selected = await TvDirectoryPicker.show(context);
            }
          }
        }
      } else {
        selected = await TvDirectoryPicker.pickDirectory(
          context,
          dialogTitle: AppLocale.selectUserDataFolder.getString(context),
          initialDirectory: _currentUserDataPath,
        );
      }

      if (selected == null || !mounted) return;
      if (selected.endsWith(Platform.pathSeparator)) {
        selected = selected.substring(0, selected.length - 1);
      }

      final current = _currentUserDataPath;
      if (current == null || selected == current) return;

      // Relocating actually MOVES data (copy + delete of NeoStation's own
      // files), so confirm the source → destination move explicitly, noting
      // when the destination already contains files.
      final entryCount = await UserDataLocationService.countDirectoryEntries(
        selected,
      );
      if (!mounted) return;
      final proceed = await MoveUserDataDialog.show(
        context,
        fromPath: current,
        toPath: selected,
        destItemCount: entryCount,
      );
      if (!proceed || !mounted) return;

      await _migrateUserData(sourcePath: current, destPath: selected);
    } catch (e) {
      _log.e('User data location selection failed: $e');
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<void> _migrateUserData({
    required String sourcePath,
    required String destPath,
  }) async {
    if (!mounted) return;
    String? migrationError;

    setState(() {
      _isMigrating = true;
      _migrationProgress = 0.0;
      _migrationFile = '';
    });

    try {
      final currentMediaPath = await ConfigService.getMediaPath();
      await UserDataLocationService.migrateData(
        sourceUserDataPath: sourcePath,
        sourceMediaPath: currentMediaPath,
        destPath: destPath,
        onProgress: (p, file) {
          if (mounted) {
            setState(() {
              _migrationProgress = p;
              _migrationFile = file;
            });
          }
        },
      );
      await UserDataLocationService.setCustomPath(destPath);
      // Reinforce the SharedPreferences setup flag so that if the new path
      // (e.g. SD card) is temporarily unavailable on next boot, the wizard
      // is not shown again.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PermissionCheckWrapper.setupCompletedKey, true);
    } catch (e) {
      migrationError = e.toString();
      _log.e('Migration failed: $e');
    }

    if (mounted) setState(() => _isMigrating = false);

    if (migrationError != null) {
      if (mounted) {
        AppNotification.showNotification(
          context,
          '${AppLocale.migratingUserDataError.getString(context)}: $migrationError',
          type: NotificationType.error,
        );
      }
      return;
    }

    if (mounted) setState(() => _currentUserDataPath = destPath);

    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const RestartRequiredDialog(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Public interface for parent (gamepad delegation)
  // ---------------------------------------------------------------------------

  int getItemCount() => _directoryItems.length;

  void selectItem(int index) {
    if (index < _directoryItems.length) {
      _handleItemTap(_directoryItems[index]);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  Widget _buildMigrationProgress(ThemeData theme) {
    if (!_isMigrating) return const SizedBox.shrink();
    final pct = _migrationProgress;
    final isCopying = pct < 0.5;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isCopying
                    ? AppLocale.migratingUserData.getString(context)
                    : '${AppLocale.delete.getString(context)}...',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_migrationFile.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _migrationFile,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScanProgress(ThemeData theme, SqliteConfigProvider provider) {
    if (!provider.isScanning) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                provider.scanStatus,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(provider.scanProgress * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              // null = indeterminate while system count not yet known
              value: provider.totalSystemsToScan > 0
                  ? provider.scanProgress
                  : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (provider.totalSystemsToScan > 0) ...[
            SizedBox(height: 4.r),
            Text(
              '${AppLocale.scanningSystem.getString(context)} ${provider.scannedSystemsCount} of ${provider.totalSystemsToScan}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(
            title: AppLocale.configureDirectories.getString(context),
            subtitle: AppLocale.configureRomsFolder.getString(context),
          ),
          SizedBox(height: 24.h),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }

    return Consumer<SqliteConfigProvider>(
      builder: (context, configProvider, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsTitle(
              title: AppLocale.configureDirectories.getString(context),
              subtitle: AppLocale.configureRomsFolder.getString(context),
            ),
            SizedBox(height: 12.r),
            _buildMigrationProgress(theme),
            _buildScanProgress(theme, configProvider),
            _buildEsdeProgress(theme),
            _buildEsdeResultSummary(theme),
            Expanded(
              child: Builder(
                builder: (context) {
                  // Precompute visual rows: either a section header or a
                  // navigable item, so header insertion stays robust as the
                  // ROM-folder count changes.
                  final visualRows = <Map<String, dynamic>>[];
                  for (var i = 0; i < _directoryItems.length; i++) {
                    // "ROM Directories" header before add_rom (nav index 2).
                    if (i == 2) {
                      visualRows.add({
                        'header': AppLocale.romDirectories.getString(context),
                      });
                    }
                    // "ES-DE Import" header before the first ES-DE item.
                    if (i == _esdeSectionStart) {
                      visualRows.add({
                        'header': AppLocale.esdeImport.getString(context),
                      });
                    }
                    visualRows.add({'nav': i});
                  }
                  _ensureKeys(_directoryItems.length);

                  return ListView.builder(
                    controller: _scrollController,
                    physics: const ClampingScrollPhysics(),
                    itemCount: visualRows.length,
                    itemBuilder: (context, visualIndex) {
                      final row = visualRows[visualIndex];
                      if (row.containsKey('header')) {
                        return SettingsSectionHeader(
                          label: row['header'] as String,
                        );
                      }

                      final navIndex = row['nav'] as int;
                      final item = _directoryItems[navIndex];
                      final isSelected =
                          widget.isContentFocused &&
                          widget.selectedContentIndex == navIndex;

                      final isRemoveItem = item['action'] == 'remove_rom';
                      final isUserData = item['action'] == 'user_data';
                      final isEsdeDisabled = _isEsdeDisabled(
                        item['action'] as String,
                      );
                      final borderColor = isSelected
                          ? (isRemoveItem
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary)
                          : theme.colorScheme.outline.withValues(alpha: 0);

                      return Opacity(
                        key: _itemKeys[navIndex],
                        opacity: isEsdeDisabled ? 0.4 : 1.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected && isRemoveItem
                                ? theme.colorScheme.error.withValues(
                                    alpha: 0.08,
                                  )
                                : theme.cardColor.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                              color: borderColor,
                              width: isSelected ? 2.r : 1.r,
                            ),
                          ),
                          margin: EdgeInsets.only(bottom: 8.r),
                          child: InkWell(
                            onTap: isEsdeDisabled
                                ? null
                                : () {
                                    SfxService().playNavSound();
                                    _handleItemTap(item);
                                  },
                            borderRadius: BorderRadius.circular(12.r),
                            canRequestFocus: false,
                            focusColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            highlightColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12.r,
                                vertical: 8.r,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        _iconFor(item['action'] as String),
                                        color: isSelected
                                            ? (isRemoveItem
                                                  ? theme.colorScheme.error
                                                  : theme.colorScheme.primary)
                                            : theme.colorScheme.onSurface,
                                        size: 20.r,
                                      ),
                                      SizedBox(width: 12.r),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              isRemoveItem
                                                  ? (item['title'] as String)
                                                  : (item['title'] as String)
                                                        .getString(context),
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: isRemoveItem
                                                        ? 10.r
                                                        : 12.r,
                                                    color: isSelected
                                                        ? (isRemoveItem
                                                              ? theme
                                                                    .colorScheme
                                                                    .error
                                                              : theme
                                                                    .colorScheme
                                                                    .primary)
                                                        : theme
                                                              .colorScheme
                                                              .onSurface,
                                                    fontFamily: isRemoveItem
                                                        ? 'monospace'
                                                        : null,
                                                  ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(height: 2.r),
                                            Text(
                                              (item['subtitle'] as String)
                                                  .getString(context),
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        isSelected &&
                                                            isRemoveItem
                                                        ? theme
                                                              .colorScheme
                                                              .error
                                                              .withValues(
                                                                alpha: 0.7,
                                                              )
                                                        : theme
                                                              .colorScheme
                                                              .onSurface
                                                              .withValues(
                                                                alpha: 0.6,
                                                              ),
                                                    fontSize: 9.r,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isRemoveItem)
                                        SettingsActionButton(
                                          icon: Symbols.delete_outline_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        )
                                      else if (item['action'] == 'add_rom')
                                        SettingsActionButton(
                                          icon: Symbols.add_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'rescan')
                                        SettingsActionButton(
                                          icon: Symbols.refresh_rounded,
                                          selected: isSelected,
                                        )
                                      else if (isUserData)
                                        SettingsActionButton(
                                          icon: Symbols.edit_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_select_folder')
                                        SettingsActionButton(
                                          icon: Symbols.folder_special_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] ==
                                          'esde_run_import')
                                        SettingsActionButton(
                                          icon: Symbols.download_rounded,
                                          selected: isSelected,
                                        )
                                      else if (item['action'] == 'esde_reset')
                                        SettingsActionButton(
                                          icon: Symbols.restart_alt_rounded,
                                          selected: isSelected,
                                          isDestructive: true,
                                        )
                                      else if (item['action'] ==
                                          'import_rom_folders')
                                        SettingsActionButton(
                                          icon: Symbols
                                              .drive_folder_upload_rounded,
                                          selected: isSelected,
                                        ),
                                    ],
                                  ),
                                  // Show current ES-DE folder under its select item
                                  if (item['action'] == 'esde_select_folder' &&
                                      _esdePath.trim().isNotEmpty) ...[
                                    SizedBox(height: 6.r),
                                    _buildPathChip(theme, _esdePath),
                                  ],
                                  // Show current path under user_data item
                                  if (isUserData &&
                                      _currentUserDataPath != null) ...[
                                    SizedBox(height: 6.r),
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8.r,
                                        vertical: 4.r,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.06),
                                        borderRadius: BorderRadius.circular(
                                          6.r,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Symbols.folder_rounded,
                                            size: 11.r,
                                            color: theme.colorScheme.primary
                                                .withValues(alpha: 0.5),
                                          ),
                                          SizedBox(width: 6.r),
                                          Expanded(
                                            child: Text(
                                              _currentUserDataPath!,
                                              style: TextStyle(
                                                fontSize: 9.r,
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.55),
                                                fontFamily: 'monospace',
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  IconData _iconFor(String action) {
    switch (action) {
      case 'user_data':
        return Symbols.folder_special_rounded;
      case 'rescan':
        return Symbols.refresh_rounded;
      case 'add_rom':
        return Symbols.folder_rounded;
      case 'remove_rom':
        return Symbols.folder_rounded;
      case 'esde_select_folder':
        return Symbols.folder_special_rounded;
      case 'esde_run_import':
        return Symbols.download_rounded;
      case 'esde_reset':
        return Symbols.restart_alt_rounded;
      case 'import_rom_folders':
        return Symbols.drive_folder_upload_rounded;
      default:
        return Symbols.folder_rounded;
    }
  }

  Widget _buildPathChip(ThemeData theme, String path) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Row(
        children: [
          Icon(
            Symbols.folder_rounded,
            size: 11.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.5),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEsdeProgress(ThemeData theme) {
    if (!_isImporting) return const SizedBox.shrink();
    final pct = _importProgress;
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1.r,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                (_importingInFolder
                        ? AppLocale.inFolderImporting
                        : AppLocale.esdeImporting)
                    .getString(context),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${(pct * 100).toInt()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.r,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.r),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: pct > 0 ? pct : null,
              minHeight: 6.r,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          if (_importLabel.isNotEmpty) ...[
            SizedBox(height: 4.r),
            Text(
              _importLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEsdeResultSummary(ThemeData theme) {
    final r = _lastEsdeResult;
    if (r == null || _isImporting) return const SizedBox.shrink();
    final inFolder = r.mode == GamelistSourceMode.inFolder;
    final body = inFolder
        ? _inFolderSummaryText(r)
        : '${AppLocale.esdeSummarySystemsMatched.getString(context)}: ${r.systemsMatched}   '
              '${AppLocale.esdeSummaryUnmatched.getString(context)}: ${r.systemsUnmatched}   '
              '${AppLocale.esdeSummarySkipped.getString(context)}: ${r.systemsSkipped}\n'
              '${AppLocale.esdeSummaryGamesImported.getString(context)}: ${r.gamesImported}   '
              '${AppLocale.esdeSummaryNoRomMatch.getString(context)}: ${r.gamesUnmatched}\n'
              '${AppLocale.esdeSummaryStatsUpdated.getString(context)}: ${r.statsUpdated}';
    return Container(
      margin: EdgeInsets.only(bottom: 12.r),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (inFolder
                    ? AppLocale.inFolderImportComplete
                    : AppLocale.esdeImportComplete)
                .getString(context),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: 11.r,
              color: theme.colorScheme.primary,
            ),
          ),
          SizedBox(height: 4.r),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 9.5.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
