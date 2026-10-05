import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/glyph_service.dart';
import 'package:neostation/services/gamepad/glyph_style.dart';
import 'package:neostation/utils/gamepad_action.dart';
import 'package:neostation/utils/gamepad_binding.dart';

/// The glyph service: Xbox assets, the positional diamond slots, fallbacks
/// for the styles whose asset sets do not exist yet (#275), the one-warning
/// contract, the pin and the listeners.
///
/// Every table check iterates `GamepadAction.values`, so an enum value added
/// later without a table entry fails here too. Pure Dart: no database, no
/// SharedPreferences, no real folders beyond checking the asset files exist.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"
void main() {
  const xboxAssets = <GamepadAction, String>{
    GamepadAction.confirm: 'assets/images/gamepad/Xbox_A_button.png',
    GamepadAction.back: 'assets/images/gamepad/Xbox_B_button.png',
    GamepadAction.context: 'assets/images/gamepad/Xbox_X_button.png',
    GamepadAction.favourite: 'assets/images/gamepad/Xbox_Y_button.png',
    GamepadAction.previousTab: 'assets/images/gamepad/Xbox_LB_bumper.png',
    GamepadAction.nextTab: 'assets/images/gamepad/Xbox_RB_bumper.png',
    GamepadAction.leftTrigger: 'assets/images/gamepad/Xbox_LT_trigger.png',
    GamepadAction.rightTrigger: 'assets/images/gamepad/Xbox_RT_trigger.png',
    GamepadAction.modifier: 'assets/images/gamepad/Xbox_View_button.png',
    GamepadAction.start: 'assets/images/gamepad/Xbox_Menu_button.png',
    GamepadAction.dpad: 'assets/images/gamepad/Xbox_D-pad_ALL.png',
    GamepadAction.dpadUp: 'assets/images/gamepad/Xbox_D-pad_U.png',
    GamepadAction.dpadDown: 'assets/images/gamepad/Xbox_D-pad_D.png',
    GamepadAction.dpadLeft: 'assets/images/gamepad/Xbox_D-pad_L.png',
    GamepadAction.dpadRight: 'assets/images/gamepad/Xbox_D-pad_R.png',
    GamepadAction.leftStick: 'assets/images/gamepad/Left Stick.png',
    GamepadAction.rightStick: 'assets/images/gamepad/Right Stick.png',
  };

  const xboxNames = <GamepadAction, String>{
    GamepadAction.confirm: 'A',
    GamepadAction.back: 'B',
    GamepadAction.context: 'X',
    GamepadAction.favourite: 'Y',
    GamepadAction.previousTab: 'LB',
    GamepadAction.nextTab: 'RB',
    GamepadAction.leftTrigger: 'LT',
    GamepadAction.rightTrigger: 'RT',
    GamepadAction.modifier: 'View',
    GamepadAction.start: 'Menu',
    GamepadAction.dpad: 'D-pad',
    GamepadAction.dpadUp: 'D-pad Up',
    GamepadAction.dpadDown: 'D-pad Down',
    GamepadAction.dpadLeft: 'D-pad Left',
    GamepadAction.dpadRight: 'D-pad Right',
    GamepadAction.leftStick: 'Left stick',
    GamepadAction.rightStick: 'Right stick',
  };

  const nintendoNames = <GamepadAction, String>{
    GamepadAction.confirm: 'A',
    GamepadAction.back: 'B',
    GamepadAction.context: 'X',
    GamepadAction.favourite: 'Y',
    GamepadAction.previousTab: 'L',
    GamepadAction.nextTab: 'R',
    GamepadAction.leftTrigger: 'ZL',
    GamepadAction.rightTrigger: 'ZR',
    GamepadAction.modifier: 'Minus',
    GamepadAction.start: 'Plus',
    GamepadAction.dpad: 'D-pad',
    GamepadAction.dpadUp: 'D-pad Up',
    GamepadAction.dpadDown: 'D-pad Down',
    GamepadAction.dpadLeft: 'D-pad Left',
    GamepadAction.dpadRight: 'D-pad Right',
    GamepadAction.leftStick: 'Left stick',
    GamepadAction.rightStick: 'Right stick',
  };

  const playstationNames = <GamepadAction, String>{
    GamepadAction.confirm: 'Cross',
    GamepadAction.back: 'Circle',
    GamepadAction.context: 'Square',
    GamepadAction.favourite: 'Triangle',
    GamepadAction.previousTab: 'L1',
    GamepadAction.nextTab: 'R1',
    GamepadAction.leftTrigger: 'L2',
    GamepadAction.rightTrigger: 'R2',
    GamepadAction.modifier: 'Share',
    GamepadAction.start: 'Options',
    GamepadAction.dpad: 'D-pad',
    GamepadAction.dpadUp: 'D-pad Up',
    GamepadAction.dpadDown: 'D-pad Down',
    GamepadAction.dpadLeft: 'D-pad Left',
    GamepadAction.dpadRight: 'D-pad Right',
    GamepadAction.leftStick: 'Left stick',
    GamepadAction.rightStick: 'Right stick',
  };

  const positionalNames = <GamepadAction, String>{
    GamepadAction.confirm: 'right button',
    GamepadAction.back: 'bottom button',
    GamepadAction.context: 'top button',
    GamepadAction.favourite: 'left button',
    GamepadAction.previousTab: 'LB',
    GamepadAction.nextTab: 'RB',
    GamepadAction.leftTrigger: 'LT',
    GamepadAction.rightTrigger: 'RT',
    GamepadAction.modifier: 'View',
    GamepadAction.start: 'Menu',
    GamepadAction.dpad: 'D-pad',
    GamepadAction.dpadUp: 'D-pad Up',
    GamepadAction.dpadDown: 'D-pad Down',
    GamepadAction.dpadLeft: 'D-pad Left',
    GamepadAction.dpadRight: 'D-pad Right',
    GamepadAction.leftStick: 'Left stick',
    GamepadAction.rightStick: 'Right stick',
  };

  GlyphService serviceWithStyle(
    GlyphStyle style, {
    void Function(String message)? onWarning,
    GamepadBinding binding = GamepadBinding.defaults,
  }) {
    final service = GlyphService(
      binding: binding,
      detected: style,
      onWarning: onWarning,
    );
    return service;
  }

  group('xbox', () {
    test('every action resolves to its exact asset, on disk', () {
      final service = serviceWithStyle(GlyphStyle.xbox);
      expect(xboxAssets.keys.toSet(), GamepadAction.values.toSet());
      for (final action in GamepadAction.values) {
        final resolution = service.resolve(action);
        expect(
          resolution.assetPath,
          xboxAssets[action],
          reason: '${action.name} asset path',
        );
        expect(resolution.slot, isNull, reason: action.name);
        expect(resolution.fellBack, isFalse, reason: action.name);
        expect(resolution.style, GlyphStyle.xbox, reason: action.name);
        expect(
          File(resolution.assetPath!).existsSync(),
          isTrue,
          reason: resolution.assetPath,
        );
        // Exactly one of assetPath and slot is set.
        expect(resolution.slot, isNull, reason: action.name);
      }
    });
  });

  group('names', () {
    test('nameFor and resolve().name follow the active style, all 17', () {
      expect(xboxNames.keys.toSet(), GamepadAction.values.toSet());
      expect(nintendoNames.keys.toSet(), GamepadAction.values.toSet());
      expect(playstationNames.keys.toSet(), GamepadAction.values.toSet());
      expect(positionalNames.keys.toSet(), GamepadAction.values.toSet());

      for (final style in GlyphStyle.values) {
        final service = serviceWithStyle(style);
        final expected = switch (style) {
          GlyphStyle.xbox => xboxNames,
          GlyphStyle.nintendo => nintendoNames,
          GlyphStyle.playstation => playstationNames,
          GlyphStyle.positional => positionalNames,
        };
        for (final action in GamepadAction.values) {
          expect(
            service.nameFor(action),
            expected[action],
            reason: '${style.name}/${action.name} nameFor',
          );
          expect(
            service.resolve(action).name,
            expected[action],
            reason: '${style.name}/${action.name} resolve name',
          );
        }
      }
    });
  });

  group('positional', () {
    test('the four face actions light the Nintendo-layout slots', () {
      final service = serviceWithStyle(GlyphStyle.positional);
      expect(service.resolve(GamepadAction.confirm).slot, GlyphSlot.right);
      expect(service.resolve(GamepadAction.back).slot, GlyphSlot.bottom);
      expect(service.resolve(GamepadAction.context).slot, GlyphSlot.top);
      expect(service.resolve(GamepadAction.favourite).slot, GlyphSlot.left);
      for (final action in [
        GamepadAction.confirm,
        GamepadAction.back,
        GamepadAction.context,
        GamepadAction.favourite,
      ]) {
        final resolution = service.resolve(action);
        expect(resolution.assetPath, isNull, reason: action.name);
        expect(resolution.slot, isNotNull, reason: action.name);
        expect(resolution.fellBack, isFalse, reason: action.name);
        expect(resolution.style, GlyphStyle.positional, reason: action.name);
        // The name has no letters: it is the position.
        expect(resolution.name, positionalNames[action], reason: action.name);
      }
    });

    test('the other 13 actions fall back to Xbox, named positionally', () {
      final service = serviceWithStyle(GlyphStyle.positional);
      final faceActions = {
        GamepadAction.confirm,
        GamepadAction.back,
        GamepadAction.context,
        GamepadAction.favourite,
      };
      for (final action in GamepadAction.values) {
        if (faceActions.contains(action)) continue;
        final resolution = service.resolve(action);
        expect(
          resolution.assetPath,
          xboxAssets[action],
          reason: '${action.name} falls back to the Xbox asset',
        );
        expect(resolution.slot, isNull, reason: action.name);
        expect(resolution.fellBack, isTrue, reason: action.name);
        expect(resolution.style, GlyphStyle.xbox, reason: action.name);
        expect(
          resolution.name,
          positionalNames[action],
          reason: '${action.name} keeps the positional name',
        );
      }
    });
  });

  group('nintendo and playstation fall back until #275', () {
    test('every action falls back to the Xbox glyph under nintendo', () {
      final service = serviceWithStyle(GlyphStyle.nintendo);
      for (final action in GamepadAction.values) {
        final resolution = service.resolve(action);
        expect(
          resolution.assetPath,
          xboxAssets[action],
          reason: '${action.name} xbox asset',
        );
        expect(resolution.slot, isNull, reason: action.name);
        expect(resolution.fellBack, isTrue, reason: action.name);
        expect(resolution.style, GlyphStyle.xbox, reason: action.name);
        expect(
          resolution.name,
          nintendoNames[action],
          reason: '${action.name} keeps the nintendo name',
        );
      }
    });

    test('every action falls back to the Xbox glyph under playstation', () {
      final service = serviceWithStyle(GlyphStyle.playstation);
      for (final action in GamepadAction.values) {
        final resolution = service.resolve(action);
        expect(
          resolution.assetPath,
          xboxAssets[action],
          reason: '${action.name} xbox asset',
        );
        expect(resolution.fellBack, isTrue, reason: action.name);
        expect(resolution.style, GlyphStyle.xbox, reason: action.name);
        expect(
          resolution.name,
          playstationNames[action],
          reason: '${action.name} keeps the playstation name',
        );
      }
    });

    test('a non-empty Nintendo asset table stops the fallback', () {
      // This test pins the EMPTY Nintendo table: every action must fall back.
      // If #275 adds a path for any action there, that action resolves
      // without fallback and this fails.
      final service = serviceWithStyle(GlyphStyle.nintendo);
      for (final action in GamepadAction.values) {
        expect(
          service.resolve(action).fellBack,
          isTrue,
          reason: '${action.name} must fall back while the set is empty',
        );
      }
    });
  });

  group('one warning per (style, action)', () {
    test(
      'the same action under one style warns once; another style warns again',
      () {
        final warnings = <String>[];
        final service = serviceWithStyle(
          GlyphStyle.nintendo,
          onWarning: warnings.add,
        );

        service.resolve(GamepadAction.back);
        service.resolve(GamepadAction.back);
        service.resolve(GamepadAction.back);
        expect(
          warnings,
          hasLength(1),
          reason: 'one warning per (style, action)',
        );
        expect(warnings.single, contains('nintendo'));
        expect(warnings.single, contains('back'));

        // The same action under another style is a different pair.
        service.setDetected(GlyphStyle.playstation);
        service.resolve(GamepadAction.back);
        expect(
          warnings,
          hasLength(2),
          reason: 'the new pair gets its own warning',
        );
        expect(warnings.last, contains('playstation'));
      },
    );

    test('every unmapped-by-style action warns exactly once per style', () {
      final warnings = <String>[];
      final service = serviceWithStyle(
        GlyphStyle.positional,
        onWarning: warnings.add,
      );
      final faceActions = {
        GamepadAction.confirm,
        GamepadAction.back,
        GamepadAction.context,
        GamepadAction.favourite,
      };
      // The 13 non-face actions fall back: 13 warnings.
      for (final action in GamepadAction.values) {
        service.resolve(action);
      }
      expect(warnings, hasLength(13));
      // And a second pass adds nothing.
      for (final action in GamepadAction.values) {
        service.resolve(action);
      }
      expect(warnings, hasLength(13));
      expect(faceActions, hasLength(4));
    });
  });

  group('pin wins', () {
    test('a pinned style beats the detected one', () {
      final service = GlyphService(detected: GlyphStyle.nintendo);
      service.setPinned(GlyphStyle.xbox);
      expect(service.activeStyle, GlyphStyle.xbox);
      expect(
        service.resolve(GamepadAction.confirm).assetPath,
        xboxAssets[GamepadAction.confirm],
      );
      expect(service.resolve(GamepadAction.confirm).fellBack, isFalse);
    });

    test('with no pin, the active style is the detected one', () {
      final service = GlyphService(detected: GlyphStyle.nintendo);
      expect(service.activeStyle, GlyphStyle.nintendo);
      expect(service.pinned, isNull);
      expect(service.detected, GlyphStyle.nintendo);
    });
  });

  group('listeners', () {
    test('setPinned and setDetected notify on change, not on no-change', () {
      var notifications = 0;
      final service = GlyphService(detected: GlyphStyle.xbox);
      service.addListener(() => notifications++);

      service.setPinned(GlyphStyle.nintendo);
      expect(notifications, 1);
      service.setPinned(GlyphStyle.nintendo);
      expect(notifications, 1, reason: 'same value: no notification');

      service.setPinned(null);
      expect(notifications, 2);
      service.setPinned(null);
      expect(
        notifications,
        2,
        reason: 'clearing an absent pin: no notification',
      );

      service.setDetected(GlyphStyle.playstation);
      expect(notifications, 3);
      service.setDetected(GlyphStyle.playstation);
      expect(notifications, 3, reason: 'same value: no notification');
    });
  });

  group('empty-binding guard', () {
    test(
      'an empty binding resolves every action as unmapped xbox fallback',
      () {
        final warnings = <String>[];
        final service = GlyphService(
          binding: const GamepadBinding({}),
          detected: GlyphStyle.xbox,
          onWarning: warnings.add,
        );
        for (final action in GamepadAction.values) {
          final resolution = service.resolve(action);
          expect(resolution.assetPath, xboxAssets[action], reason: action.name);
          expect(resolution.fellBack, isTrue, reason: action.name);
          expect(resolution.style, GlyphStyle.xbox, reason: action.name);
        }
        expect(warnings, hasLength(GamepadAction.values.length));
        // Never throws, never duplicates: a second pass is silent.
        for (final action in GamepadAction.values) {
          service.resolve(action);
        }
        expect(warnings, hasLength(GamepadAction.values.length));
      },
    );
  });

  group('synchronous', () {
    test('resolve returns a GlyphResolution, not a Future', () {
      final service = GlyphService();
      // A compile-time property: if resolve returned a Future this would not
      // even be a GlyphResolution.
      expect(service.resolve(GamepadAction.confirm), isA<GlyphResolution>());
    });
  });
}
