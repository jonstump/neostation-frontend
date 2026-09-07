import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_manual.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../services/logger_service.dart';
import '../../services/sfx_service.dart';
import '../../utils/gamepad_nav.dart';
import 'manual_viewer_cursor.dart';

/// Full-screen, gamepad-driven reader for a game's RomM manual.
///
/// Opened on a file that is already on disk — `RommManualCache` decides
/// whether that needed a download — so the viewer itself never touches the
/// network and works with the server unreachable.
///
/// Like every full-screen route it registers its own
/// [GamepadNavigationManager] layer in the same post-frame callback as its
/// navigator's `initialize()`, and pops it in `dispose()`; without the layer
/// the manager would wake the screen underneath on resume and two navigators
/// would answer the same press (CLAUDE.md).
///
/// Controls: L1/R1 turn pages, the D-pad pans a magnified page (and scrolls
/// text), X cycles the zoom steps, B leaves. A render failure swaps the page
/// for the "Open externally" fallback rather than a blank screen.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
class ManualViewerScreen extends StatefulWidget {
  /// Absolute path of the cached manual file.
  final String filePath;

  /// What the file is, decided from its extension by [RommManual].
  final RommManualKind kind;

  /// Game name, shown in the header.
  final String title;

  const ManualViewerScreen({
    super.key,
    required this.filePath,
    required this.kind,
    required this.title,
  });

  /// Pushes the viewer and resolves when it closes.
  static Future<void> show(
    BuildContext context, {
    required String filePath,
    required RommManualKind kind,
    required String title,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ManualViewerScreen(filePath: filePath, kind: kind, title: title),
      ),
    );
  }

  @override
  State<ManualViewerScreen> createState() => _ManualViewerScreenState();
}

class _ManualViewerScreenState extends State<ManualViewerScreen> {
  static const String _layerId = 'manual_viewer';
  static final _log = LoggerService.instance;

  /// How far one D-pad press scrolls the text view: about three lines, the
  /// same step the game info description panel uses.
  static const double _textScrollStep = 56.0;

  late final GamepadNavigation _gamepadNav;

  /// The pure input mapping — which page, which zoom step, whether panning is
  /// on. Held here so the screen only turns its answers into pixels.
  final ManualViewerCursor _cursor = ManualViewerCursor();

  final PdfViewerController _pdfController = PdfViewerController();
  final ScrollController _textController = ScrollController();

  /// The zoom the viewer settled on when the document opened — "fit the page".
  /// Every zoom step is a multiple of it, so the steps mean the same thing on
  /// a portrait manual and a landscape one.
  double _fitZoom = 1.0;

  /// Text of a `.txt`/`.md` manual, once read.
  String? _text;

  /// Set when the file cannot be shown: a PDF pdfium refuses, or a text file
  /// that cannot be read. Drives the "Open externally" fallback.
  Object? _renderError;

  /// Whether the render failure has already been logged, so a rebuild does not
  /// log it again (SPEC-0017 REQ "Error Handling Standards": surfaced once).
  bool _renderErrorLogged = false;

