import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_controller.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/cover_decode.dart';
import 'package:neostation/utils/gamepad_nav.dart';

/// "Fix match on RomM" and "Change cover": search the *server's* metadata
/// providers and write the chosen candidate back onto the RomM entry.
///
/// Structure follows `RommMatchPickerDialog`, which this is opened from: its
/// own gamepad layer pushed in the same post-frame callback as the navigator
/// and popped in `dispose`, a text field the D-pad can enter and B can leave,
/// and a result list under it. The two flows differ only in what a row means,
/// so one dialog drives both through [RommFixMatchController.mode].
///
/// Pops `true` when something was written to the server, `false` otherwise.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
class RommFixMatchDialog extends StatefulWidget {
  /// Built by the caller, which owns the RomM provider; disposed here.
  final RommFixMatchController controller;

  /// The local game's name: prefills the search and names what is about to
  /// change in the confirmation.
  final String gameName;

  /// Auth headers for a cover URL served by the RomM instance itself; cover
  /// art from SteamGridDB is public and needs none.
  final Map<String, String> Function(String url) imageHeaders;

  const RommFixMatchDialog({
    super.key,
    required this.controller,
    required this.gameName,
    required this.imageHeaders,
  });

  static Future<bool?> show(
    BuildContext context, {
    required RommFixMatchController controller,
    required String gameName,
    required Map<String, String> Function(String url) imageHeaders,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommFixMatchDialog(
        controller: controller,
        gameName: gameName,
        imageHeaders: imageHeaders,
      ),
    );
  }

  @override
  State<RommFixMatchDialog> createState() => _RommFixMatchDialogState();
}

class _RommFixMatchDialogState extends State<RommFixMatchDialog> {
  static const String _layerId = 'romm_fix_match_dialog';
  static final double _rowHeight = 56.r;

  late final GamepadNavigation _gamepadNav;
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isFieldFocused = false;
  bool _wroteSomething = false;
  int _selectedIndex = 0;

  RommFixMatchController get _controller => widget.controller;

  // Index 0 is the search field; the rows after it are either the candidates
  // or the single retry row shown while the last search is in an error state.
  bool get _showRetryRow => _controller.status == RommFixStatus.error;
  int get _itemCount => 1 + (_showRetryRow ? 1 : _controller.results.length);

