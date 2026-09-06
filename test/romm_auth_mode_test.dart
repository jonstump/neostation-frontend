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
        final order = focusOrderFor(mode);
        expect(order.first, RommConnectSlot.url, reason: '$mode');
        expect(order[1], RommConnectSlot.authMode, reason: '$mode');
        expect(order.last, RommConnectSlot.connect, reason: '$mode');
        expect(order.toSet().length, order.length, reason: '$mode repeats');
      }
    });
  });
}
