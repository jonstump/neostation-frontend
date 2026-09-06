import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_pairing.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../services/logger_service.dart';
import '../../utils/gamepad_nav.dart';

/// What [RommQrScanScreen] hands back to the connect form. A null route
/// result (B, the back arrow, a system back gesture) means the user left
/// without scanning anything.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
sealed class RommQrScanResult {
  const RommQrScanResult();

  /// A RomM pairing QR was read: [link] carries the server origin and the
  /// normalized code, ready to exchange.
  const factory RommQrScanResult.link(RommPairLink link) = RommQrScanLink;

  /// The user (or a device policy) refused camera access, so the typed code
  /// is the only way in.
  const factory RommQrScanResult.denied() = RommQrScanDenied;

  /// The camera could not be started at all — no camera on the device, or
  /// the platform refused for a reason other than permission.
  const factory RommQrScanResult.unavailable() = RommQrScanUnavailable;
}

class RommQrScanLink extends RommQrScanResult {
  final RommPairLink link;

  const RommQrScanLink(this.link);
}

class RommQrScanDenied extends RommQrScanResult {
  const RommQrScanDenied();
}

class RommQrScanUnavailable extends RommQrScanResult {
  const RommQrScanUnavailable();
}

/// Full-screen camera view that reads RomM's pairing QR code.
///
/// Pushed as its own route on top of the connect form, and — like every
/// full-screen route — registered as its own [GamepadNavigationManager]
/// layer so B closes it and the form underneath stays deaf while it is up.
/// The plugin owns the camera lifecycle and asks for permission on start; the
/// screen only decides what a frame means: the first barcode whose payload
/// [RommPairLink.parse] accepts pops with [RommQrScanResult.link], anything
/// else lights a short refusal and keeps scanning, and a camera that cannot
/// start pops with [RommQrScanResult.denied] or [RommQrScanResult.unavailable]
/// so the form can say why.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
class RommQrScanScreen extends StatefulWidget {
  const RommQrScanScreen({super.key});

  /// Opens the scanner and resolves when it closes. Null means the user
  /// backed out.
  static Future<RommQrScanResult?> show(BuildContext context) {
    return Navigator.of(context).push<RommQrScanResult?>(
      MaterialPageRoute<RommQrScanResult?>(
        builder: (_) => const RommQrScanScreen(),
      ),
    );
  }

  @override
  State<RommQrScanScreen> createState() => _RommQrScanScreenState();
}

class _RommQrScanScreenState extends State<RommQrScanScreen> {
  static const String _layerId = 'romm_qr_scan';

  /// How long the "not a pairing code" line stays lit after a wrong QR, and
  /// the least time between two lightings, so a code held in frame reads as
  /// one steady message rather than a flicker.
  static const Duration _refusalThrottle = Duration(seconds: 1);
  static const Duration _refusalVisible = Duration(milliseconds: 1500);

  static final _log = LoggerService.instance;

  late final GamepadNavigation _gamepadNav;
  late final MobileScannerController _controller;

  /// Set once the route's result is decided, so a second frame or a second
  /// controller notification cannot pop the route twice.
  bool _done = false;
  bool _showRefusal = false;
  DateTime? _lastRefusal;
  Timer? _refusalTimer;

