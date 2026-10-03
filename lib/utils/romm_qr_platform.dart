import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, visibleForTesting;

import '../services/android_service.dart';

/// Whether the RomM connect form offers the "Scan QR code" action on
/// [platform], given whether the device [hasCamera].
///
/// Only Android and macOS get the action: those are the platforms where
/// `mobile_scanner` is wired in and where the app can reasonably meet a
/// camera (a phone, a tablet, a MacBook). Windows and Linux builds never show
/// it — the typed code is the only path there — so nothing camera-related
/// is reachable in those builds. And an Android handheld without a camera
/// gets no action either: CameraX throws on the main thread while
/// initialising on such a device and takes the process down, so the scanner
/// must never be opened there. Pure so the gate is testable without a
/// device; the screen passes `defaultTargetPlatform` and
/// [DeviceCamera.available].
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
bool showsQrScanAction(TargetPlatform platform, {bool hasCamera = true}) =>
    switch (platform) {
      TargetPlatform.android || TargetPlatform.macOS => hasCamera,
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };

/// Whether this device has a camera, asked once of the platform at startup.
///
/// Android answers through `PackageManager.hasSystemFeature(FEATURE_CAMERA_ANY)`;
/// every other platform is taken to have one, since only Android ships
/// camera-less devices this app runs on and only Android's camera stack
/// crashes on them. Until [probe] has answered, the device is assumed to
/// have none: a missing action for a moment is nothing, a crash is not.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
abstract final class DeviceCamera {
  static bool? _available;

  /// Whether a camera is known to exist.
  static bool get available => _available ?? !Platform.isAndroid;

  /// Asks the platform once. Safe to call more than once; later calls return
  /// the first answer.
  static Future<void> probe() async {
    if (_available != null) return;
    _available = Platform.isAndroid ? await AndroidService.hasCamera() : true;
  }

  /// Fixes the answer, for tests and for a host that already knows.
  @visibleForTesting
  static void debugSet(bool? value) => _available = value;
}
