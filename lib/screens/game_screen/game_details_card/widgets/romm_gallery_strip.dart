import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../../l10n/app_locale.dart';
import '../../../../models/romm_screenshot.dart';
import '../../../../utils/cover_decode.dart';
import 'panel_gate_highlight.dart';

/// The "RomM gallery" strip under the details card's media panel.
///
/// Purely presentational: it is handed the screenshots, the load state and the
/// cursor, and reports a confirm back. Everything that needs a server — the
/// link lookup, the version gate, the request — belongs to the panel that owns
/// it, so this widget can be laid out in a test with no provider tree at all.
///
/// Thumbnails go through Flutter's `ImageCache` with a `cacheWidth`, exactly
/// as the RomM browser's tiles do (`RommRomCard`): the hint wraps the provider
/// in a `ResizeImage`, which bounds decode memory and keys the cache by size,
/// so a strip of eight captures costs eight small bitmaps rather than eight
/// full-resolution ones.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
class RommGalleryStrip extends StatefulWidget {
  /// The gallery, already ordered newest first by the panel.
  final List<RommScreenshot> shots;

  /// A request is in flight and nothing has been shown yet.
  final bool loading;

  /// The request failed. Distinct from an empty [shots]: one says "we could
  /// not ask", the other says "there is nothing there".
  final bool hasError;

  /// Cursor position within [shots]; ignored when the strip is not active.
  final int selectedIndex;

  /// Whether the strip currently holds the D-pad.
  final bool isPanelActive;

  /// Absolute URL for a screenshot's bytes, or null when the server gave no
  /// usable path (that entry then draws its placeholder).
  final String? Function(RommScreenshot shot) urlOf;

  /// Auth headers for [url], which are the bearer token only while the URL
  /// points at the connected RomM server.
  final Map<String, String> Function(String url) headersOf;

  /// Confirm on the thumbnail at this index (A, or a tap).
  final void Function(int index) onActivate;

  const RommGalleryStrip({
    super.key,
    required this.shots,
    required this.loading,
    required this.hasError,
    required this.selectedIndex,
    required this.isPanelActive,
    required this.urlOf,
    required this.headersOf,
    required this.onActivate,
  });

  /// Height the panel reserves for the whole strip, title included. A constant
  /// so the media above it can be laid out without measuring this first.
  static double height() => 96.r;

  /// Logical size of one thumbnail. 3:2 is a compromise between the 4:3 of the
  /// consoles most of this library is and the 16:9 the handhelds capture at;
  /// the image is cropped to it rather than letterboxed either way.
  static double thumbWidth() => 96.r;

  static double thumbHeight() => 64.r;

  @override
  State<RommGalleryStrip> createState() => _RommGalleryStripState();
}

class _RommGalleryStripState extends State<RommGalleryStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(RommGalleryStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.isPanelActive != widget.isPanelActive) {
      _revealSelected();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Keeps the cursor's thumbnail on screen after a D-pad step.
  ///
  /// Scrolled by arithmetic rather than `Scrollable.ensureVisible`: the list is
  /// lazily built, so a thumbnail several steps away has no element to reach
  /// for yet, and every tile is the same fixed width — which makes its offset
  /// exactly computable.
  void _revealSelected() {
    if (!_controller.hasClients || widget.shots.isEmpty) return;
    final tile = RommGalleryStrip.thumbWidth() + _gap;
    final target = (widget.selectedIndex * tile).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  double get _gap => 6.r;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: RommGalleryStrip.height(),
      child: Container(
        padding: EdgeInsets.fromLTRB(8.r, 4.r, 8.r, 4.r),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10.r),
          border: PanelGateHighlight.border(
            context,
            // The strip advertises itself as enterable whenever there is
            // something in it to walk; an empty or failed gallery is a label,
            // not a control.
            isDrivable: widget.shots.isNotEmpty,
            isActive: widget.isPanelActive,
            restingColor: Colors.transparent,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Symbols.photo_library_rounded,
                  size: 12.r,
                  color: scheme.onSurface.withValues(alpha: 0.7),
                ),
                SizedBox(width: 4.r),
                Text(
                  AppLocale.rommGalleryTitle.getString(context),
                  style: TextStyle(
                    fontSize: 10.r,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4.r),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (widget.shots.isNotEmpty) return _buildList(theme);
    if (widget.loading) {
      return Center(
        child: SizedBox(
          width: 16.r,
          height: 16.r,
          child: CircularProgressIndicator(strokeWidth: 2.r),
        ),
      );
    }
    // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Localized User-Facing Text"
    return _buildMessage(
      theme,
      widget.hasError
          ? AppLocale.rommGalleryError.getString(context)
          : AppLocale.rommGalleryEmpty.getString(context),
      isError: widget.hasError,
    );
  }

  Widget _buildMessage(ThemeData theme, String text, {required bool isError}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.r,
          color: isError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    return ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      itemCount: widget.shots.length,
      separatorBuilder: (_, _) => SizedBox(width: _gap),
      itemBuilder: (context, index) => _buildThumb(theme, index),
    );
  }

  Widget _buildThumb(ThemeData theme, int index) {
    final shot = widget.shots[index];
    final selected = widget.isPanelActive && index == widget.selectedIndex;
    final url = widget.urlOf(shot);
    return GestureDetector(
      onTap: () => widget.onActivate(index),
      child: Container(
        width: RommGalleryStrip.thumbWidth(),
        height: RommGalleryStrip.thumbHeight(),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : Colors.white.withValues(alpha: 0.12),
            width: selected ? 2.r : 1.r,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5.r),
          child: url == null
              ? _placeholder(theme)
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    _placeholder(theme),
                    Image.network(
                      url,
                      fit: BoxFit.cover,
                      cacheWidth: coverDecodeWidth(
                        logicalWidth: RommGalleryStrip.thumbWidth(),
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                      gaplessPlayback: true,
                      headers: widget.headersOf(url),
                      errorBuilder: (_, _, _) => _placeholder(theme),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) => Container(
    color: theme.colorScheme.surface.withValues(alpha: 0.6),
    child: Center(
      child: Icon(
        Symbols.image_rounded,
        size: 18.r,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    ),
  );
}
