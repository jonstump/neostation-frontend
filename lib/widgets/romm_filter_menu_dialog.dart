import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_locale.dart';
import '../models/romm_rom_filters.dart';
import '../services/game_service.dart' show GamepadNavigationManager;
import '../services/sfx_service.dart';
import '../utils/gamepad_nav.dart';

/// Checklist of RomM's server-side ROM filters for the open platform or
/// collection.
///
/// One row per [RommRomFilter], each a tick box, then a "Clear all" row that
/// unticks the lot: Up/Down walks them, A toggles (or clears), B closes. The
/// result is the whole [RommRomFilters] set as the user left it, or null when
/// nothing changed — closing without a change must not re-page the grid.
///
/// "Clear all" is appended rather than prepended so the filter rows keep the
/// indices the D-pad already walked, and it is the controller-reachable twin of
/// the chip row's tap-only "Clear filters" chip — CLAUDE.md requires every
/// interactive element to be reachable by D-pad, not only by touch.
///
/// Gamepad wiring follows [ConfirmActionDialog]: the layer is pushed in the
/// same post-frame callback as `initialize()`, activation is left to the
/// [GamepadNavigationManager], and the layer is popped in `dispose()`. Every
/// row is also a tap target, so touch reaches what the D-pad reaches.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Filter Menu And Chips"
class RommFilterMenuDialog extends StatefulWidget {
  /// The filters currently applied to the open source.
  final RommRomFilters filters;

  const RommFilterMenuDialog({super.key, required this.filters});

  /// Opens the menu. Returns the chosen filters, or null on cancel / no change.
  static Future<RommRomFilters?> show(
    BuildContext context, {
    required RommRomFilters filters,
  }) {
    return showDialog<RommRomFilters>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RommFilterMenuDialog(filters: filters),
    );
  }

  /// The `AppLocale` key naming [filter], shared with the chip row so a chip
  /// and its menu row always read the same.
  // Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips", REQ "Localized User-Facing Text"
  static String labelKeyFor(RommRomFilter filter) {
    switch (filter) {
      case RommRomFilter.favorite:
        return AppLocale.rommFilterFavorites;
      case RommRomFilter.hasSaves:
        return AppLocale.rommFilterHasSaves;
      case RommRomFilter.hasStates:
        return AppLocale.rommFilterHasStates;
      case RommRomFilter.hasRa:
        return AppLocale.rommFilterHasAchievements;
      case RommRomFilter.playable:
        return AppLocale.rommFilterPlayable;
      case RommRomFilter.duplicate:
        return AppLocale.rommFilterDuplicates;
      case RommRomFilter.missing:
        return AppLocale.rommFilterMissing;
    }
  }

  /// The icon for [filter]'s row and chip.
  static IconData iconFor(RommRomFilter filter) {
    switch (filter) {
      case RommRomFilter.favorite:
        return Symbols.favorite_rounded;
      case RommRomFilter.hasSaves:
        return Symbols.save_rounded;
      case RommRomFilter.hasStates:
        return Symbols.bookmark_rounded;
      case RommRomFilter.hasRa:
        return Symbols.trophy_rounded;
      case RommRomFilter.playable:
        return Symbols.sports_esports_rounded;
      case RommRomFilter.duplicate:
        return Symbols.content_copy_rounded;
      case RommRomFilter.missing:
        return Symbols.link_off_rounded;
    }
  }

  @override
  State<RommFilterMenuDialog> createState() => _RommFilterMenuDialogState();
}

class _RommFilterMenuDialogState extends State<RommFilterMenuDialog> {
  static const _layerName = 'romm_filter_menu_dialog';
  static const _filters = RommRomFilter.values;

  /// The "Clear all" row sits one past the last filter.
  static int get _clearRow => _filters.length;
  static int get _rowCount => _filters.length + 1;

  late final GamepadNavigation _gamepadNav;
  late RommRomFilters _current;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _current = widget.filters;
    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _move(-1),
      onNavigateDown: () => _move(1),
      onSelectItem: _confirmRow,
      onBack: _close,
      // A fixed short list: one move per press, as the other dialogs do.
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
      _selected = (_selected + delta + _rowCount) % _rowCount;
    });
  }

  /// A on the focused row: a filter row ticks, the last row clears the lot.
  void _confirmRow() {
    if (_selected == _clearRow) {
      _clearAll();
      return;
    }
    _toggle(_filters[_selected]);
  }

  /// Unticks every filter — the same outcome as the chip row's "Clear filters".
  // Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips"
  void _clearAll() {
    SfxService().playNavSound();
    setState(() {
      _selected = _clearRow;
      _current = RommRomFilters.none;
    });
  }

  void _toggle(RommRomFilter filter) {
    SfxService().playNavSound();
    setState(() {
      _selected = _filters.indexOf(filter);
      _current = _current.toggled(filter);
    });
  }

  /// B / Close. Hands back the new set only when it actually differs, so a
  /// look-and-leave costs no request.
  void _close() {
    if (!mounted) return;
    SfxService().playBackSound();
    Navigator.of(context).pop(_current == widget.filters ? null : _current);
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
          Icon(Symbols.filter_alt_rounded, color: accent, size: 20.r),
          SizedBox(width: 8.r),
          Flexible(
            child: Text(
              AppLocale.rommFilterMenuTitle.getString(context),
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _filters.length; i++) ...[
                if (i > 0) SizedBox(height: 4.r),
                _buildRow(theme, _filters[i], i),
              ],
              SizedBox(height: 4.r),
              _buildClearRow(theme),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _close,
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
                AppLocale.close.getString(context),
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

  /// The "Clear all" row. Dimmed when nothing is ticked, but still walkable so
  /// the row count the D-pad sees never changes shape underneath it.
  Widget _buildClearRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final focused = _selected == _clearRow;
    final enabled = _current.active.isNotEmpty;
    final tint = scheme.onSurface.withValues(alpha: enabled ? 0.8 : 0.4);
    return InkWell(
      onTap: _clearAll,
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
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
            Icon(Symbols.close_rounded, size: 18.r, color: tint),
            SizedBox(width: 8.r),
            Expanded(
              child: Text(
                AppLocale.rommFilterClearAll.getString(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.r, color: tint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, RommRomFilter filter, int index) {
    final scheme = theme.colorScheme;
    final focused = _selected == index;
    final on = _current[filter] == true;
    return InkWell(
      onTap: () => _toggle(filter),
      borderRadius: BorderRadius.circular(8.r),
      child: Semantics(
        toggled: on,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
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
                on
                    ? Symbols.check_box_rounded
                    : Symbols.check_box_outline_blank_rounded,
                fill: on ? 1 : 0,
                size: 18.r,
                color: on
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.6),
              ),
              SizedBox(width: 8.r),
              Icon(
                RommFilterMenuDialog.iconFor(filter),
                size: 16.r,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
              SizedBox(width: 8.r),
              Expanded(
                child: Text(
                  RommFilterMenuDialog.labelKeyFor(filter).getString(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    color: scheme.onSurface.withValues(alpha: on ? 1 : 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
