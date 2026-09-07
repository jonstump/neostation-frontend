import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../../l10n/app_locale.dart';
import '../../../../models/romm_screenshot.dart';
import '../../../../services/gamepad/gamepad_navigation_manager.dart';
import '../../../../services/sfx_service.dart';
import '../../../../utils/gamepad_nav.dart';

/// Full-screen view of one RomM gallery screenshot, with Left/Right walking
/// the rest of the gallery and B returning to the strip.
///
/// A full-screen route, so — like every full-screen route in this app — it
/// registers its own [GamepadNavigationManager] layer in the same post-frame
/// callback that starts its navigator, and pops that layer in [dispose].
/// Activating a navigator without pushing a layer leaves the screen invisible
/// to the manager, and `GameLaunchService.handleAppResumed` then wakes the
/// screen buried underneath it instead — two navigators handling one press.
///
/// The route resolves with the index the user left on, so the strip's cursor
/// follows what they were actually looking at.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
class RommScreenshotViewer extends StatefulWidget {
  /// The gallery, in the same order the strip drew it (newest first).
  final List<RommScreenshot> shots;

  /// Which screenshot the user confirmed.
  final int initialIndex;

  /// Absolute URL for a screenshot's bytes, or null when the server gave no
  /// usable path.
  final String? Function(RommScreenshot shot) urlOf;

  /// Auth headers for [url] — the bearer token only for the RomM server.
  final Map<String, String> Function(String url) headersOf;

  const RommScreenshotViewer({
    super.key,
    required this.shots,
    required this.initialIndex,
    required this.urlOf,
    required this.headersOf,
  });

  /// Opens the viewer and resolves with the index the user left on (or null
  /// when the gallery was empty and nothing was pushed).
  static Future<int?> show(
    BuildContext context, {
    required List<RommScreenshot> shots,
    required int initialIndex,
    required String? Function(RommScreenshot shot) urlOf,
    required Map<String, String> Function(String url) headersOf,
  }) {
    if (shots.isEmpty) return Future<int?>.value(null);
    return Navigator.of(context).push<int>(
      PageRouteBuilder<int>(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (_, _, _) => RommScreenshotViewer(
          shots: shots,
          initialIndex: initialIndex,
          urlOf: urlOf,
          headersOf: headersOf,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<RommScreenshotViewer> createState() => _RommScreenshotViewerState();
}

class _RommScreenshotViewerState extends State<RommScreenshotViewer> {
  static const String _layerId = 'romm_screenshot_viewer';

  late final GamepadNavigation _gamepadNav;
  late int _index;

  /// Set as the route pops, so a second button press cannot pop it twice.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.shots.length - 1);
    _gamepadNav = GamepadNavigation(
      onNavigateLeft: () => _step(-1),
      onNavigateRight: () => _step(1),
      // A on a screenshot the user is already looking at has nothing left to
      // do, so it closes — the same press that opened it takes it away again.
      onSelectItem: _close,
      onBack: _close,
      allowRepeat: false,
    );
    // The layer goes up in the same post-frame callback as initialize(): a
    // navigator activated without a registered layer is invisible to the
    // manager, and reactivate() would then wake the details card underneath.
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

  /// Moves to a neighbouring screenshot. Returns whether it moved, so the
  /// gamepad handler stays silent at either end of the gallery.
  bool _step(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.shots.length) return false;
    setState(() => _index = next);
    return true;
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    SfxService().playNavSound();
    Navigator.of(context).pop(_index);
  }

  @override
  Widget build(BuildContext context) {
    final shot = widget.shots[_index];
    final url = widget.urlOf(shot);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        // A tap anywhere closes, which is what a full-screen image does on a
        // touchscreen; the gamepad path is B.
        onTap: _close,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: url == null
                  ? _unavailable(context)
                  : Image.network(
                      url,
                      fit: BoxFit.contain,
                      headers: widget.headersOf(url),
                      errorBuilder: (_, _, _) => _unavailable(context),
                    ),
            ),
            Positioned(
              left: 16.r,
              bottom: 16.r,
              child: _caption(context, shot),
            ),
          ],
        ),
      ),
    );
  }

  /// File name plus the position in the gallery, so a user stepping through a
  /// session's captures can tell where they are.
  Widget _caption(BuildContext context, RommScreenshot shot) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.photo_library_rounded, size: 12.r, color: Colors.white),
          SizedBox(width: 6.r),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 320.r),
            child: Text(
              shot.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 10.r),
            ),
          ),
          if (widget.shots.length > 1) ...[
            SizedBox(width: 8.r),
            Text(
              '${_index + 1}/${widget.shots.length}',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.r,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// What a screenshot RomM cannot serve looks like. Reuses the gallery's
  /// error line rather than inventing a second wording for the same failure.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Localized User-Facing Text"
  Widget _unavailable(BuildContext context) => Text(
    AppLocale.rommGalleryError.getString(context),
    style: TextStyle(color: Colors.white70, fontSize: 12.r),
  );
}
