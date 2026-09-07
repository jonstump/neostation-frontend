import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../../../../models/game_model.dart';
import '../../../../models/romm_screenshot.dart';
import '../../../../providers/romm_provider.dart';
import '../../../../providers/sqlite_config_provider.dart';
import '../../../../services/logger_service.dart';
import '../../../../services/sfx_service.dart';
import '../../../../themes/corner_radii.dart';
import '../dialogs/romm_screenshot_viewer.dart';
import '../widgets/romm_gallery_strip.dart';

class GameDetailsScreenshotVideoTab extends StatefulWidget {
  final String screenshotPath;
  final bool isVideoDelayActive;
  final VideoPlayerController? videoController;
  final int imageVersion;
  final VoidCallback onToggleVideoMute;

  /// The game this panel is showing media for, when the card has one.
  ///
  /// Optional because the panel's geometry — which is what most of it is
  /// about, and what its test measures — does not need a game. Only the RomM
  /// gallery strip does, and with no game there is no strip and the panel is
  /// exactly what it was before ADR-0016.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  final GameModel? game;

  /// Where the footer starts, so the media stops there and no lower.
  ///
  /// The other three panels have taken this from the card since the footer's
  /// height stopped being a constant; this one kept a hardcoded 110 and went
  /// on reserving room for a row that had shrunk to 90. Since a screenshot in
  /// this panel is almost always height-bound — 4:3 art in a panel close to
  /// 2:1 — every unit reserved here came straight off the image's width.
  final double bottomOffset;

  const GameDetailsScreenshotVideoTab({
    super.key,
    required this.screenshotPath,
    required this.isVideoDelayActive,
    this.videoController,
    required this.imageVersion,
    required this.onToggleVideoMute,
    this.bottomOffset = 110.0,
    this.game,
  });

  @override
  State<GameDetailsScreenshotVideoTab> createState() =>
      GameDetailsScreenshotVideoTabState();
}

