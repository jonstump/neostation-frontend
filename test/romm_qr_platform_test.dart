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

  // Governing: SPEC-0007 REQ "QR Scan Where A Camera Exists" — the Retroid
  // Pocket Nova has no camera, and CameraX took the app down when the action
  // was used there.
  group('showsQrScanAction without a camera', () {
    test(
      'no camera, no action, on the platforms that would have offered it',
      () {
        expect(
          showsQrScanAction(TargetPlatform.android, hasCamera: false),
          isFalse,
        );
        expect(
          showsQrScanAction(TargetPlatform.macOS, hasCamera: false),
          isFalse,
        );
      },
    );

    test('a camera changes nothing where the action never existed', () {
      expect(
        showsQrScanAction(TargetPlatform.windows, hasCamera: true),
        isFalse,
      );
      expect(showsQrScanAction(TargetPlatform.linux, hasCamera: true), isFalse);
    });
  });

  group('DeviceCamera', () {
    tearDown(() => DeviceCamera.debugSet(null));

    test('a fixed answer is what the gate reads', () {
      DeviceCamera.debugSet(false);
      expect(DeviceCamera.available, isFalse);
      DeviceCamera.debugSet(true);
      expect(DeviceCamera.available, isTrue);
    });

    test('a device not yet asked counts as having a camera off Android', () {
      // The test host is a desktop: off Android the stack cannot crash.
      expect(DeviceCamera.available, isTrue);
    });
  });
}
