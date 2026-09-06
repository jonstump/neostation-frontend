import 'package:flutter/foundation.dart' show TargetPlatform;

/// Whether the RomM connect form offers the "Scan QR code" action on
/// [platform].
///
/// Only Android and macOS get the action: those are the platforms where
/// `mobile_scanner` is wired in and where the app can reasonably meet a
/// camera (a phone, a tablet, a MacBook). Windows and Linux builds never show
/// it — the typed code is the only path there — so nothing camera-related
/// is reachable in those builds. Pure so the gate is testable without a
/// device; the screen passes `defaultTargetPlatform`.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
bool showsQrScanAction(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android || TargetPlatform.macOS => true,
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => false,
};
