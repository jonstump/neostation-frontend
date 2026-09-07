import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_locale.dart';
import '../models/romm_firmware_row.dart';
import '../models/system_model.dart';
import '../services/bios_destination_service.dart';
import '../services/game_service.dart' show GamepadNavigationManager;
import '../services/global_notification_service.dart';
import '../services/logger_service.dart';
import '../services/romm/romm_firmware_service.dart';
import '../services/romm_service.dart';
import '../services/saf_directory_service.dart';
import '../services/sfx_service.dart';
import '../utils/gamepad_nav.dart';
import 'custom_notification.dart';
import 'tv_directory_picker.dart';

/// The per-system BIOS panel: one row per firmware file RomM holds for the
/// system's platform, what the local BIOS destination has, and the actions that
/// change that.
///
/// Navigation is entirely controller-driven, like every other full-screen or
/// modal surface in the app: up/down moves between rows and the two footer
/// actions, left/right picks which of a row's actions is armed, A activates it,
/// and B cancels a running download or — when nothing is running — closes the
/// panel. The gamepad layer is pushed in the same post-frame callback as
/// [GamepadNavigation.initialize] and popped in [dispose], so returning here
/// from anywhere else wakes exactly this panel and not the dialog underneath.
///
/// The panel owns no RomM connection: it is handed a configured [RommService]
/// and the resolved platform id, and everything it writes goes through
/// [BiosDestinationService] and [RommFirmwareService].
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
class RommFirmwarePanel extends StatefulWidget {
  /// The system whose BIOS files these are; names the panel and picks the
  /// destination.
  final SystemModel system;

  /// RomM platform the system resolved to.
  final int platformId;

  /// The connected client the list and the downloads go through.
  final RommService service;

  /// Resolver for the BIOS destination. Defaults to the shared instance; a
  /// widget test injects one with scripted collaborators so all three
  /// destination states can be driven without a RetroArch install, a database
  /// or a real filesystem.
  final BiosDestinationService? destinationService;

  /// How "Choose BIOS folder" asks for a folder, given the panel's context.
  /// Defaults to the SAF tree on Android and the desktop picker elsewhere; a
  /// widget test injects a closure so the pick is deterministic and needs no
  /// platform dialog.
  final Future<String?> Function(BuildContext context)? folderPicker;

  const RommFirmwarePanel({
    super.key,
    required this.system,
    required this.platformId,
    required this.service,
    this.destinationService,
    this.folderPicker,
  });

  static Future<void> show(
    BuildContext context, {
    required SystemModel system,
    required int platformId,
    required RommService service,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommFirmwarePanel(
        system: system,
        platformId: platformId,
        service: service,
      ),
    );
  }

  @override
  State<RommFirmwarePanel> createState() => _RommFirmwarePanelState();
}

class _RommFirmwarePanelState extends State<RommFirmwarePanel> {
  static const _layerName = 'romm_firmware_panel';
  static final _log = LoggerService.instance;

  late final GamepadNavigation _gamepadNav;
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  List<RommFirmwareRow> _rows = const [];
  String? _destDir;

  /// Which candidate supplied [_destDir], or null when there is none.
  ///
  /// Presentation only: it picks which destination line is shown, so the user
  /// can tell a folder they chose from the one RetroArch supplied. It does
  /// *not* gate the picker — SPEC-0012 REQ "BIOS Destination" has the panel
  /// always offering to pick a folder, and an explicit choice outranks the
  /// RetroArch default on every later open.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  BiosDestinationSource? _destSource;
  bool _loading = true;

  /// The localized line explaining why there are no rows, already rendered
  /// (the list-failure key carries an `{error}` placeholder), or null.
  String? _emptyMessage;

  /// Focused item: `0..._rows.length-1` are rows, then the footer actions.
  int _selected = 0;

  /// Which of the focused row's actions is armed (left/right).
  int _actionIndex = 0;

