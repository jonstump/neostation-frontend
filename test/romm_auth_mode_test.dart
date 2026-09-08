import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/romm_screen/romm_auth_mode.dart';

/// The connect screen's three-way authentication switch as pure logic: how
/// A cycles, how Left/Right step and stop at the ends, and the D-pad slot
/// order each mode presents (URL first, the switch second in every mode,
/// connect last).
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On
/// The Connect Screen"
void main() {
  group('RommAuthMode cycling', () {
    test('segments are declared left to right', () {
      expect(RommAuthMode.values, [
        RommAuthMode.password,
        RommAuthMode.apiKey,
        RommAuthMode.pairCode,
      ]);
    });

    test('next advances one segment and wraps', () {
      expect(RommAuthMode.password.next, RommAuthMode.apiKey);
      expect(RommAuthMode.apiKey.next, RommAuthMode.pairCode);
      expect(RommAuthMode.pairCode.next, RommAuthMode.password);
    });

    test('Right twice from password lands on pairing code', () {
      expect(RommAuthMode.password.toRight.toRight, RommAuthMode.pairCode);
    });

    test('Right stops at pairing code instead of wrapping', () {
      expect(RommAuthMode.pairCode.toRight, RommAuthMode.pairCode);
      expect(RommAuthMode.apiKey.toRight, RommAuthMode.pairCode);
    });

    test('Left steps back and stops at password', () {
      expect(RommAuthMode.pairCode.toLeft, RommAuthMode.apiKey);
      expect(RommAuthMode.apiKey.toLeft, RommAuthMode.password);
      expect(RommAuthMode.password.toLeft, RommAuthMode.password);
    });

    test('three presses of next visit every mode once', () {
      var mode = RommAuthMode.password;
      final seen = <RommAuthMode>{};
      for (var i = 0; i < RommAuthMode.values.length; i++) {
        seen.add(mode);
        mode = mode.next;
      }
      expect(seen, RommAuthMode.values.toSet());
      expect(mode, RommAuthMode.password);
    });
  });

  // Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect
  // Screen Surfaces" — scenario "Password login disabled"
  group('authModeOrderFor', () {
    test('with the flag unknown or false the declared order stands', () {
      expect(
        authModeOrderFor(passwordLoginDisabled: false),
        RommAuthMode.values,
      );
    });

    test('a server without password login leads with pairing and puts the '
        'password segment last', () {
      expect(authModeOrderFor(passwordLoginDisabled: true), [
        RommAuthMode.pairCode,
        RommAuthMode.apiKey,
        RommAuthMode.password,
      ]);
    });

    test('the flag reorders the switch, it never drops a segment', () {
      for (final disabled in [false, true]) {
        final order = authModeOrderFor(passwordLoginDisabled: disabled);
        expect(order.toSet(), RommAuthMode.values.toSet(), reason: '$disabled');
        expect(order.length, RommAuthMode.values.length, reason: '$disabled');
        expect(
          order,
          contains(RommAuthMode.password),
          reason: 'password stays selectable ($disabled)',
        );
      }
    });

    test('the QR scan still follows the pairing code inside its mode', () {
      // QR is a row of pairing mode, not a segment: "pairing, QR, API key,
      // password" is the leading mode's rows followed by the other segments.
      final order = authModeOrderFor(passwordLoginDisabled: true);
      expect(order.first, RommAuthMode.pairCode);
      expect(focusOrderFor(order.first, includeScanQr: true), const [
        RommConnectSlot.url,
        RommConnectSlot.authMode,
        RommConnectSlot.pairCode,
        RommConnectSlot.scanQr,
        RommConnectSlot.connect,
      ]);
    });
  });

  // Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect
  // Screen Surfaces" — the D-pad follows the drawn order
  group('cycling over a chosen order', () {
    final reordered = authModeOrderFor(passwordLoginDisabled: true);

    test('over the declared order the In variants match the plain ones', () {
      for (final mode in RommAuthMode.values) {
        expect(mode.nextIn(RommAuthMode.values), mode.next, reason: '$mode');
        expect(
          mode.toLeftIn(RommAuthMode.values),
          mode.toLeft,
          reason: '$mode',
        );
        expect(
          mode.toRightIn(RommAuthMode.values),
          mode.toRight,
          reason: '$mode',
        );
      }
    });

    test('A walks the reordered switch left to right and wraps', () {
      expect(RommAuthMode.pairCode.nextIn(reordered), RommAuthMode.apiKey);
      expect(RommAuthMode.apiKey.nextIn(reordered), RommAuthMode.password);
      expect(RommAuthMode.password.nextIn(reordered), RommAuthMode.pairCode);
    });

    test('Right stops at the password segment, now rightmost', () {
      expect(RommAuthMode.pairCode.toRightIn(reordered), RommAuthMode.apiKey);
      expect(RommAuthMode.apiKey.toRightIn(reordered), RommAuthMode.password);
      expect(RommAuthMode.password.toRightIn(reordered), RommAuthMode.password);
    });

    test('Left stops at the pairing segment, now leftmost', () {
      expect(RommAuthMode.password.toLeftIn(reordered), RommAuthMode.apiKey);
      expect(RommAuthMode.apiKey.toLeftIn(reordered), RommAuthMode.pairCode);
      expect(RommAuthMode.pairCode.toLeftIn(reordered), RommAuthMode.pairCode);
    });

    test('three presses of A visit every mode once in either order', () {
      for (final disabled in [false, true]) {
        final order = authModeOrderFor(passwordLoginDisabled: disabled);
        var mode = order.first;
        final seen = <RommAuthMode>[];
        for (var i = 0; i < order.length; i++) {
          seen.add(mode);
          mode = mode.nextIn(order);
        }
        expect(seen, order, reason: '$disabled');
        expect(mode, order.first, reason: '$disabled wraps');
      }
    });
  });

  group('focusOrderFor', () {
    test('password mode: url, switch, username, password, connect', () {
      expect(focusOrderFor(RommAuthMode.password), const [
        RommConnectSlot.url,
        RommConnectSlot.authMode,
        RommConnectSlot.username,
        RommConnectSlot.password,
        RommConnectSlot.connect,
      ]);
    });

    test('API-key mode: url, switch, API key, connect', () {
      expect(focusOrderFor(RommAuthMode.apiKey), const [
        RommConnectSlot.url,
        RommConnectSlot.authMode,
        RommConnectSlot.apiKey,
        RommConnectSlot.connect,
      ]);
    });

    test('pairing mode: url, switch, code, connect', () {
      expect(focusOrderFor(RommAuthMode.pairCode), const [
        RommConnectSlot.url,
        RommConnectSlot.authMode,
        RommConnectSlot.pairCode,
        RommConnectSlot.connect,
      ]);
    });

    test('every mode starts on the URL, keeps the switch at slot 1, and ends '
        'on connect', () {
      for (final mode in RommAuthMode.values) {
        for (final scan in [false, true]) {
          final order = focusOrderFor(mode, includeScanQr: scan);
          expect(order.first, RommConnectSlot.url, reason: '$mode scan=$scan');
          expect(
            order[1],
            RommConnectSlot.authMode,
            reason: '$mode scan=$scan',
          );
          expect(
            order.last,
            RommConnectSlot.connect,
            reason: '$mode scan=$scan',
          );
          expect(
            order.toSet().length,
            order.length,
            reason: '$mode scan=$scan repeats',
          );
        }
      }
    });
  });

  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A
  // Camera Exists"
  group('focusOrderFor with the scan action', () {
    test('pairing mode puts scan between the code field and connect', () {
      expect(focusOrderFor(RommAuthMode.pairCode, includeScanQr: true), const [
        RommConnectSlot.url,
        RommConnectSlot.authMode,
        RommConnectSlot.pairCode,
        RommConnectSlot.scanQr,
        RommConnectSlot.connect,
      ]);
    });

    test('pairing mode without a camera has no scan slot', () {
      expect(
        focusOrderFor(RommAuthMode.pairCode, includeScanQr: false),
        isNot(contains(RommConnectSlot.scanQr)),
      );
      expect(
        focusOrderFor(RommAuthMode.pairCode),
        focusOrderFor(RommAuthMode.pairCode, includeScanQr: false),
      );
    });

    test('the scan action never appears outside pairing mode', () {
      expect(
        focusOrderFor(RommAuthMode.password, includeScanQr: true),
        focusOrderFor(RommAuthMode.password),
      );
      expect(
        focusOrderFor(RommAuthMode.apiKey, includeScanQr: true),
        focusOrderFor(RommAuthMode.apiKey),
      );
    });

    test('the switch keeps its index whether or not scan is offered', () {
      for (final mode in RommAuthMode.values) {
        expect(
          focusOrderFor(
            mode,
            includeScanQr: true,
          ).indexOf(RommConnectSlot.authMode),
          focusOrderFor(mode).indexOf(RommConnectSlot.authMode),
          reason: '$mode',
        );
      }
    });
  });
}
