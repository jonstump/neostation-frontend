import 'gamepad_action.dart';
import 'gamepad_translator.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Binding Comes From The Navigator"

/// The navigator's default binding from [GamepadAction] to the
/// [GamepadInputType]s that carry it.
///
/// This is the one table both consumers are meant to read, so a hint and the
/// press it describes cannot disagree: the navigator dispatches its callbacks
/// from it, and the glyph service resolves hints through it. A later story
/// (ADR-0025) makes the table the user's map; until then `defaults` is the
/// navigator's own binding.
///
/// **Nothing reads this table yet** — the navigator still cases the input
/// types literally in `_handleTranslatedEvent`; wiring it in is a later slice
/// of the story, which must keep behaviour identical.
class GamepadBinding {
  const GamepadBinding(this.table);

  /// Action -> the input types that carry it.
  final Map<GamepadAction, List<GamepadInputType>> table;

  /// The navigator's own binding, before any user map exists (ADR-0025).
  static const GamepadBinding defaults = GamepadBinding({
    GamepadAction.confirm: [GamepadInputType.buttonA],
    GamepadAction.back: [GamepadInputType.buttonB],
    GamepadAction.context: [GamepadInputType.buttonX],
    GamepadAction.favourite: [GamepadInputType.buttonY],
    GamepadAction.previousTab: [GamepadInputType.buttonLB],
    GamepadAction.nextTab: [GamepadInputType.buttonRB],
    GamepadAction.leftTrigger: [GamepadInputType.buttonLT],
    GamepadAction.rightTrigger: [GamepadInputType.buttonRT],
    GamepadAction.modifier: [GamepadInputType.buttonSelect],
    GamepadAction.start: [GamepadInputType.buttonStart],
    GamepadAction.dpad: [
      GamepadInputType.dpadUp,
      GamepadInputType.dpadDown,
      GamepadInputType.dpadLeft,
      GamepadInputType.dpadRight,
    ],
    GamepadAction.dpadUp: [GamepadInputType.dpadUp],
    GamepadAction.dpadDown: [GamepadInputType.dpadDown],
    GamepadAction.dpadLeft: [GamepadInputType.dpadLeft],
    GamepadAction.dpadRight: [GamepadInputType.dpadRight],
    GamepadAction.leftStick: [
      GamepadInputType.leftStickX,
      GamepadInputType.leftStickY,
    ],
    GamepadAction.rightStick: [
      GamepadInputType.rightStickX,
      GamepadInputType.rightStickY,
    ],
  });

  /// The input types carrying [action]; empty when the table has no entry for
  /// it — an unmapped action draws no hint and never throws.
  List<GamepadInputType> inputsFor(GamepadAction action) =>
      table[action] ?? const [];
}
