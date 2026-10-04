import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/gamepad_action.dart';
import 'package:neostation/utils/gamepad_binding.dart';
import 'package:neostation/utils/gamepad_translator.dart';

/// The default binding table the navigator and the glyph service will both
/// read (SPEC-0022 REQ "Binding Comes From The Navigator").
///
/// The completeness, uniqueness and composite tests iterate `GamepadAction.values`
/// rather than naming actions, so an enum value added later without a table
/// entry fails them.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Binding Comes From The Navigator"
void main() {
  group('default binding', () {
    test('quoted spec scenario: confirm is A, back is B when no user map', () {
      expect(GamepadBinding.defaults.inputsFor(GamepadAction.confirm), [
        GamepadInputType.buttonA,
      ]);
      expect(GamepadBinding.defaults.inputsFor(GamepadAction.back), [
        GamepadInputType.buttonB,
      ]);
    });

    test('every action has a non-empty entry', () {
      for (final action in GamepadAction.values) {
        expect(
          GamepadBinding.defaults.inputsFor(action),
          isNotEmpty,
          reason: '${action.name} has no entry in GamepadBinding.defaults',
        );
      }
    });

    test('no action resolves to unknown', () {
      for (final action in GamepadAction.values) {
        expect(
          GamepadBinding.defaults.inputsFor(action),
          isNot(contains(GamepadInputType.unknown)),
          reason: '${action.name} resolves to the unknown input type',
        );
      }
    });

    test('the ten single-button actions map one input each, all distinct', () {
      const singles = [
        GamepadAction.confirm,
        GamepadAction.back,
        GamepadAction.context,
        GamepadAction.favourite,
        GamepadAction.previousTab,
        GamepadAction.nextTab,
        GamepadAction.leftTrigger,
        GamepadAction.rightTrigger,
        GamepadAction.modifier,
        GamepadAction.start,
      ];

      final seen = <GamepadInputType>{};
      for (final action in singles) {
        final inputs = GamepadBinding.defaults.inputsFor(action);
        expect(
          inputs,
          hasLength(1),
          reason: '${action.name} is a single-button action',
        );
        final input = inputs.single;
        expect(
          seen.add(input),
          isTrue,
          reason: '$input is already bound to another single-button action',
        );
      }
    });

    test('the composite actions bind their parts', () {
      expect(GamepadBinding.defaults.inputsFor(GamepadAction.dpad), [
        GamepadInputType.dpadUp,
        GamepadInputType.dpadDown,
        GamepadInputType.dpadLeft,
        GamepadInputType.dpadRight,
      ]);
      expect(GamepadBinding.defaults.inputsFor(GamepadAction.leftStick), [
        GamepadInputType.leftStickX,
        GamepadInputType.leftStickY,
      ]);
      expect(GamepadBinding.defaults.inputsFor(GamepadAction.rightStick), [
        GamepadInputType.rightStickX,
        GamepadInputType.rightStickY,
      ]);
    });

    test('a binding with an empty table answers empty, never throws', () {
      const empty = GamepadBinding({});
      for (final action in GamepadAction.values) {
        expect(empty.inputsFor(action), isEmpty, reason: action.name);
      }
    });

    test('the enum has exactly the 17 spec values in spec order', () {
      expect(GamepadAction.values.map((a) => a.name), [
        'confirm',
        'back',
        'context',
        'favourite',
        'previousTab',
        'nextTab',
        'leftTrigger',
        'rightTrigger',
        'modifier',
        'start',
        'dpad',
        'dpadUp',
        'dpadDown',
        'dpadLeft',
        'dpadRight',
        'leftStick',
        'rightStick',
      ]);
    });
  });
}
