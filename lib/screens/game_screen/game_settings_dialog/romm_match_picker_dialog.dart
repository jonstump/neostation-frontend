import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/rom_fingerprint.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_controller.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_dialog.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_match_picker_controller.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/retroachievements_hash_service.dart';
import 'package:neostation/services/rom_fingerprint_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/utils/romm_link_state.dart';
import 'package:neostation/widgets/custom_notification.dart';

/// The picker's row layout: the one place that maps between a *slot* — the
/// D-pad row index the dialog keeps in `_selectedIndex` — and what that slot
/// means.
///
/// Slot 0 is the search field, slots `1..actionCount` are the action rows
/// ("Match by hash" when the server may have the endpoint, then the RomM
/// fix-up actions), and every slot after them is a search result (or the
/// single retry row). Every index computation in the dialog goes through this
/// rather than carrying its own offset: rows have been inserted above the
/// results twice already (the fix-up actions, then match by hash), and a
/// literal `+ 1` left behind by such an insertion silently highlights the
/// wrong row — which A then confirms as the manual link.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
@immutable
class RommMatchPickerSlots {
  /// How many fix-up action rows sit between the field and the results.
  final int actionCount;

  const RommMatchPickerSlots({required this.actionCount});

  /// The first slot a search result — or the retry row — can occupy.
  int get resultBase => 1 + actionCount;

  /// The slot showing the result at [resultIndex].
  int slotForResult(int resultIndex) => resultBase + resultIndex;

  /// The result [slot] shows, or null when it is the field or an action row.
  int? resultForSlot(int slot) => slot < resultBase ? null : slot - resultBase;

  /// The slot showing the fix-up action at [actionIndex].
  int slotForAction(int actionIndex) => 1 + actionIndex;

  /// The fix-up action [slot] shows, or null when [slot] is not an action row.
  int? actionForSlot(int slot) =>
      (slot < 1 || slot >= resultBase) ? null : slot - 1;

  /// How many slots the dialog has with [rowCount] rows under the actions.
  int itemCount(int rowCount) => resultBase + rowCount;
}

/// The action rows between the search field and the results, in row order.
enum _PickerAction {
  /// Fingerprint the local file and ask the server which ROM it is.
  matchByHash,

  /// "Fix match on RomM" for the linked entry.
  fixMatch,

  /// "Change cover" for the linked entry.
  changeCover,
}

/// Lets the user link one local game to a RomM ROM by hand.
///
/// Filename linking cannot reach a file renamed locally or one that matches
/// several server entries. This searches the connected server by name, scoped
/// to the RomM platforms that map to the game's system (or every platform when
/// none does), and writes the chosen ROM as a `manual` row that the download
/// path and the automatic passes never replace. Structure follows
/// `RaMatchPickerDialog`: its own gamepad layer, a text field the D-pad can
/// enter and B can leave, and a result list under it.
///
/// Pops `true` when a link was written, `false` when the user backed out.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
class RommMatchPickerDialog extends StatefulWidget {
  final GameModel game;
  final SystemModel system;

  /// A remote ROM to pin at the top of the results and pre-select — the
  /// search screen's entry point already knows which one the user means.
  final RommRom? preselectedRom;

  const RommMatchPickerDialog({
    super.key,
    required this.game,
    required this.system,
    this.preselectedRom,
  });

  static Future<bool?> show(
    BuildContext context,
    GameModel game,
    SystemModel system, {
    RommRom? preselectedRom,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommMatchPickerDialog(
        game: game,
        system: system,
        preselectedRom: preselectedRom,
      ),
    );
  }

  @override
  State<RommMatchPickerDialog> createState() => _RommMatchPickerDialogState();
}

class _RommMatchPickerDialogState extends State<RommMatchPickerDialog> {
  static const String _layerId = 'romm_match_picker_dialog';
  static final double _rowHeight = 48.r;

