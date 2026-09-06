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
  RommAuthMode get next => values[(index + 1) % values.length];

  /// The segment to the left, or this one when already leftmost. A segmented
  /// control reads as positions rather than a ring, so stepping stops at the
  /// ends and the caller can stay silent on a refused move.
  RommAuthMode get toLeft => index == 0 ? this : values[index - 1];

  /// The segment to the right, or this one when already rightmost. Two
  /// presses of Right from [password] land on [pairCode].
  RommAuthMode get toRight =>
      index == values.length - 1 ? this : values[index + 1];
}

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

  /// The pairing-code field. The QR-scan action of the scanner story slots
  /// in after it and before [connect] in the [RommAuthMode.pairCode] order.
  pairCode,

  /// The connect button, always last.
  connect,
}

/// The cursor order for [mode]: the URL, the switch, that mode's secret
/// field(s), and connect. The switch keeps the same index in every mode so
/// changing modes never moves the cursor off it.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
List<RommConnectSlot> focusOrderFor(RommAuthMode mode) {
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
    RommAuthMode.pairCode => const [
      RommConnectSlot.url,
      RommConnectSlot.authMode,
      RommConnectSlot.pairCode,
      RommConnectSlot.connect,
    ],
  };
}