  @override
  void initState() {
    super.initState();

    _controller.addListener(_onControllerChanged);

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

    _queryController.text = widget.gameName;
    _controller.searchNow(widget.gameName);
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

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      _selectedIndex = _selectedIndex.clamp(0, _itemCount - 1);
    });
  }

  bool get _isCover => _controller.mode == RommFixMode.cover;

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
    if (_controller.isApplying) return;

    if (_queryFocus.hasFocus) {
      _queryFocus.unfocus();
      _controller.searchNow(_queryController.text);
      return;
    }

    if (_selectedIndex == 0) {
      _queryFocus.requestFocus();
      return;
    }

    if (_showRetryRow) {
      SfxService().playNavSound();
      _controller.searchNow(_queryController.text);
      return;
    }

    final candidate = _controller.results.elementAtOrNull(_selectedIndex - 1);
    if (candidate != null) _confirmAndApply(candidate);
  }

  /// B leaves the text field first, then closes. A write in flight ignores B:
  /// the `PUT` is already on its way to the server and the replace-mode fetch
  /// behind it is what makes the local row agree with it.
  void _handleBack() {
    if (_controller.isApplying) return;
    if (_queryFocus.hasFocus) {
      _queryFocus.unfocus();
      return;
    }
    if (mounted) Navigator.of(context).pop(_wroteSomething);
  }

  void _scrollToSelection() {
    if (!_scrollController.hasClients) return;
    final target = ((_selectedIndex - 1) * _rowHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Names what is about to change on the server, waits for a deliberate
  /// confirmation, and only then writes.
  ///
  /// `PUT /api/roms/{id}` rewrites the entry for *every* client of the server
  /// and the replace-mode fetch behind it overwrites the local row, so the
  /// confirmation is load-bearing rather than decorative: it defaults to
  /// Cancel (see [_RommFixConfirmDialog]) so a stray or repeated A press backs
  /// out instead of writing, and [RommFixMatchController.apply] refuses a
  /// second write while one is in flight.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
  Future<void> _confirmAndApply(RommFixCandidate candidate) async {
    if (_controller.isApplying) return;
    SfxService().playNavSound();

    final subject = _isCover ? widget.gameName : candidate.name;
    final confirmed = await _RommFixConfirmDialog.show(
      context,
      title:
          (_isCover
                  ? AppLocale.rommChangeCoverConfirmTitle
                  : AppLocale.rommFixMatchConfirmTitle)
              .getString(context),
      body:
          (_isCover
                  ? AppLocale.rommChangeCoverConfirmBody
                  : AppLocale.rommFixMatchConfirmBody)
              .getString(context)
              .replaceFirst('{name}', subject),
      applyLabel: AppLocale.rommFixMatchApply.getString(context),
    );
    if (!mounted || !confirmed) return;

    final applied = await _controller.apply(candidate);
    if (!mounted) return;
    if (!applied) {
      setState(() {});
      return;
    }
    _wroteSomething = true;
    Navigator.of(context).pop(true);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

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
            SizedBox(height: 10.r),
            _buildSearchField(theme),
            SizedBox(height: 8.r),
            Flexible(child: _buildResults(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(ThemeData theme) {
    return Row(
      children: [
        Icon(
          _isCover ? Symbols.image_rounded : Symbols.manage_search_rounded,
          color: theme.colorScheme.primary,
          size: 18.r,
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            (_isCover
                    ? AppLocale.rommChangeCoverTitle
                    : AppLocale.rommFixMatchTitle)
                .getString(context),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 13.r,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          widget.gameName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    final selected = _selectedIndex == 0;
    final busy =
        _controller.status == RommFixStatus.loading || _controller.isApplying;
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
              onSubmitted: _controller.searchNow,
              onTap: () => setState(() => _selectedIndex = 0),
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10.r),
                hintText: AppLocale.rommFixMatchSearchHint.getString(context),
                hintStyle: TextStyle(
                  fontSize: 12.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
          if (busy)
            SizedBox(
              width: 12.r,
              height: 12.r,
              child: CircularProgressIndicator(strokeWidth: 1.5.r),
            ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_controller.status == RommFixStatus.error) {
      // A server with no provider configured is a different sentence from a
      // failed request: nothing the user does here will fix it.
      // Governing: ADR-0019, SPEC-0018 REQ "Error Handling Standards"
      final noSource =
          _controller.lastErrorKind == RommErrorKind.noMetadataSource;
      return _RommFixMessageRow(
        selected: _selectedIndex == 1,
        message:
            (noSource
                    ? AppLocale.rommFixMatchNoSource
                    : AppLocale.rommFixMatchFailed)
                .getString(context),
        retryable: !noSource,
        onTap: () {
          SfxService().playNavSound();
          _controller.searchNow(_queryController.text);
        },
      );
    }

    if (_controller.results.isEmpty) {
      final message = _controller.status == RommFixStatus.ready
          ? AppLocale.rommFixMatchNoResults.getString(context)
          : AppLocale.rommFixMatchLoading.getString(context);
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
      itemCount: _controller.results.length,
      itemBuilder: (context, i) {
        final candidate = _controller.results[i];
        return _RommFixRow(
          candidate: candidate,
          selected: _selectedIndex == i + 1,
          imageHeaders: widget.imageHeaders,
          onTap: () {
            setState(() => _selectedIndex = i + 1);
            _confirmAndApply(candidate);
          },
        );
      },
    );
  }
}

/// One candidate: its art on the left, name and provider ids beside it.
class _RommFixRow extends StatelessWidget {
  final RommFixCandidate candidate;
  final bool selected;
  final Map<String, String> Function(String url) imageHeaders;
  final VoidCallback onTap;

  const _RommFixRow({
    required this.candidate,
    required this.selected,
    required this.imageHeaders,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artWidth = 34.r;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommFixMatchDialogState._rowHeight,
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
            SizedBox(
              width: artWidth,
              height: 44.r,
              child: _buildArt(context, theme, artWidth),
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.name,
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
                  if (candidate.detail != null) ...[
                    SizedBox(height: 2.r),
                    Text(
                      candidate.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.r,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The candidate's art, decoded no wider than the row paints it. Same
  /// `cacheWidth` treatment as the browse tiles: bounds decode memory and
  /// keys the shared `ImageCache` by size.
  // Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Decode At Tile Size"
  Widget _buildArt(BuildContext context, ThemeData theme, double logicalWidth) {
    final url = candidate.previewUrl;
    final placeholder = Container(
      color: theme.colorScheme.surface,
      child: Center(
        child: Icon(
          Symbols.image_rounded,
          size: 14.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    );
    if (url == null || url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4.r),
      child: Stack(
        fit: StackFit.expand,
        children: [
          placeholder,
          Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: coverDecodeWidth(
              logicalWidth: logicalWidth,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
            gaplessPlayback: true,
            headers: imageHeaders(url),
            errorBuilder: (_, _, _) => placeholder,
          ),
        ],
      ),
    );
  }
}

/// The single row shown when a search failed: selecting it runs the query
/// again, unless the failure is one no retry can fix.
class _RommFixMessageRow extends StatelessWidget {
  final bool selected;
  final String message;
  final bool retryable;
  final VoidCallback onTap;

  const _RommFixMessageRow({
    required this.selected,
    required this.message,
    required this.retryable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: retryable ? onTap : null,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        height: _RommFixMatchDialogState._rowHeight,
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
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
            if (retryable) ...[
              SizedBox(width: 6.r),
              Icon(
                Symbols.refresh_rounded,
                size: 14.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The confirmation in front of a write to the user's own RomM server.
///
/// Deliberately *not* [ConfirmActionDialog]: that one maps A straight to
/// "confirm", which is fine for a local delete the user can redo but not for a
/// `PUT` that rewrites a library entry for every client of the server. Here the
/// selection starts on Cancel, so the A press that opened this dialog — or a
/// repeated one, which Android's keycode-backed pads make cheap to produce —
/// cancels rather than writes. The user has to move to Apply first.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Fix Match In The Picker"
class _RommFixConfirmDialog extends StatefulWidget {
  final String title;
  final String body;
  final String applyLabel;

  const _RommFixConfirmDialog({
    required this.title,
    required this.body,
    required this.applyLabel,
  });

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String body,
    required String applyLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RommFixConfirmDialog(
        title: title,
        body: body,
        applyLabel: applyLabel,
      ),
    );
    return result ?? false;
  }

  @override
  State<_RommFixConfirmDialog> createState() => _RommFixConfirmDialogState();
}

class _RommFixConfirmDialogState extends State<_RommFixConfirmDialog> {
  static const String _layerId = 'romm_fix_match_confirm_dialog';

  late final GamepadNavigation _gamepadNav;

  /// 0 = Cancel, 1 = Apply. Cancel is the default on purpose.
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () => _move(-1),
      onNavigateRight: () => _move(1),
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _activate,
      onBack: () {
        if (mounted) Navigator.of(context).pop(false);
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
    final next = (_selectedIndex + delta).clamp(0, 1);
    if (next == _selectedIndex) return;
    SfxService().playNavSound();
    setState(() => _selectedIndex = next);
  }

  void _activate() {
    if (!mounted) return;
    Navigator.of(context).pop(_selectedIndex == 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.error;

    return AlertDialog(
      backgroundColor: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.r),
        side: BorderSide(color: accent.withValues(alpha: 0.3)),
      ),
      title: Row(
        children: [
          Icon(Symbols.cloud_upload_rounded, color: accent, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              widget.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 14.r,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: Text(
        widget.body,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 11.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
      actions: [
        _buildAction(
          theme,
          label: AppLocale.cancel.getString(context),
          selected: _selectedIndex == 0,
          accent: theme.colorScheme.onSurface,
          onTap: () => Navigator.of(context).pop(false),
        ),
        _buildAction(
          theme,
          label: widget.applyLabel,
          selected: _selectedIndex == 1,
          accent: accent,
          onTap: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  Widget _buildAction(
    ThemeData theme, {
    required String label,
    required bool selected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 8.r),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected ? accent : Colors.transparent,
            width: 2.r,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? accent
                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
            fontSize: 12.r,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