  late final GamepadNavigation _gamepadNav;
  late final RommMatchPickerController _controller;
  late final RommProvider _rommProvider;
  late final FileProvider _fileProvider;
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isFieldFocused = false;
  bool _isConfirming = false;
  int _selectedIndex = 0;

  // Index 0 is the search field, then the metadata fix-up actions when they
  // are offered, then either the results or the single retry row shown while
  // the last search is in an error state.
  bool get _showRetryRow => _controller.status == RommMatchPickerStatus.error;

  /// The RomM-side fix-up actions offered for this game, in row order.
  ///
  /// They only make sense once the game is linked — they rewrite the entry the
  /// link points at — and only when this connection may write to the library
  /// and the server has a metadata provider to ask.
  ///
  /// A `romsWrite` group in [RommScopeState.unknown] still shows them: that is
  /// every API-key connection, which is what the pair-code and QR logins mint,
  /// and ADR-0013 settled that only [RommScopeState.denied] gates. The service
  /// refuses the write and records the denial if a 403 later proves otherwise,
  /// and the actions disappear from that point on.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
  List<RommFixMode> get _fixActions {
    if (_controller.currentRomId == null) return const [];
    if (!_rommProvider.isConnected) return const [];
    final service = _rommProvider.service;
    if (service.hasScope(RommScopeGroup.romsWrite) == RommScopeState.denied) {
      return const [];
    }
    if (!service.hasMetadataSource) return const [];
    return const [RommFixMode.match, RommFixMode.cover];
  }

