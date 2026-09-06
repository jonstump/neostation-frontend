import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/romm_qr_platform.dart';

/// The platform gate in front of the RomM "Scan QR code" action: Android
/// and macOS get it, every other platform the app builds for does not.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A
/// Camera Exists"
void main() {
  group('showsQrScanAction', () {
    test('is true on Android and macOS', () {
      expect(showsQrScanAction(TargetPlatform.android), isTrue);
      expect(showsQrScanAction(TargetPlatform.macOS), isTrue);
    });

    test('is false on Windows and Linux', () {
      expect(showsQrScanAction(TargetPlatform.windows), isFalse);
      expect(showsQrScanAction(TargetPlatform.linux), isFalse);
    });

    test('is false on every platform the app does not ship to', () {
      expect(showsQrScanAction(TargetPlatform.iOS), isFalse);
      expect(showsQrScanAction(TargetPlatform.fuchsia), isFalse);
    });

    test('covers every TargetPlatform without throwing', () {
      for (final platform in TargetPlatform.values) {
        expect(() => showsQrScanAction(platform), returnsNormally);
      }
    });
  });
}