  /// Set while an external open is in flight, so a held button cannot fire it
  /// repeatedly.
  bool _openingExternally = false;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onBack: _close,
      onLeftBumper: _previousPage,
      onRightBumper: _nextPage,
      onXButton: _cycleZoom,
      onSelectItem: _onSelect,
      onNavigateUp: () => _pan(ManualPanDirection.up),
      onNavigateDown: () => _pan(ManualPanDirection.down),
      onNavigateLeft: () => _pan(ManualPanDirection.left),
      onNavigateRight: () => _pan(ManualPanDirection.right),
    );

    // The layer goes up in the SAME post-frame callback as initialize(): a
    // navigator that activated without registering is invisible to the
    // manager, and reactivate() on resume would then wake the screen buried
    // under this one.
    // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        _layerId,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });

    if (widget.kind != RommManualKind.pdf) _loadText();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _textController.dispose();
    super.dispose();
  }

  /// Reads a `.txt`/`.md` manual off disk. Markdown is shown as its source:
  /// readable as-is, and a Markdown widget is explicitly optional for v1.
  Future<void> _loadText() async {
    try {
      final text = await File(widget.filePath).readAsString();
      if (!mounted) return;
      setState(() => _text = text);
    } catch (e) {
      _failRender(e);
    }
  }

  /// Records a render failure and lights the fallback, logging it once.
  void _failRender(Object error) {
    if (!_renderErrorLogged) {
      _renderErrorLogged = true;
      _log.w(
        '[ManualViewerScreen] Render failed: path=${widget.filePath} '
        'kind=${widget.kind.name} error=$error',
      );
    }
    if (!mounted) return;
    setState(() => _renderError = error);
  }

  void _close() => Navigator.of(context).maybePop();

  /// A on the failure screen is the same as its button.
  void _onSelect() {
    if (_renderError != null) _openExternally();
  }

  bool get _isPdf => widget.kind == RommManualKind.pdf && _renderError == null;

  void _nextPage() {
    if (!_isPdf || !_pdfController.isReady) return;
    _cursor.setPageCount(_pdfController.pages.length);
    if (!_cursor.nextPage()) return;
    SfxService().playNavSound();
    _applyPage();
  }

  void _previousPage() {
    if (!_isPdf || !_pdfController.isReady) return;
    _cursor.setPageCount(_pdfController.pages.length);
    if (!_cursor.previousPage()) return;
    SfxService().playNavSound();
    _applyPage();
  }

  /// Turning a page drops the zoom back to fit: landing on the corner of the
  /// next page magnified is disorienting, and the reader can zoom back in.
  void _applyPage() {
    _cursor.resetZoom();
    _pdfController.goToPage(pageNumber: _cursor.page);
    setState(() {});
  }

  void _cycleZoom() {
    if (widget.kind != RommManualKind.pdf) return;
    if (_renderError != null || !_pdfController.isReady) return;
    final zoom = _cursor.cycleZoom();
    SfxService().playNavSound();
    _pdfController.setZoom(_pdfController.centerPosition, _fitZoom * zoom);
    setState(() {});
  }

  /// D-pad: pans a magnified PDF page, scrolls a text manual, and is ignored
  /// on a page that already fits (nothing off screen to reach).
  void _pan(ManualPanDirection direction) {
    if (_renderError != null) return;

    if (widget.kind != RommManualKind.pdf) {
      final delta = switch (direction) {
        ManualPanDirection.up => -_textScrollStep.r,
        ManualPanDirection.down => _textScrollStep.r,
        _ => 0.0,
      };
      _scrollText(delta);
      return;
    }

    if (!_pdfController.isReady) return;
    final visible = _pdfController.visibleRect;
    final step = _cursor.panStep(
      direction,
      viewWidth: visible.width,
      viewHeight: visible.height,
    );
    if (step == null) return;
    _pdfController.goToPosition(
      documentOffset: visible.topLeft + Offset(step.$1, step.$2),
    );
  }

  void _scrollText(double delta) {
    if (delta == 0 || !_textController.hasClients) return;
    final position = _textController.position;
    final target = (position.pixels + delta).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return;
    _textController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  /// Hands the file to whatever the platform opens it with.
  ///
  /// The fallback of last resort: a PDF pdfium refuses may still open in a
  /// desktop reader. It is best-effort by nature — a device with no handler
  /// (or a platform that refuses a `file://` view intent) says so rather than
  /// failing silently.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
  Future<void> _openExternally() async {
    if (_openingExternally) return;
    _openingExternally = true;
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.file(widget.filePath),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      _log.w(
        '[ManualViewerScreen] External open failed: '
        'path=${widget.filePath} error=$e',
      );
    } finally {
      _openingExternally = false;
    }
    if (!opened && mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            AppLocale.manualOpenExternallyFailed.getString(context),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme),
            Expanded(child: _buildBody(theme)),
            _buildHints(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16.r, 12.r, 16.r, 8.r),
      child: Row(
        children: [
          Icon(Symbols.menu_book_rounded, size: 18.r, color: scheme.onSurface),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14.r,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_isPdf) _buildPageIndicator(theme),
        ],
      ),
    );
  }

  /// `{page}/{total}`, always visible while a PDF is open.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
  Widget _buildPageIndicator(ThemeData theme) {
    final label = AppLocale.manualPageIndicator
        .getString(context)
        .replaceFirst('{page}', _cursor.pageLabel)
        .replaceFirst('{total}', _cursor.pageCountLabel);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onSecondaryContainer,
          fontSize: 11.r,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_renderError != null) return _buildFallback(theme);
    if (widget.kind == RommManualKind.pdf) return _buildPdf(theme);
    return _buildText(theme);
  }

  Widget _buildPdf(ThemeData theme) {
    return PdfViewer.file(
      widget.filePath,
      controller: _pdfController,
      params: PdfViewerParams(
        backgroundColor: theme.colorScheme.surface,
        onViewerReady: (document, controller) {
          _fitZoom = controller.currentZoom;
          if (!mounted) return;
          setState(() => _cursor.setPageCount(document.pages.length));
        },
        // Touch scrolling moves the page under the reader too, so the cursor
        // follows the viewer rather than only driving it.
        onPageChanged: (pageNumber) {
          if (pageNumber == null || !mounted) return;
          if (_cursor.setPage(pageNumber)) setState(() {});
        },
        errorBannerBuilder: (context, error, stackTrace, documentRef) {
          // pdfium reports a document it cannot open here. Swap in the
          // fallback on the next frame — this runs during build.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _failRender(error),
          );
          return const SizedBox.shrink();
        },
      ),
    );
  }

  Widget _buildText(ThemeData theme) {
    final text = _text;
    if (text == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Scrollbar(
      controller: _textController,
      child: SingleChildScrollView(
        controller: _textController,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 12.r),
        child: SelectionArea(
          child: Text(
            text,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 12.r,
              height: 1.6,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallback(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_outline_rounded, size: 32.r, color: scheme.error),
          SizedBox(height: 12.r),
          Text(
            AppLocale.manualRenderFailed.getString(context),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurface, fontSize: 13.r),
          ),
          SizedBox(height: 20.r),
          // Focused by default: it is the only control on this screen, so A
          // runs it without any cursor to move first.
          FilledButton.icon(
            onPressed: _openExternally,
            icon: Icon(Symbols.open_in_new_rounded, size: 16.r),
            label: Text(AppLocale.manualOpenExternally.getString(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildHints(ThemeData theme) {
    final style = TextStyle(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      fontSize: 10.r,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16.r, 4.r, 16.r, 10.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Text(AppLocale.back.getString(context), style: style)],
      ),
    );
  }
}
