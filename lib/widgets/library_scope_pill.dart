import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/library_scope.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/chrome_surface.dart';
import 'package:neostation/themes/corner_radii.dart';

/// The active library scope, as a footer pill: the Select + X chord that
/// toggles it, the scope's name, and — while the server is unreachable and the
/// scope is `all` — an offline mark, because what is listed then is the cached
/// catalog and none of it can be downloaded.
///
/// Tappable for touch, since the chord needs a pad; the host owns the scope and
/// the rebuild, this only reports the press. Shared by the details-card footer
/// (list view) and the grid/carousel footer so the three views show the scope
/// the same way.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope"
class LibraryScopePill extends StatelessWidget {
  final LibraryScope scope;
  final VoidCallback onToggle;

  /// True while reachability is `offline`: the pill wears a cloud-off mark and
  /// its tooltip carries the "showing the cached library" line.
  final bool offline;

  /// Row height to match the pills beside it: the two footers size theirs
  /// differently.
  final double height;

  /// The widest this pill may draw, already scaled, or null for whatever its
  /// label needs.
  ///
  /// Bounded, the label ellipsizes and the pill stops at the ceiling instead
  /// of pushing the controls beside it off the row — the details-card footer
  /// hands it what its row has left over (issue #238). Unbounded, the pill is
  /// a plain non-flexible child of a Row and is laid out with no main-axis
  /// ceiling at all, and a flexible child under an unbounded constraint is a
  /// layout error: that is why the label is only made flexible when there is
  /// a ceiling for it to flex against.
  final double? maxWidth;

  const LibraryScopePill({
    super.key,
    required this.scope,
    required this.onToggle,
    this.offline = false,
    this.height = 32,
    this.maxWidth,
  });

  /// The scope's localized name, for the footer and the switch notice.
  static String labelFor(BuildContext context, LibraryScope scope) =>
      switch (scope) {
        LibraryScope.all => AppLocale.libraryScopeAll.getString(context),
        LibraryScope.downloaded => AppLocale.libraryScopeDownloaded.getString(
          context,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radii = theme.extension<CornerRadii>() ?? CornerRadii.m();
    final label = labelFor(context, scope);
    final footerText = AppLocale.libraryScopeFooter
        .getString(context)
        .replaceFirst('{scope}', label);
    final showOffline = offline && scope == LibraryScope.all;
    final tooltip = showOffline
        ? AppLocale.libraryOfflineCached.getString(context)
        : AppLocale.libraryScopeToggle.getString(context);

    return Semantics(
      button: true,
      label: footerText,
      hint: tooltip,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                SfxService().playNavSound();
                onToggle();
              },
              canRequestFocus: false,
              borderRadius: radii.radiusExternal,
              child: Container(
                height: height.r,
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: ChromeSurface.fill(context),
                  borderRadius: radii.radiusExternal,
                  border: Border.all(color: scheme.outline, width: 1.r),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.1),
                      blurRadius: 4.r,
                      offset: Offset(2.0.r, 2.0.r),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // The chord, as the same button art the other hints use.
                    Image.asset(
                      'assets/images/gamepad/Xbox_View_button.png',
                      width: 15.r,
                      height: 15.r,
                      color: scheme.onSurface,
                    ),
                    SizedBox(width: 2.r),
                    Image.asset(
                      'assets/images/gamepad/Xbox_X_button.png',
                      width: 15.r,
                      height: 15.r,
                      // Tinted like the View glyph above it and every other
                      // gamepad glyph in lib/ — the two shared renderers
                      // (`glass_button.dart`, `core_footer.dart`) both do this.
                      // Untinted, the asset drew in its own colour and was
                      // invisible against a dark surface. Issue #234.
                      color: scheme.onSurface,
                    ),
                    SizedBox(width: 4.r),
                    Icon(
                      showOffline
                          ? Symbols.cloud_off_rounded
                          : scope == LibraryScope.all
                          ? Symbols.cloud_rounded
                          : Symbols.download_done_rounded,
                      size: 15.r,
                      color: scheme.onSurface,
                    ),
                    SizedBox(width: 4.r),
                    // Flexible only when there is a ceiling to flex against:
                    // under [maxWidth] the label is what gives, and without one
                    // this Row has no main-axis bound at all, where a flexible
                    // child is a layout error rather than a shrinking one.
                    if (maxWidth == null)
                      _label(label, scheme)
                    else
                      Flexible(child: _label(label, scheme)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The scope's name. Ellipsized rather than wrapped or scaled: the pill is
  /// one line high and the name is the only part of it that can lose width.
  Widget _label(String label, ColorScheme scheme) => Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: scheme.onSurface,
      fontSize: 11.r,
      fontWeight: FontWeight.w600,
    ),
  );
}
