import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_locale.dart';
import '../../../models/library_scope.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../widgets/custom_toggle_switch.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'settings_title.dart';
import 'widgets/setting_row.dart';
import 'widgets/setting_value_chip.dart';

/// The RomM section of settings.
///
/// These three rows lived in General, where they were the tail of a section
/// about everything else and were easy to miss in a fork whose library is
/// RomM-first. Nothing about them changed in the move: the same config keys,
/// the same handlers, the same cycles.
///
/// The contract with `NewSettingsScreen` is the one every content panel here
/// keeps — [getItemCount] must equal the number of rows [build] draws, because
/// that is what bounds D-pad traversal. General drifted three rows out of step
/// with its own count once (issue #239) and nothing failed loudly; the rows
/// still drew, they just stopped being reachable. A test pins the equality for
/// this panel from the start.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Settings And Actions"
class RommSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const RommSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<RommSettingsContent> createState() => RommSettingsContentState();
}

class RommSettingsContentState extends State<RommSettingsContent> {
  final ScrollController _scrollController = ScrollController();

  /// Snaps during rapid D-pad navigation, animates on a single move.
  final AdaptiveScroller _scroller = AdaptiveScroller();

  final List<GlobalKey> _itemKeys = List.generate(
    _itemCount,
    (_) => GlobalKey(),
  );

  /// The caps the cover cache row cycles through, in megabytes. 200 is the
  /// column default; the row steps to the next entry and wraps.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Settings And Actions"
  static const List<int> _coverCacheMbCycle = [100, 200, 500, 1000];

  /// Show the library, default scope, cover cache size. All three are
  /// unconditional — no platform or feature gate — so this is a constant
  /// rather than a computed count.
  static const int _itemCount = 3;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// The number of navigable rows. Must equal what [build] draws.
  int getItemCount() => _itemCount;

  /// Synchronizes the scroll viewport with the currently focused row.
  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  void _cycleLibraryDefaultScope(SqliteConfigProvider provider) {
    final current = LibraryScope.fromConfig(
      provider.config.rommLibraryDefaultScope,
    );
    provider.updateRommLibraryDefaultScope(current.toggled.configValue);
  }

  void _cycleCoverCacheMb(SqliteConfigProvider provider) {
    final index = _coverCacheMbCycle.indexOf(provider.config.rommCoverCacheMb);
    final next = index == -1
        ? _coverCacheMbCycle.first
        : _coverCacheMbCycle[(index + 1) % _coverCacheMbCycle.length];
    provider.updateRommCoverCacheMb(next);
  }

  /// Runs the action for [index]. Same order as the rows in [build].
  void selectItem(int index) {
    final provider = context.read<SqliteConfigProvider>();
    switch (index) {
      case 0:
        provider.updateRommShowLibrary(!provider.config.rommShowLibrary);
      case 1:
        _cycleLibraryDefaultScope(provider);
      case 2:
        _cycleCoverCacheMb(provider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(title: AppLocale.rommSettings.getString(context)),
        SizedBox(height: 12.r),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.only(bottom: 24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Setting: show the RomM library inside the local systems.
                SettingRow(
                  key: _itemKeys[0],
                  onTap: () => selectItem(0),
                  focused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == 0,
                  title: AppLocale.rommShowLibrary.getString(context),
                  subtitle: AppLocale.rommShowLibrarySubtitle.getString(
                    context,
                  ),
                  trailing: CustomToggleSwitch(
                    value: config.rommShowLibrary,
                    onChanged: (value) => context
                        .read<SqliteConfigProvider>()
                        .updateRommShowLibrary(value),
                    activeColor: theme.colorScheme.primary,
                  ),
                ),

                // Setting: the scope a game list opens in.
                // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope"
                SizedBox(height: 12.r),
                SettingRow(
                  key: _itemKeys[1],
                  onTap: () => selectItem(1),
                  focused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == 1,
                  title: AppLocale.rommLibraryDefaultScope.getString(context),
                  subtitle: AppLocale.rommLibraryDefaultScopeSubtitle.getString(
                    context,
                  ),
                  trailing: SettingValueChip(
                    text:
                        LibraryScope.fromConfig(
                              config.rommLibraryDefaultScope,
                            ) ==
                            LibraryScope.all
                        ? AppLocale.libraryScopeAll.getString(context)
                        : AppLocale.libraryScopeDownloaded.getString(context),
                  ),
                ),

                // Setting: the cover cache cap.
                // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
                SizedBox(height: 12.r),
                SettingRow(
                  key: _itemKeys[2],
                  onTap: () => selectItem(2),
                  focused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == 2,
                  title: AppLocale.rommCoverCacheSize.getString(context),
                  subtitle: AppLocale.rommCoverCacheSizeSubtitle.getString(
                    context,
                  ),
                  trailing: SettingValueChip(
                    text: AppLocale.rommCoverCacheSizeValue
                        .getString(context)
                        .replaceFirst(
                          '{size}',
                          config.rommCoverCacheMb.toString(),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
