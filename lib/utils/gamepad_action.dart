// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Actions Not Buttons"

/// What a UI hint means, as opposed to which physical button does it.
///
/// Screens know what they *do*; the glyph service and the navigator look up
/// which input type carries each action today. The doc comment on each value
/// names the physical button it is bound to in `GamepadBinding.defaults` —
/// the binding, not this enum, is what a user map will change later
/// (ADR-0025).
enum GamepadAction {
  /// The A button today: the primary action.
  confirm,

  /// The B button today: back and cancel.
  back,

  /// The X button today: a contextual action.
  context,

  /// The Y button today: favourite.
  favourite,

  /// The LB bumper today: previous tab.
  previousTab,

  /// The RB bumper today: next tab.
  nextTab,

  /// The LT trigger today.
  leftTrigger,

  /// The RT trigger today.
  rightTrigger,

  /// The Select button today: held as a chord modifier.
  modifier,

  /// The Start button today: open settings.
  start,

  /// The D-pad as a whole (all four directions).
  dpad,

  /// The D-pad's up direction.
  dpadUp,

  /// The D-pad's down direction.
  dpadDown,

  /// The D-pad's left direction.
  dpadLeft,

  /// The D-pad's right direction.
  dpadRight,

  /// The left stick as a whole (both axes).
  leftStick,

  /// The right stick as a whole (both axes).
  rightStick,
}