  /// Every action row in slot order: "Match by hash" first, when this server
  /// is not known to lack the endpoint, then the fix-up rows.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  List<_PickerAction> get _actions => [
    if (_controller.hashLookupAvailable) _PickerAction.matchByHash,
    for (final mode in _fixActions)
      mode == RommFixMode.cover
          ? _PickerAction.changeCover
          : _PickerAction.fixMatch,
  ];

  /// The row layout as it stands right now — the one place that maps between
  /// a slot and what the slot means. See [RommMatchPickerSlots].
  RommMatchPickerSlots get _slots =>
      RommMatchPickerSlots(actionCount: _actions.length);

  int get _itemCount =>
      _slots.itemCount(_showRetryRow ? 1 : _controller.results.length);

  @override
  void initState() {
    super.initState();

    final rommProvider = context.read<RommProvider>();
    final service = rommProvider.service;
    final fileProvider = context.read<FileProvider>();
    _rommProvider = rommProvider;
    _fileProvider = fileProvider;
    _controller = RommMatchPickerController(
      linkKey: rommLinkKeyFor(
        romPath: widget.game.romPath,
        romname: widget.game.romname,
      ),
      syncKey: widget.game.romname,
      systemFolder: widget.system.folderName,
      systemRealName: widget.system.realName,
      searchRoms:
          ({
            required String search,
            required List<int> platformIds,
            required int limit,
          }) => service.getRomsPage(
            search: search,
            platformIds: platformIds,
            limit: limit,
          ),
      platformIdsFor: rommProvider.platformIdsForSystemName,
      readMapping: () => RommSaveMapRepository.getMapping(
        widget.game.romname,
        widget.system.folderName,
      ),
      writeMapping: RommSaveMapRepository.putManualMapping,
      invalidateSyncState: _invalidateSyncState,
      // Fill-gaps only: a hand-picked link must never replace metadata the
      // user scraped, edited, or imported. Art that landed is picked up by
      // the same debounced settle a download arms.
      // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fill Gaps On Link Confirm"
      fetchMetadata: (_) async {
        final outcome = await rommProvider.fetchMetadata(
          game: widget.game,
          system: widget.system,
          mode: RommMetadataMode.fillGaps,
          fileProvider: fileProvider,
        );
        if (outcome.mediaWritten > 0) {
          rommProvider.scheduleLibraryRefresh(widget.system);
        }
        return outcome;
      },
      preselected: widget.preselectedRom,
      // "Match by hash" is offered unless the heartbeat proved the server
      // predates the endpoint; an unknown version still tries (ADR-0010).
      // The fingerprint is the full one — the whole ROM read off the UI
      // isolate — honouring the system's packed-archive policy so an arcade
      // set hashes as the archive RomM stores.
      // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
      hashLookupAvailable:
          service.supports(RommFeature.romLookupByHash) !=
          RommFeatureSupport.unsupported,
      fingerprintFile: _fingerprintGameFile,
      lookupByHash: (fingerprint) =>
          service.getRomByHash(crc32: fingerprint.crc32, md5: fingerprint.md5),
    )..addListener(_onControllerChanged);

    _queryFocus.addListener(() {
      if (!mounted) return;
      setState(() => _isFieldFocused = _queryFocus.hasFocus);
    });

    _gamepadNav = GamepadNavigation(
      onNavigateUp: _moveUp,
      onNavigateDown: _moveDown,
      onSelectItem: _activateSelection,
      onBack: _handleBack,
      isTextFieldFocused: () => _queryFocus.hasFocus,
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

    // init cleans the query synchronously before its first await, so the
    // field can show the cleaned title straight away rather than after the
    // platform scope resolves.
    final initialized = _controller.init(_initialQuery());
    _queryController.text = _controller.prefilledQuery;
    initialized.then((_) {
      if (!mounted) return;
      final pinned = _controller.preselectedIndex;
      if (pinned >= 0) {
        // [RommMatchPickerSlots], not `pinned + 1`: the fix-up actions sit
        // between the field and the results, so a raw offset here highlights
        // an action row — or the wrong RomM entry, which A then writes.
        // Governing: ADR-0019, SPEC-0018 REQ "Fix Match In The Picker"
        setState(() => _selectedIndex = _slots.slotForResult(pinned));
        _scrollToSelection();
      }
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    _queryController.dispose();
    _queryFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Drops the RomM sync provider's cached status for the game so the cloud
  /// badge re-asks now that the row changed. Reached by id rather than
  /// through [SyncManager.active], as the browse screen does: the cache lives
  /// on the RomM provider whether or not it is the one doing the saves.
  void _invalidateSyncState(String romname) {
    final sync = SyncManager.instance.provider(RomMSyncProvider.kProviderId);
    if (sync is RomMSyncProvider) sync.invalidateGameSyncState(romname);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      _selectedIndex = _selectedIndex.clamp(0, _itemCount - 1);
    });
  }

  /// The full fingerprint of the game's file, for the controller's
  /// [RommMatchPickerController.matchByHash]. A game with no path (a
  /// RomM-only row) is answered as missing without touching the disk.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  Future<({RomFingerprint? fingerprint, String? skipReason})>
  _fingerprintGameFile() async {
    final romPath = widget.game.romPath;
    if (romPath == null || romPath.isEmpty) {
      return (fingerprint: null, skipReason: RomFingerprintService.skipMissing);
    }
    final folder = widget.system.folderName;
    final policy = await RetroAchievementsHashService.policyForSystem(folder);
    return RomFingerprintService.computeInBackground(
      romPath,
      folder,
      keepsArchivesPacked: policy.keepsArchivesPacked,
      effort: FingerprintEffort.full,
    );
  }

  /// The game's extension-stripped filename, or the preselected ROM's name
  /// when the caller already knows which entry it means. The controller
  /// strips the release tags before searching.
  String _initialQuery() {
    final pinned = widget.preselectedRom;
    if (pinned != null && pinned.name.isNotEmpty) return pinned.name;
    return widget.game.romname
        .replaceAll(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '')
        .trim();
  }

  // ── Gamepad ───────────────────────────────────────────────────────────────

  void _moveUp() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex == 0) return;
    setState(() => _selectedIndex--);
    _scrollToSelection();
  }

  void _moveDown() {
    if (_queryFocus.hasFocus) return;
    if (_selectedIndex >= _itemCount - 1) return;
    setState(() => _selectedIndex++);
    _scrollToSelection();
  }

  void _activateSelection() {
    if (_queryFocus.hasFocus) {
      // Enter/A while typing commits the search and returns to list navigation.
      _queryFocus.unfocus();
      _controller.searchNow(_queryController.text);
      return;
    }

    if (_selectedIndex == 0) {
      _queryFocus.requestFocus();
      return;
    }

    final slots = _slots;
    final action = slots.actionForSlot(_selectedIndex);
    if (action != null) {
      _activateAction(_actions[action]);
      return;
    }

    if (_showRetryRow) {
      _retry();
      return;
    }

    final index = slots.resultForSlot(_selectedIndex);
    final rom = index == null
        ? null
        : _controller.results.elementAtOrNull(index);
    if (rom != null) _confirm(rom);
  }

  /// B leaves the text field first, and only closes the dialog once the field
  /// is no longer focused — the app-wide way out of text entry. A busy
  /// "Match by hash" run is cancelled by the same press, before anything
  /// closes, so a slow read of a big ROM can be abandoned without losing the
  /// search results. While a confirm is in flight B is ignored: the link row
  /// is already written and the fill-gaps fetch is running, so popping
  /// `false` here would tell the Manage tab nothing changed when it did.
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fill Gaps On Link Confirm"
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  void _handleBack() {
    if (_isConfirming) return;
    if (_queryFocus.hasFocus) {
      _queryFocus.unfocus();
      return;
    }
    if (_controller.cancelMatchByHash()) return;
    if (mounted) Navigator.of(context).pop(false);
  }

  void _scrollToSelection() {
    if (!_scrollController.hasClients) return;
    // Rows are a fixed height, so the offset can be computed directly rather
    // than measured.
    final target = ((_slots.resultForSlot(_selectedIndex) ?? 0) * _rowHeight)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _activateAction(_PickerAction action) {
    switch (action) {
      case _PickerAction.matchByHash:
        _matchByHash();
      case _PickerAction.fixMatch:
        _openFixDialog(RommFixMode.match);
      case _PickerAction.changeCover:
        _openFixDialog(RommFixMode.cover);
    }
  }

  /// Runs the controller's match-by-hash and, on a hit, moves the highlight
  /// onto the ROM it pinned so A confirms it. A press while a run is busy is
  /// ignored by the controller; the dialog just plays no sound for it.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  Future<void> _matchByHash() async {
    if (_controller.isMatchingByHash || _isConfirming) return;
    SfxService().playNavSound();
    await _controller.matchByHash();
    if (!mounted) return;
    if (_controller.hashStatus != RommMatchByHashStatus.hit) return;
    final pinned = _controller.preselectedIndex;
    if (pinned < 0) return;
    setState(() => _selectedIndex = _slots.slotForResult(pinned));
    _scrollToSelection();
  }

  void _retry() {
    SfxService().playNavSound();
    _controller.searchNow(_queryController.text);
  }

  Future<void> _confirm(RommRom rom) async {
    if (_isConfirming) return;
    SfxService().playNavSound();
    setState(() => _isConfirming = true);
    final linked = await _controller.confirm(rom);
    if (!mounted) return;
    if (linked) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _isConfirming = false);
    AppNotification.showNotification(
      context,
      AppLocale.rommLinkFailed.getString(context),
      type: NotificationType.error,
    );
  }

  /// Opens "Fix match on RomM" or "Change cover" for the linked ROM.
  ///
  /// Everything that reaches the server is built here and handed to
  /// [RommFixMatchController], so the dialog stays a view: the two searches,
  /// the two writes, and the replace-mode metadata fetch that makes the local
  /// row agree with what RomM now holds. The fetch is *replace* rather than
  /// fill-gaps because the user has just told the server this game is
  /// something else — keeping the old local columns would leave the two
  /// disagreeing.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
  // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fetch Modes"
  Future<void> _openFixDialog(RommFixMode mode) async {
    final romId = _controller.currentRomId;
    if (romId == null) return;
    SfxService().playNavSound();

    final service = _rommProvider.service;
    final controller = RommFixMatchController(
      mode: mode,
      romId: romId,
      search: (term) async {
        if (mode == RommFixMode.match) {
          final found = await service.searchRomMetadata(romId, term);
          return found.map(RommFixCandidate.fromMatch).toList();
        }
        final covers = await service.searchCovers(term);
        return covers.map(RommFixCandidate.fromCover).toList();
      },
      applyCandidate: (candidate) async {
        if (mode == RommFixMode.match) {
          final match = candidate.match;
          if (match == null) return false;
          return await service.applyRomMatch(romId, match) != null;
        }
        final url = candidate.coverUrl;
        if (url == null) return false;
        return await service.applyRomCover(romId, url) != null;
      },
      refreshLocal: () async {
        final outcome = await _rommProvider.fetchMetadata(
          game: widget.game,
          system: widget.system,
          mode: RommMetadataMode.replace,
          fileProvider: _fileProvider,
        );
        if (outcome.mediaWritten > 0) {
          _rommProvider.scheduleLibraryRefresh(widget.system);
        }
      },
    );

    final wrote = await RommFixMatchDialog.show(
      context,
      controller: controller,
      gameName: _fixSubjectName(),
      imageHeaders: service.imageHeadersFor,
    );
    if (!mounted) return;

    if (wrote == true) {
      AppNotification.showNotification(
        context,
        (mode == RommFixMode.cover
                ? AppLocale.rommChangeCoverApplied
                : AppLocale.rommFixMatchApplied)
            .getString(context),
      );
      setState(() {});
      return;
    }
    // A cancelled dialog is not a failure; only a write that reached the
    // server and did not take gets an error line.
    if (controller.lastApplyFailed) {
      AppNotification.showNotification(
        context,
        AppLocale.rommFixMatchApplyFailed.getString(context),
        type: NotificationType.error,
      );
    }
  }

  /// The name the fix-up search is prefilled with and the confirmation names:
  /// the cleaned title the picker itself searched by.
  String _fixSubjectName() {
    final cleaned = _controller.prefilledQuery.trim();
    return cleaned.isEmpty ? widget.game.romname : cleaned;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final platformNames = {
      for (final platform in context.read<RommProvider>().platforms)
        platform.id: platform.name,
    };
    final showUnscopedHint =
        !_controller.isScoped &&
        _controller.status != RommMatchPickerStatus.idle;

    return Dialog(
      backgroundColor: theme.cardColor,
      insetPadding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 24.r),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Container(
        width: size.width * 0.6,
        constraints: BoxConstraints(maxHeight: size.height * 0.7),
        padding: EdgeInsets.all(12.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitle(theme),
            if (showUnscopedHint) ...[
              SizedBox(height: 6.r),
              _buildUnscopedHint(theme),
            ],
            SizedBox(height: 10.r),
            _buildSearchField(theme),
            if (_controller.queryWasCleaned) ...[
              SizedBox(height: 4.r),
              _buildCleanedQueryNote(theme),
            ],
            ..._buildActionRows(theme),
            if (_hashResultLine() != null) ...[
              SizedBox(height: 4.r),
              _buildHashResultLine(theme),
            ],
            SizedBox(height: 8.r),
            Flexible(child: _buildResults(theme, platformNames)),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Row(
      children: [
        Icon(
          Symbols.link_rounded,
          color: theme.colorScheme.primary,
          size: 18.r,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            AppLocale.rommLinkPickerTitle.getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 13.r,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          widget.system.realName,
          style: TextStyle(
            fontSize: 10.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildUnscopedHint(ThemeData theme) {
    return Row(
      children: [
        Icon(
          Symbols.info_rounded,
          size: 12.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        SizedBox(width: 6.r),
        Expanded(
          child: Text(
            AppLocale.rommLinkPickerUnscoped.getString(context),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ],
    );
  }

  /// One line under the field while the results answer the cleaned form of
  /// what the user typed, so it is clear which query they are looking at.
  Widget _buildCleanedQueryNote(ThemeData theme) {
    final cleaned = _controller.cleanedQuery ?? '';
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Text(
        AppLocale.rommLinkPickerCleanedQuery
            .getString(context)
            .replaceFirst('{query}', cleaned),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final selected = _selectedIndex == 0;
    final searching = _controller.status == RommMatchPickerStatus.loading;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6.r),
        border: Border.all(
          color: selected || _isFieldFocused
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
          width: selected || _isFieldFocused ? 2.r : 1.r,
        ),
      ),
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Row(
        children: [
          Icon(
            Symbols.search_rounded,
            size: 14.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: TextField(
              controller: _queryController,
              focusNode: _queryFocus,
              onChanged: _controller.onQueryChanged,
              onTap: () => setState(() => _selectedIndex = 0),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10.r),
                hintText: AppLocale.rommLinkPickerSearchHint.getString(context),
                hintStyle: TextStyle(
                  fontSize: 12.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          if (searching || _isConfirming)
            SizedBox(
              width: 12.r,
              height: 12.r,
              child: CircularProgressIndicator(strokeWidth: 1.5.r),
            ),
        ],
      ),
    );
  }

  /// The action rows between the search field and the results — "Match by
  /// hash" and the RomM-side fix-ups — so the D-pad reaches them on the way
  /// down without a separate menu. The hash row shows a spinner and its busy
  /// label while a run is in flight.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  List<Widget> _buildActionRows(ThemeData theme) {
    final actions = _actions;
    if (actions.isEmpty) return const [];
    final slots = _slots;
    final busy = _controller.isMatchingByHash;
    return [
      for (var i = 0; i < actions.length; i++) ...[
        SizedBox(height: 6.r),
        _RommFixActionRow(
          label: _actionLabel(actions[i], busy: busy),
          icon: _actionIcon(actions[i]),
          busy: busy && actions[i] == _PickerAction.matchByHash,
          selected: _selectedIndex == slots.slotForAction(i),
          onTap: () {
            setState(() => _selectedIndex = slots.slotForAction(i));
            _activateAction(actions[i]);
          },
        ),
      ],
    ];
  }

  String _actionLabel(_PickerAction action, {required bool busy}) {
    final key = switch (action) {
      _PickerAction.matchByHash =>
        busy ? AppLocale.rommMatchByHashBusy : AppLocale.rommMatchByHash,
      _PickerAction.fixMatch => AppLocale.rommFixMatchAction,
      _PickerAction.changeCover => AppLocale.rommChangeCoverAction,
    };
    return key.getString(context);
  }

  IconData _actionIcon(_PickerAction action) => switch (action) {
    _PickerAction.matchByHash => Symbols.fingerprint_rounded,
    _PickerAction.fixMatch => Symbols.manage_search_rounded,
    _PickerAction.changeCover => Symbols.image_rounded,
  };

  /// What the last "Match by hash" run has to say, or null when there is
  /// nothing to show (idle, busy, or a hit — the highlighted row is the
  /// answer). A skip names its reason in the user's language; a token the
  /// fingerprint service adds later is shown as-is rather than hidden.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash In The Picker"
  String? _hashResultLine() {
    switch (_controller.hashStatus) {
      case RommMatchByHashStatus.idle:
      case RommMatchByHashStatus.busy:
      case RommMatchByHashStatus.hit:
        return null;
      case RommMatchByHashStatus.miss:
        return AppLocale.rommMatchByHashNoMatch.getString(context);
      case RommMatchByHashStatus.skipped:
        final token = _controller.hashSkipReason ?? '';
        final key = switch (token) {
          RomFingerprintService.skipDisc => AppLocale.rommMatchByHashReasonDisc,
          RomFingerprintService.skipOversize =>
            AppLocale.rommMatchByHashReasonOversize,
          RomFingerprintService.skipMissing =>
            AppLocale.rommMatchByHashReasonMissing,
          RomFingerprintService.skipExtractFailed =>
            AppLocale.rommMatchByHashReasonExtractFailed,
          RomFingerprintService.skipError =>
            AppLocale.rommMatchByHashReasonError,
          _ => null,
        };
        final reason = key == null ? token : key.getString(context);
        return AppLocale.rommMatchByHashSkipped
            .getString(context)
            .replaceFirst('{reason}', reason);
      case RommMatchByHashStatus.error:
        return AppLocale.rommMatchByHashFailed.getString(context);
    }
  }

  Widget _buildHashResultLine(ThemeData theme) {
    final failed = _controller.hashStatus == RommMatchByHashStatus.error;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.r),
      child: Row(
        children: [
          Icon(
            failed ? Symbols.error_rounded : Symbols.info_rounded,
            size: 12.r,
            color: failed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          SizedBox(width: 6.r),
          Expanded(
            child: Text(
              _hashResultLine() ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme, Map<int, String> platformNames) {
    final status = _controller.status;
    final results = _controller.results;
    final slots = _slots;

    if (status == RommMatchPickerStatus.error) {
      return _RommRetryRow(
        selected: _selectedIndex == slots.slotForResult(0),
        onTap: _retry,
      );
    }

    if (results.isEmpty) {
      final message = status == RommMatchPickerStatus.ready
          ? AppLocale.rommLinkPickerNoResults.getString(context)
          : AppLocale.rommLinkPickerLoading.getString(context);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20.r),
        child: Center(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: results.length,
      itemBuilder: (context, i) {
        final rom = results[i];
        return _RommMatchRow(
          rom: rom,
          platformName: platformNames[rom.platformId] ?? rom.platformSlug,
          selected: _selectedIndex == slots.slotForResult(i),
          isCurrent: rom.id == _controller.currentRomId,
          onTap: () {
            setState(() => _selectedIndex = slots.slotForResult(i));
            _confirm(rom);
          },
        );
      },
    );
  }
}

/// A single remote ROM: name on the first line, platform and on-server
/// filename on the second so same-named entries can be told apart.
class _RommMatchRow extends StatelessWidget {
  final RommRom rom;
  final String platformName;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;

  const _RommMatchRow({
    required this.rom,
    required this.platformName,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = platformName.isEmpty
        ? rom.fsName
        : '$platformName · ${rom.fsName}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommMatchPickerDialogState._rowHeight,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            if (isCurrent) ...[
              Icon(
                Symbols.check_circle_rounded,
                size: 14.r,
                color: theme.colorScheme.primary,
              ),
              SizedBox(width: 6.r),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rom.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.r,
                      color: theme.colorScheme.onSurface,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  SizedBox(height: 2.r),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.r,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
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

/// The one row shown when the last search failed: selecting it runs the same
/// query again, so the dialog stays usable without retyping.
class _RommRetryRow extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _RommRetryRow({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommMatchPickerDialogState._rowHeight,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Symbols.error_rounded,
              size: 14.r,
              color: theme.colorScheme.error,
            ),
            SizedBox(width: 6.r),
            Expanded(
              child: Text(
                AppLocale.rommLinkPickerError.getString(context),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            SizedBox(width: 6.r),
            Icon(
              Symbols.refresh_rounded,
              size: 14.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// One action row under the search field. [busy] swaps the icon for a
/// spinner while the row's work is in flight.
class _RommFixActionRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  const _RommFixActionRow({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: 34.r,
        padding: EdgeInsets.symmetric(horizontal: 8.r),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Row(
          children: [
            if (busy)
              SizedBox(
                width: 14.r,
                height: 14.r,
                child: CircularProgressIndicator(strokeWidth: 1.5.r),
              )
            else
              Icon(icon, size: 14.r, color: theme.colorScheme.primary),
            SizedBox(width: 6.r),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.r,
                  color: theme.colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
