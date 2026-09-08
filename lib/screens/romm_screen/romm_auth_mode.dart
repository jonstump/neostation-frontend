/// The authentication modes of the RomM connect form and the D-pad slot
/// order each one presents, kept free of widget imports so tests can drive
/// the cycling and the focus lists without building the screen.
library;

/// How the connect form proves who the user is: a username and password, a
/// pasted Client API Token, or an 8-character pairing code from RomM's
/// Client API Tokens screen. Declared in the order the switch draws its
/// segments, left to right, which is also the order Left/Right step through.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
enum RommAuthMode {
  password,
  apiKey,
  pairCode;

  /// The mode A (or a tap with no segment target) advances to: one segment
  /// to the right, wrapping from the last back to the first, so repeated
  /// presses visit every mode.
  RommAuthMode get next => nextIn(values);

  /// The segment to the left, or this one when already leftmost. A segmented
  /// control reads as positions rather than a ring, so stepping stops at the
  /// ends and the caller can stay silent on a refused move.
  RommAuthMode get toLeft => toLeftIn(values);

  /// The segment to the right, or this one when already rightmost. Two
  /// presses of Right from [password] land on [pairCode].
  RommAuthMode get toRight => toRightIn(values);

  /// [next] over [order] rather than the declared order, for a switch drawn
  /// in the order [authModeOrderFor] chose: A still walks the segments left to
  /// right as the user sees them and wraps from the last back to the first.
  // Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect Screen Surfaces",
  // ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  RommAuthMode nextIn(List<RommAuthMode> order) =>
      order[(order.indexOf(this) + 1) % order.length];

  /// [toLeft] over [order]: one segment left as drawn, stopping at the first.
  // Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect Screen Surfaces",
  // ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  RommAuthMode toLeftIn(List<RommAuthMode> order) {
    final at = order.indexOf(this);
    return at <= 0 ? this : order[at - 1];
  }

  /// [toRight] over [order]: one segment right as drawn, stopping at the last.
  // Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect Screen Surfaces",
  // ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  RommAuthMode toRightIn(List<RommAuthMode> order) {
    final at = order.indexOf(this);
    return at == order.length - 1 ? this : order[at + 1];
  }
}

/// The order the connect form draws its segments in, left to right, which is
/// also the order Left/Right and A step through and the mode a fresh form
/// opens on.
///
/// A server whose heartbeat says password login is off leads with pairing
/// (the QR scan is a row inside that mode), then the API key, and puts the
/// password segment last, where the form hangs the hint that this server has
/// disabled it. Every mode stays in the list either way: the flag reorders
/// the switch, it never removes a segment, so a user who wants the password
/// form can still reach it. With the flag unknown or false the declared
/// order stands.
// Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Connect Screen Surfaces"
List<RommAuthMode> authModeOrderFor({required bool passwordLoginDisabled}) =>
    passwordLoginDisabled
    ? const [RommAuthMode.pairCode, RommAuthMode.apiKey, RommAuthMode.password]
    : RommAuthMode.values;

/// Everything the D-pad can land on while the connect form is shown. The
/// form's live slot list is [focusOrderFor] mapped onto focus nodes; controls
/// without a text field ([authMode], [connect]) map to null there.
enum RommConnectSlot {
  /// The server URL, shared by every mode and always first.
  url,

  /// The three-segment mode switch, always directly under the URL.
  authMode,
  username,
  password,
  apiKey,

  /// The pairing-code field.
  pairCode,

  /// The "Scan QR code" action: an action row, not a field, that sits between
  /// [pairCode] and [connect] in the [RommAuthMode.pairCode] order — and only
  /// on platforms with a camera (see `showsQrScanAction`).
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
  scanQr,

  /// The connect button, always last.
  connect,
}

/// The cursor order for [mode]: the URL, the switch, that mode's secret
/// field(s), and connect. The switch keeps the same index in every mode so
/// changing modes never moves the cursor off it.
///
/// [includeScanQr] adds the [RommConnectSlot.scanQr] action after the code
/// field in pairing mode; it is the platform gate's answer, so a Windows or
/// Linux build never has a slot for a row it does not draw.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
List<RommConnectSlot> focusOrderFor(
  RommAuthMode mode, {
  bool includeScanQr = false,
}) {
  return switch (mode) {
    RommAuthMode.password => const [
      RommConnectSlot.url,
      RommConnectSlot.authMode,
      RommConnectSlot.username,
      RommConnectSlot.password,
      RommConnectSlot.connect,
    ],
    RommAuthMode.apiKey => const [
      RommConnectSlot.url,
      RommConnectSlot.authMode,
      RommConnectSlot.apiKey,
      RommConnectSlot.connect,
    ],
    // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
    RommAuthMode.pairCode => [
      RommConnectSlot.url,
      RommConnectSlot.authMode,
      RommConnectSlot.pairCode,
      if (includeScanQr) RommConnectSlot.scanQr,
      RommConnectSlot.connect,
    ],
  };
}