class GameDetailsScreenshotVideoTabState
    extends State<GameDetailsScreenshotVideoTab> {
  static final _log = LoggerService.instance;

  final Map<String, double> _imageAspectRatios = {};

  ImageStream? _currentImageStream;
  ImageStreamListener? _currentImageListener;

  // ── RomM gallery ────────────────────────────────────────────────────────

  /// The linked game's RomM user screenshots, newest first. Empty until (and
  /// unless) a gallery lands.
  List<RommScreenshot> _shots = const [];

  /// Whether the strip is drawn at all: connected, linked, and a server whose
  /// version does not rule the gallery out. Resolved asynchronously, because
  /// "linked" is a database question.
  bool _galleryVisible = false;
  bool _galleryLoading = false;
  bool _galleryError = false;
  int _galleryIndex = 0;
  bool _isPanelActive = false;

  /// Identifies the load in flight, so a gallery for a game the card has since
  /// moved off cannot overwrite the current one.
  int _galleryGeneration = 0;

  @override
  void initState() {
    super.initState();
    // A provider read needs a mounted element, and the card builds this panel
    // for every game it passes through while the user scrolls.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshGallery());
  }

  @override
  void didUpdateWidget(GameDetailsScreenshotVideoTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game?.romPath != widget.game?.romPath ||
        oldWidget.game?.romname != widget.game?.romname) {
      _resetGallery();
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshGallery());
    }
  }

  void _resetGallery() {
    _galleryGeneration++;
    _shots = const [];
    _galleryVisible = false;
    _galleryLoading = false;
    _galleryError = false;
    _galleryIndex = 0;
    _isPanelActive = false;
  }

  /// Decides whether this game gets a strip and, if so, loads it.
  ///
  /// Every failure mode ends in a drawn state rather than an exception: an
  /// unlinked or unsupported game hides the strip, a failed request shows the
  /// localized error line, and a load for a game the card has moved off is
  /// dropped on its generation check.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  Future<void> _refreshGallery() async {
    final game = widget.game;
    if (!mounted || game == null) return;

    final provider = context.read<RommProvider>();

    final generation = ++_galleryGeneration;
    final romId = await provider.linkedRomId(game);
    if (!mounted || generation != _galleryGeneration) return;

    final visible = provider.galleryStripVisibleFor(linked: romId != null);
    if (!visible) {
      setState(() {
        _galleryVisible = false;
        _shots = const [];
      });
      return;
    }

    setState(() {
      _galleryVisible = true;
      _galleryLoading = true;
      _galleryError = false;
    });

    List<RommScreenshot> shots = const [];
    var failed = false;
    try {
      shots = await provider.galleryFor(game);
    } catch (e) {
      failed = true;
      _log.w('RomM gallery strip failed game="${game.romname}": $e');
    }
    if (!mounted || generation != _galleryGeneration) return;

    setState(() {
      _shots = shots;
      _galleryLoading = false;
      _galleryError = failed;
      _galleryIndex = 0;
      if (shots.isEmpty) _isPanelActive = false;
    });
  }

  // ── Panel gate (gamepad) ────────────────────────────────────────────────

  /// Whether the strip currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  /// Whether there is anything in this panel to drive. False keeps A as the
  /// card's launch button, which is what it is on a media tab with no gallery.
  bool get isDrivable => _galleryVisible && _shots.isNotEmpty;

  /// Takes the D-pad (gamepad A). Returns whether it was taken.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  bool enterPanel() {
    if (_isPanelActive) return true;
    if (!isDrivable) return false;
    setState(() => _isPanelActive = true);
    return true;
  }

  /// Gives the D-pad back to the details card (gamepad B). Returns whether it
  /// was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;
    setState(() => _isPanelActive = false);
    return true;
  }

  /// Opens the focused screenshot full screen. Returns whether anything ran.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  bool activateFocused() {
    if (!_isPanelActive || _shots.isEmpty) return false;
    _openViewer(_galleryIndex);
    return true;
  }

  /// Gamepad navigation delegate: steps the strip's cursor left.
  void moveLeft() => _stepGallery(-1);

  /// Gamepad navigation delegate: steps the strip's cursor right.
  void moveRight() => _stepGallery(1);

  /// Gamepad navigation delegate: the strip is one row, so there is no
  /// vertical axis in here. Swallowed rather than left unhandled so a stray
  /// press cannot slide the tab out from under an active strip; B is the way
  /// out, as everywhere else in the card.
  void moveUp() {}

  /// Gamepad navigation delegate: see [moveUp].
  void moveDown() {}

  void _stepGallery(int delta) {
    if (!_isPanelActive || _shots.isEmpty) return;
    final next = _galleryIndex + delta;
    if (next < 0 || next >= _shots.length) return;
    SfxService().playNavSound();
    setState(() => _galleryIndex = next);
  }

  /// Opens the full-screen viewer and adopts whichever screenshot the user
  /// left it on as the strip's new cursor.
  Future<void> _openViewer(int index) async {
    if (index < 0 || index >= _shots.length) return;
    final provider = context.read<RommProvider>();
    SfxService().playNavSound();
    // Entering by touch on an inactive strip should leave it holding the
    // D-pad, so the user can walk the rest of the gallery on the way back.
    if (!_isPanelActive) setState(() => _isPanelActive = true);
    final landed = await RommScreenshotViewer.show(
      context,
      shots: _shots,
      initialIndex: index,
      urlOf: provider.screenshotUrl,
      headersOf: provider.service.imageHeadersFor,
    );
    if (!mounted || landed == null) return;
    if (landed >= 0 && landed < _shots.length && landed != _galleryIndex) {
      setState(() => _galleryIndex = landed);
    }
  }

  void _loadImageAspectRatio(String path) {
    if (_imageAspectRatios.containsKey(path) || path.isEmpty) return;

    final File file = File(path);
    if (!file.existsSync()) return;

    _removeImageListener();

    final Image image = Image.file(file);
    final ImageStream stream = image.image.resolve(const ImageConfiguration());

    final listener = ImageStreamListener((
      ImageInfo info,
      bool synchronousCall,
    ) {
      if (!mounted) return;
      final double aspectRatio = info.image.width / info.image.height;
      if (aspectRatio <= 0 || (_imageAspectRatios[path] == aspectRatio)) {
        return;
      }

      void update() {
        setState(() {
          _imageAspectRatios[path] = aspectRatio;
        });
      }

      if (synchronousCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) update();
        });
      } else {
        update();
      }
    });

    stream.addListener(listener);
    _currentImageStream = stream;
    _currentImageListener = listener;
  }

  void _removeImageListener() {
    if (_currentImageStream != null && _currentImageListener != null) {
      _currentImageStream!.removeListener(_currentImageListener!);
      _currentImageStream = null;
      _currentImageListener = null;
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenshotPath = widget.screenshotPath;

    final bool hasVideo =
        widget.videoController != null &&
        widget.videoController!.value.isInitialized;

    if (screenshotPath.isNotEmpty) {
      _loadImageAspectRatio(screenshotPath);
    }

    double mediaAspectRatio = 16 / 9;

    if (!widget.isVideoDelayActive && hasVideo) {
      mediaAspectRatio = widget.videoController!.value.aspectRatio;
    } else if (_imageAspectRatios.containsKey(screenshotPath)) {
      mediaAspectRatio = _imageAspectRatios[screenshotPath]!;
    }

    if (mediaAspectRatio <= 0 || mediaAspectRatio.isNaN) {
      mediaAspectRatio = 16 / 9;
    }

    // The strip takes its room out of the media's, below it, so the panel's
    // outer insets — which its geometry test measures — are untouched by a
    // gallery that is or is not there.
    // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
    if (_galleryVisible) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12.r, 55.r, 12.r, widget.bottomOffset.r),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _buildMedia(
                  context,
                  mediaAspectRatio,
                  screenshotPath,
                  hasVideo,
                ),
              ),
            ),
            SizedBox(height: 6.r),
            _buildGalleryStrip(),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(12.r, 55.r, 12.r, widget.bottomOffset.r),
      child: Center(
        child: _buildMedia(context, mediaAspectRatio, screenshotPath, hasVideo),
      ),
    );
  }

  /// The RomM gallery strip, wired to this panel's cursor and load state.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  Widget _buildGalleryStrip() {
    final provider = context.read<RommProvider>();
    return RommGalleryStrip(
      shots: _shots,
      loading: _galleryLoading,
      hasError: _galleryError,
      selectedIndex: _galleryIndex,
      isPanelActive: _isPanelActive,
      urlOf: provider.screenshotUrl,
      headersOf: provider.service.imageHeadersFor,
      onActivate: _openViewer,
    );
  }

  /// The screenshot / video box itself, unchanged by the gallery: the same
  /// widget whether or not a strip sits under it.
  Widget _buildMedia(
    BuildContext context,
    double mediaAspectRatio,
    String screenshotPath,
    bool hasVideo,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(14.r),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.3),
            blurRadius: 3.r,
            offset: Offset(3.0.r, 3.0.r),
          ),
        ],
        color: Colors.transparent,
      ),
      child: ClipRRect(
        borderRadius:
            Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
            BorderRadius.circular(14.r),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: mediaAspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!widget.isVideoDelayActive &&
                  hasVideo &&
                  widget.videoController!.value.isInitialized &&
                  widget.videoController!.value.size.width > 0 &&
                  widget.videoController!.value.size.height > 0) ...[
                Consumer<SqliteConfigProvider>(
                  builder: (context, config, child) {
                    return VideoPlayer(widget.videoController!);
                  },
                ),
              ] else if (File(screenshotPath).existsSync()) ...[
                Image.file(
                  File(screenshotPath),
                  height: double.infinity,
                  cacheHeight: 640,
                  key: ValueKey('${screenshotPath}_fg_${widget.imageVersion}'),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ] else
                Center(
                  child: Icon(
                    Symbols.videogame_asset_rounded,
                    size: 48.r,
                    color: Colors.white24,
                  ),
                ),

              if (!widget.isVideoDelayActive && hasVideo)
                Positioned(
                  bottom: 8.r,
                  right: 8.r,
                  child: ExcludeFocus(
                    child: Material(
                      color: Colors.black54,
                      borderRadius:
                          Theme.of(
                            context,
                          ).extension<CornerRadii>()?.radiusExternal ??
                          BorderRadius.circular(14.r),
                      child: InkWell(
                        onTap: () {
                          SfxService().playNavSound();
                          widget.onToggleVideoMute();
                        },
                        canRequestFocus: false,
                        focusColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        highlightColor: Colors.transparent,
                        splashColor: Colors.transparent,
                        borderRadius:
                            Theme.of(
                              context,
                            ).extension<CornerRadii>()?.radiusInternal ??
                            BorderRadius.circular(14.r),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8.r,
                            vertical: 4.r,
                          ),
                          child: Consumer<SqliteConfigProvider>(
                            builder: (context, configProvider, child) {
                              final isMuted = !configProvider.config.videoSound;
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.asset(
                                    'assets/images/gamepad/Xbox_View_button.png',
                                    width: 14.r,
                                    height: 14.r,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 4.r),
                                  Icon(
                                    isMuted
                                        ? Symbols.volume_off_rounded
                                        : Symbols.volume_up_rounded,
                                    size: 12.r,
                                    color: Colors.white,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
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