  bool _busy = false;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onNavigateLeft: () => _moveAction(-1),
      onNavigateRight: () => _moveAction(1),
      onSelectItem: _activate,
      onBack: _back,
    );
    // Layer and navigator come up together: a navigator activated without a
    // registered layer is invisible to the manager, and the screen underneath
    // would answer the same button press.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerName,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerName);
    _gamepadNav.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  /// Resolves the destination, lists the platform's firmware, and describes
  /// each file against the destination.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  /// The resolver this panel reads and writes the destination through.
  BiosDestinationService get _destinations =>
      widget.destinationService ?? BiosDestinationService.instance;

  Future<void> _load() async {
    final resolved = await _destinations.resolveDestination(widget.system);
    final dest = resolved?.directory;
    List<RommFirmwareRow> rows = const [];
    // The key to explain an empty list with, and the failure detail its
    // `{error}` placeholder takes; both null on a normal, non-empty listing.
    String? emptyKey;
    String? errorDetail;
    try {
      final listed = await widget.service.listFirmware(widget.platformId);
      rows = await RommFirmwareService.describe(listed, dest);
      if (rows.isEmpty) emptyKey = AppLocale.rommFirmwareEmpty;
    } on RommException catch (e) {
      // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Error Handling Standards"
      _log.w(
        'RomM firmware list failed: system=${widget.system.folderName} '
        'platform=${widget.platformId} status=${e.statusCode ?? '-'} '
        'kind=${e.kind.name} cause=${e.message}',
      );
      if (e.kind == RommErrorKind.scopeDenied) {
        emptyKey = AppLocale.rommFirmwareScopeDenied;
      } else {
        emptyKey = AppLocale.rommFirmwareListFailed;
        errorDetail = e.message;
      }
    } catch (e) {
      _log.w(
        'RomM firmware list failed: system=${widget.system.folderName} '
        'platform=${widget.platformId} cause=$e',
      );
      emptyKey = AppLocale.rommFirmwareListFailed;
      errorDetail = '$e';
    }
    if (!mounted) return;
    final empty = emptyKey
        ?.getString(context)
        .replaceFirst('{error}', errorDetail ?? '');
    setState(() {
      _destDir = dest;
      _destSource = resolved?.source;
      _rows = rows;
      _emptyMessage = empty;
      _loading = false;
      _selected = 0;
      _actionIndex = 0;
    });
  }

  /// Re-reads every row's local state against the current destination.
  Future<void> _refreshStates() async {
    final dest = _destDir;
    final refreshed = await RommFirmwareService.describe(
      _rows.map((r) => r.firmware).toList(),
      dest,
    );
    if (!mounted) return;
    setState(() => _rows = refreshed);
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  bool get _hasDestination => (_destDir ?? '').isNotEmpty;

  /// Footer actions, in order, after the firmware rows.
  ///
  /// "Choose BIOS folder" is unconditional: SPEC-0012 REQ "BIOS Destination"
  /// requires the panel to always offer it, and it is the *only* caller of
  /// [BiosDestinationService.setBiosDirectory] — hiding it while RetroArch
  /// supplied the destination left no in-app way to set or change
  /// `user_config.bios_directory` at all. "Download all missing" is the
  /// conditional one, so the footer list grows and shrinks ahead of the
  /// picker; every index into it is bounds-checked for that reason.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  List<_FooterAction> get _footerActions => [
    if (RommFirmwareRow.canDownloadAll(
          _rows,
          hasDestination: _hasDestination,
          busy: false,
        ) ||
        _busy)
      _FooterAction.downloadAll,
    _FooterAction.chooseFolder,
  ];

  int get _itemCount => _rows.length + _footerActions.length;

  /// The actions the focused row offers, in left-to-right order.
  List<_RowAction> _actionsFor(RommFirmwareRow row) => [
    if (row.canDownload && _hasDestination && !_busy) _RowAction.download,
    if (row.canVerify) _RowAction.verify,
  ];

  void _move(int delta) {
    if (_itemCount == 0) return;
    SfxService().playNavSound();
    setState(() {
      _selected = (_selected + delta + _itemCount) % _itemCount;
      _actionIndex = 0;
    });
    _scrollToSelected();
  }

  void _moveAction(int delta) {
    if (_selected >= _rows.length) return;
    final actions = _actionsFor(_rows[_selected]);
    if (actions.length < 2) return;
    SfxService().playNavSound();
    setState(() {
      _actionIndex = (_actionIndex + delta + actions.length) % actions.length;
    });
  }

  void _scrollToSelected() {
    final key = _itemKeys[_selected];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void _activate() {
    // Nothing is rendered during the initial load, so a press here would arm an
    // action the user cannot see — and the folder it picked would be
    // overwritten by [_load]'s own setState moments later.
    if (_loading) return;
    if (_selected < _rows.length) {
      final row = _rows[_selected];
      final actions = _actionsFor(row);
      if (actions.isEmpty) return;
      final action = actions[_actionIndex.clamp(0, actions.length - 1)];
      switch (action) {
        case _RowAction.download:
          unawaited(_runDownloads([row]));
        case _RowAction.verify:
          unawaited(_verify(_selected));
      }
      return;
    }
    final footers = _footerActions;
    final footerIndex = _selected - _rows.length;
    if (footerIndex < 0 || footerIndex >= footers.length) return;
    final footer = footers[footerIndex];
    switch (footer) {
      case _FooterAction.downloadAll:
        if (_busy) {
          _requestCancel();
        } else {
          unawaited(_runDownloads(RommFirmwareRow.downloadableMissing(_rows)));
        }
      case _FooterAction.chooseFolder:
        unawaited(_chooseFolder());
    }
  }

  /// B: stops a running download first, and only closes the panel when nothing
  /// is running — so a press mid-transfer never silently abandons a half-file.
  void _back() {
    if (_busy) {
      _requestCancel();
      return;
    }
    if (!mounted) return;
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _requestCancel() {
    if (!_busy || _cancelRequested) return;
    SfxService().playBackSound();
    setState(() => _cancelRequested = true);
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Streams the local md5 of the focused row's file off the UI isolate and
  /// records whether it matches the server's.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  Future<void> _verify(int index) async {
    final dest = _destDir;
    if (dest == null || index >= _rows.length) return;
    final row = _rows[index];
    setState(() {
      _rows = _replace(
        index,
        row.copyWith(verify: RommFirmwareVerifyState.checking),
      );
    });
    final result = await RommFirmwareService.verify(row.firmware, dest);
    if (!mounted) return;
    setState(
      () => _rows = _replace(index, _rows[index].copyWith(verify: result)),
    );
  }

  /// Downloads [targets] one after another, reporting per-file progress in the
  /// global notification and refreshing each row as it lands.
  ///
  /// Every string the run needs is resolved before the first await, so no
  /// `BuildContext` is read across one.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  Future<void> _runDownloads(List<RommFirmwareRow> targets) async {
    final dest = _destDir;
    if (_busy || dest == null || targets.isEmpty) return;

    final progressTemplate = AppLocale.rommFirmwareDownloadProgress.getString(
      context,
    );
    final summaryTemplate = AppLocale.rommFirmwareDownloadSummary.getString(
      context,
    );
    final cancelledTemplate = AppLocale.rommFirmwareDownloadCancelled.getString(
      context,
    );
    final failedFileTemplate = AppLocale.rommFirmwareDownloadFailedFile
        .getString(context);
    final scopeDeniedMessage = AppLocale.rommFirmwareScopeDenied.getString(
      context,
    );

    final notifications = GlobalNotificationService();
    final notificationId = 'romm_firmware_${widget.system.folderName}';
    final total = targets.length;
    var downloaded = 0;
    var failed = 0;
    var cancelled = false;
    String? fatal;

    setState(() {
      _busy = true;
      _cancelRequested = false;
    });

    notifications.show(
      id: notificationId,
      message: progressTemplate
          .replaceFirst('{file}', targets.first.firmware.fileName)
          .replaceFirst('{done}', '1')
          .replaceFirst('{total}', '$total'),
      icon: Symbols.memory_rounded,
      type: GlobalNotificationType.info,
      progress: 0,
      ongoing: true,
    );

    for (var i = 0; i < targets.length; i++) {
      if (_cancelRequested) {
        cancelled = true;
        break;
      }
      final firmware = targets[i].firmware;
      final message = progressTemplate
          .replaceFirst('{file}', firmware.fileName)
          .replaceFirst('{done}', '${i + 1}')
          .replaceFirst('{total}', '$total');
      notifications.update(
        id: notificationId,
        message: message,
        type: GlobalNotificationType.info,
        progress: i / total,
        ongoing: true,
      );
      _setDownloading(firmware.fileName, downloading: true, progress: null);

      final result = await RommFirmwareService.download(
        firmware,
        service: widget.service,
        destDir: dest,
        shouldCancel: () => _cancelRequested,
        onProgress: (received, contentLength) {
          final fraction = (contentLength == null || contentLength <= 0)
              ? null
              : received / contentLength;
          notifications.update(
            id: notificationId,
            message: message,
            type: GlobalNotificationType.info,
            progress: (i + (fraction ?? 0)) / total,
            ongoing: true,
          );
          _setDownloading(
            firmware.fileName,
            downloading: true,
            progress: fraction,
          );
        },
      );

      _setDownloading(firmware.fileName, downloading: false, progress: null);

      switch (result) {
        case RommFirmwareDownloadResult.downloaded:
          downloaded++;
        case RommFirmwareDownloadResult.cancelled:
          cancelled = true;
        case RommFirmwareDownloadResult.scopeDenied:
          failed++;
          fatal = scopeDeniedMessage;
        case RommFirmwareDownloadResult.serverMissing:
        case RommFirmwareDownloadResult.failed:
          failed++;
          fatal ??= failedFileTemplate.replaceFirst(
            '{file}',
            firmware.fileName,
          );
      }

      // Refresh from disk rather than assuming: a rename that landed and a
      // transfer that did not both answer here.
      await _refreshStates();
      if (!mounted) {
        // The route popped mid-run. The notification is global and outlives
        // this widget, so it has to be closed out here or it stays pinned as
        // an in-progress transfer that will never finish.
        // Governing: SPEC-0012 REQ "Error Handling Standards"
        notifications.update(
          id: notificationId,
          message: summaryTemplate
              .replaceFirst('{downloaded}', '$downloaded')
              .replaceFirst('{failed}', '$failed'),
          type: failed > 0
              ? GlobalNotificationType.error
              : GlobalNotificationType.success,
          progress: null,
        );
        return;
      }
      if (cancelled || result == RommFirmwareDownloadResult.scopeDenied) break;
    }

    final summary = summaryTemplate
        .replaceFirst('{downloaded}', '$downloaded')
        .replaceFirst('{failed}', '$failed');
    notifications.update(
      id: notificationId,
      message: cancelled
          ? cancelledTemplate.replaceFirst('{summary}', summary)
          : (fatal == null ? summary : '$summary — $fatal'),
      type: cancelled
          ? GlobalNotificationType.info
          : (failed > 0
                ? GlobalNotificationType.error
                : GlobalNotificationType.success),
      progress: null,
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _cancelRequested = false;
      if (_selected >= _itemCount) _selected = _itemCount - 1;
      if (_selected < 0) _selected = 0;
    });
  }

  /// Picks a BIOS folder — a SAF tree on Android, the native picker elsewhere —
  /// persists it, and re-describes every row against it.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  Future<void> _chooseFolder() async {
    if (_busy) return;
    final failedMessage = AppLocale.rommFirmwareFolderFailed.getString(context);
    String? picked;
    final injectedPicker = widget.folderPicker;
    if (injectedPicker != null) {
      picked = await injectedPicker(context);
    } else if (Platform.isAndroid) {
      // The SAF tree URI is stored verbatim; BiosDestinationService translates
      // its %2F-encoded form to a real path on every read.
      picked = await SafDirectoryService.requestDirectoryAccess();
    } else {
      picked = await TvDirectoryPicker.pickDirectory(
        context,
        dialogTitle: AppLocale.rommFirmwareActionChooseFolder.getString(
          context,
        ),
      );
    }
    if (picked == null || picked.trim().isEmpty) return;

    final resolved = await _destinations.setBiosDirectory(picked);
    if (!mounted) return;
    if (resolved == null) {
      AppNotification.showNotification(
        context,
        failedMessage,
        type: NotificationType.error,
      );
      return;
    }
    // Keep the cursor on the action the user just used. A new destination can
    // make "Download all missing" appear (or, if the folder already holds every
    // file, disappear), and that entry sits *ahead* of the picker — without
    // this the focus ring would land on whatever slid under the user's thumb.
    final wasOnChooseFolder =
        _selected >= _rows.length &&
        _selected - _rows.length < _footerActions.length &&
        _footerActions[_selected - _rows.length] == _FooterAction.chooseFolder;
    setState(() {
      _destDir = resolved;
      _destSource = BiosDestinationSource.configured;
    });
    // The refresh has to land first: "Download all missing" is derived from the
    // rows' local state, and until they have been re-described against the new
    // folder they still read `unknownDestination`, so the footer list read here
    // would be the pre-refresh one and the cursor would be put back on an index
    // that means something else a moment later.
    await _refreshStates();
    if (!mounted) return;
    setState(() {
      if (wasOnChooseFolder) {
        final index = _footerActions.indexOf(_FooterAction.chooseFolder);
        if (index >= 0) _selected = _rows.length + index;
      }
      // Whatever the cursor was on, it must still name an item: the footer can
      // also lose an entry here.
      if (_selected >= _itemCount) _selected = _itemCount - 1;
      if (_selected < 0) _selected = 0;
    });
  }

  List<RommFirmwareRow> _replace(int index, RommFirmwareRow row) {
    final copy = List<RommFirmwareRow>.from(_rows);
    copy[index] = row;
    return copy;
  }

  void _setDownloading(
    String fileName, {
    required bool downloading,
    double? progress,
  }) {
    if (!mounted) return;
    final index = _rows.indexWhere((r) => r.firmware.fileName == fileName);
    if (index == -1) return;
    setState(() {
      _rows = _replace(
        index,
        _rows[index].copyWith(
          downloading: downloading,
          progress: progress,
          clearProgress: progress == null,
        ),
      );
    });
  }

  // ── Presentation ──────────────────────────────────────────────────────────

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
          Icon(Symbols.memory_rounded, color: accent, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              AppLocale.rommFirmwarePanelTitle
                  .getString(context)
                  .replaceFirst('{system}', widget.system.realName),
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
        constraints: BoxConstraints(maxWidth: 520.r, maxHeight: 320.r),
        child: SizedBox(width: 520.r, child: _buildBody()),
      ),
      actions: [_buildCloseHint(theme)],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Text(
          AppLocale.rommFirmwareLoading.getString(context),
          style: TextStyle(fontSize: 11.r),
        ),
      );
    }
    final empty = _emptyMessage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildDestinationLine(),
        SizedBox(height: 6.r),
        Flexible(
          child: empty != null
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16.r),
                    child: Text(
                      empty,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11.r,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  shrinkWrap: true,
                  itemCount: _rows.length,
                  itemBuilder: (context, index) =>
                      _buildFirmwareRow(index, _rows[index]),
                ),
        ),
        SizedBox(height: 6.r),
        ..._buildFooterActions(),
      ],
    );
  }

  Widget _buildDestinationLine() {
    final theme = Theme.of(context);
    final dest = _destDir;
    // Naming RetroArch as the source is what makes the always-present picker
    // legible: this path is a default the app discovered, not one the user
    // chose, and "Choose BIOS folder" right below it will outrank it.
    // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
    final text = dest == null
        ? AppLocale.rommFirmwareDestinationMissing.getString(context)
        : (_destSource == BiosDestinationSource.retroArch
                  ? AppLocale.rommFirmwareDestinationRetroArch
                  : AppLocale.rommFirmwareDestination)
              .getString(context)
              .replaceFirst('{path}', dest);
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 9.r,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      ),
    );
  }

  /// One firmware file: name and size, its local state, the verify verdict,
  /// and the actions that apply to it.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  Widget _buildFirmwareRow(int index, RommFirmwareRow row) {
    final theme = Theme.of(context);
    final focused = _selected == index;
    final accent = theme.colorScheme.primary;
    final key = _itemKeys[index] ??= GlobalKey(
      debugLabel: 'romm_firmware_$index',
    );
    final actions = _actionsFor(row);

    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: 4.r),
      child: InkWell(
        onTap: () {
          SfxService().playNavSound();
          setState(() {
            _selected = index;
            _actionIndex = 0;
          });
        },
        borderRadius: BorderRadius.circular(9.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
          decoration: BoxDecoration(
            color: focused
                ? accent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9.r),
            border: Border.all(
              color: focused
                  ? accent.withValues(alpha: 0.6)
                  : theme.colorScheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.firmware.fileName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.r,
                              fontWeight: FontWeight.w600,
                              color: focused
                                  ? accent
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (row.firmware.isVerified) ...[
                          SizedBox(width: 4.r),
                          Tooltip(
                            message: AppLocale.rommFirmwareVerifiedByServer
                                .getString(context),
                            child: Icon(
                              Symbols.verified_rounded,
                              size: 12.r,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: 2.r),
                    Text(
                      '${_formatSize(row.firmware.fileSizeBytes)} · '
                      '${_stateLabel(row)}',
                      style: TextStyle(
                        fontSize: 9.r,
                        color: _stateColor(theme, row),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.r),
              if (row.downloading)
                SizedBox(
                  width: 60.r,
                  child: LinearProgressIndicator(
                    value: row.progress,
                    minHeight: 4.r,
                  ),
                )
              else
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) SizedBox(width: 4.r),
                  _buildActionPill(
                    label: actions[i] == _RowAction.download
                        ? AppLocale.rommFirmwareActionDownload.getString(
                            context,
                          )
                        : AppLocale.rommFirmwareActionVerify.getString(context),
                    icon: actions[i] == _RowAction.download
                        ? Symbols.download_rounded
                        : Symbols.fact_check_rounded,
                    armed: focused && _actionIndex == i,
                    onTap: () {
                      setState(() {
                        _selected = index;
                        _actionIndex = i;
                      });
                      _activate();
                    },
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFooterActions() {
    final footers = _footerActions;
    final widgets = <Widget>[];
    for (var i = 0; i < footers.length; i++) {
      final index = _rows.length + i;
      final key = _itemKeys[index] ??= GlobalKey(
        debugLabel: 'romm_firmware_footer_$i',
      );
      final downloadAll = footers[i] == _FooterAction.downloadAll;
      final label = downloadAll
          ? (_busy
                ? AppLocale.cancel.getString(context)
                : AppLocale.rommFirmwareActionDownloadAll.getString(context))
          : AppLocale.rommFirmwareActionChooseFolder.getString(context);
      widgets.add(
        Padding(
          key: key,
          padding: EdgeInsets.only(bottom: 4.r),
          child: _buildFooterRow(
            label: label,
            icon: downloadAll
                ? (_busy ? Symbols.cancel_rounded : Symbols.download_rounded)
                : Symbols.folder_open_rounded,
            focused: _selected == index,
            onTap: () {
              SfxService().playNavSound();
              setState(() {
                _selected = index;
                _actionIndex = 0;
              });
              _activate();
            },
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildFooterRow({
    required String label,
    required IconData icon,
    required bool focused,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
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
          children: [
            Icon(icon, size: 14.r, color: accent),
            SizedBox(width: 8.r),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.r,
                  fontWeight: FontWeight.w600,
                  color: focused ? accent : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionPill({
    required String label,
    required IconData icon,
    required bool armed,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color = armed
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 3.r),
        decoration: BoxDecoration(
          color: color.withValues(alpha: armed ? 0.2 : 0.08),
          borderRadius: BorderRadius.circular(4.r),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1.r),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11.r, color: color),
            SizedBox(width: 3.r),
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
      ),
    );
  }

  Widget _buildCloseHint(ThemeData theme) {
    return TextButton(
      onPressed: _back,
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
            _busy
                ? AppLocale.cancel.getString(context)
                : AppLocale.close.getString(context),
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 12.r,
            ),
          ),
        ],
      ),
    );
  }

  String _stateLabel(RommFirmwareRow row) {
    switch (row.verify) {
      case RommFirmwareVerifyState.checking:
        return AppLocale.rommFirmwareVerifyChecking.getString(context);
      case RommFirmwareVerifyState.match:
        return AppLocale.rommFirmwareVerifyMatch.getString(context);
      case RommFirmwareVerifyState.mismatch:
        return AppLocale.rommFirmwareVerifyMismatch.getString(context);
      case RommFirmwareVerifyState.unreadable:
        return AppLocale.rommFirmwareVerifyUnreadable.getString(context);
      case RommFirmwareVerifyState.unchecked:
        break;
    }
    switch (row.state) {
      case RommFirmwareLocalState.present:
        return AppLocale.rommFirmwareStatePresent.getString(context);
      case RommFirmwareLocalState.missing:
        return AppLocale.rommFirmwareStateMissing.getString(context);
      case RommFirmwareLocalState.serverMissing:
        return AppLocale.rommFirmwareStateServerMissing.getString(context);
      case RommFirmwareLocalState.unknownDestination:
        return AppLocale.rommFirmwareStateNoFolder.getString(context);
    }
  }

  Color _stateColor(ThemeData theme, RommFirmwareRow row) {
    if (row.verify == RommFirmwareVerifyState.mismatch ||
        row.verify == RommFirmwareVerifyState.unreadable ||
        row.state == RommFirmwareLocalState.serverMissing) {
      return theme.colorScheme.error;
    }
    if (row.verify == RommFirmwareVerifyState.match ||
        row.state == RommFirmwareLocalState.present) {
      return theme.colorScheme.primary;
    }
    return theme.colorScheme.onSurface.withValues(alpha: 0.6);
  }

  /// Byte counts are shown with untranslated SI-ish units, as everywhere else
  /// in the app.
  static String _formatSize(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// An action a firmware row can offer, left to right.
enum _RowAction { download, verify }

/// The panel's list-level actions, below the rows.
enum _FooterAction { downloadAll, chooseFolder }