  @override
  void initState() {
    super.initState();
    // Normal detection speed so a wrong code held in frame is reported again
    // every interval and the refusal stays up; noDuplicates would report it
    // once and then fall silent while the user keeps pointing at it.
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 1000,
    )..addListener(_onControllerChanged);
    _gamepadNav = GamepadNavigation(onBack: _close, allowRepeat: false);
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
    _refusalTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    // The MobileScanner widget stops a controller it was handed but does not
    // dispose it; that is this screen's job.
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// The controller reports a camera that failed to start through its state
  /// (`value.error`), set by `start()` when the platform refuses. A refusal
  /// is either the permission, which the user can grant later, or the camera
  /// itself; either way the form underneath is where the user goes next.
  void _onControllerChanged() {
    final error = _controller.value.error;
    if (error == null || _done) return;
    _log.w(
      '[RommQrScanScreen] Camera failed to start: code=${error.errorCode.name} '
      'message=${error.errorDetails?.message}',
    );
    final result = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        const RommQrScanResult.denied(),
      // `unsupported` is the plugin's "no camera"; anything else that stops
      // the camera from starting (already in use, a generic platform error)
      // leaves the user just as unable to scan.
      _ => const RommQrScanResult.unavailable(),
    };
    _finish(result);
  }

  /// Decides the route's result once and pops. Called from a detection, a
  /// controller error, or B — whichever comes first wins.
  void _finish(RommQrScanResult? result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(result);
  }

  void _close() => _finish(null);

  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    var sawPayload = false;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      sawPayload = true;
      final link = RommPairLink.parse(raw);
      if (link == null) continue;
      _log.i('[RommQrScanScreen] Pairing QR read for ${link.serverUrl}');
      // Stop the preview now so the last frame doesn't keep feeding
      // detections while the route animates away.
      unawaited(_controller.stop());
      _finish(RommQrScanResult.link(link));
      return;
    }
    if (sawPayload) _refuse();
  }

  /// Lights the "not a pairing code" line for a moment, at most once per
  /// [_refusalThrottle]. Scanning continues regardless.
  void _refuse() {
    final now = DateTime.now();
    final last = _lastRefusal;
    if (last != null && now.difference(last) < _refusalThrottle) return;
    _lastRefusal = now;
    _refusalTimer?.cancel();
    setState(() => _showRefusal = true);
    _refusalTimer = Timer(_refusalVisible, () {
      if (!mounted) return;
      setState(() => _showRefusal = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            fit: BoxFit.cover,
            onDetect: _onDetect,
            // A start failure is handled by _onControllerChanged, which pops
            // the route; the frame it takes to get there stays black rather
            // than showing the plugin's default error text.
            errorBuilder: (_, _) => const ColoredBox(color: Colors.black),
            placeholderBuilder: (_) => const ColoredBox(color: Colors.black),
          ),
          _buildViewfinder(scheme),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(theme),
                const Spacer(),
                _buildRefusal(scheme),
                SizedBox(height: 12.r),
                _buildBackHint(scheme),
                SizedBox(height: 16.r),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Title and prompt over a dark gradient so they read on any camera feed.
  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(16.r, 12.r, 16.r, 24.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.75),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: Icon(Symbols.arrow_back_rounded, color: Colors.white),
            iconSize: 20.r,
            onPressed: _close,
            tooltip: AppLocale.back.getString(context),
          ),
          SizedBox(width: 4.r),
          Icon(
            Symbols.qr_code_scanner_rounded,
            color: scheme.primary,
            size: 24.r,
          ),
          SizedBox(width: 12.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocale.rommScanQrTitle.getString(context),
                  style: TextStyle(
                    fontSize: 16.r,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4.r),
                Text(
                  AppLocale.rommScanQrPrompt.getString(context),
                  style: TextStyle(
                    fontSize: 10.r,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  softWrap: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A square frame in the middle of the feed, so the user knows where to
  /// hold the code. Purely visual — the plugin scans the whole frame.
  Widget _buildViewfinder(ColorScheme scheme) {
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 160.r,
          height: 160.r,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: _showRefusal
                  ? scheme.error
                  : scheme.primary.withValues(alpha: 0.9),
              width: 2.r,
            ),
          ),
        ),
      ),
    );
  }

  /// "That is not a RomM pairing code", shown briefly under the viewfinder
  /// after a QR that parses as something else. Reserves its height while
  /// hidden so the back hint doesn't jump.
  Widget _buildRefusal(ColorScheme scheme) {
    return AnimatedOpacity(
      opacity: _showRefusal ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: scheme.error.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8.r),
        ),
        child: Text(
          AppLocale.rommScanQrNotPairingCode.getString(context),
          style: TextStyle(
            fontSize: 11.r,
            fontWeight: FontWeight.w600,
            color: scheme.onError,
          ),
        ),
      ),
    );
  }

  /// The B glyph plus "Back", the same pairing the app's dialogs wear.
  Widget _buildBackHint(ColorScheme scheme) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/images/gamepad/Xbox_B_button.png',
            width: 12.r,
            height: 12.r,
            color: Colors.white,
          ),
          SizedBox(width: 6.r),
          Text(
            AppLocale.back.getString(context).toUpperCase(),
            style: TextStyle(
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
