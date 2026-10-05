import 'package:flutter/foundation.dart';

import '../../utils/gamepad_action.dart';
import '../../utils/gamepad_binding.dart';
import '../logger_service.dart';
import 'glyph_style.dart';

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Styles"

/// What resolving an action produced.
///
/// Exactly one of [assetPath] and [slot] is non-null: an asset glyph, or a
/// drawn positional slot. [style] is the style whose glyph is actually drawn
/// — `xbox` whenever a fallback happened — and [fellBack] says so. [name] is
/// ALWAYS the active style's spoken name for the action, even when the drawn
/// glyph fell back (SPEC-0022 REQ "Text Follows The Style").
@immutable
class GlyphResolution {
  const GlyphResolution({
    this.assetPath,
    this.slot,
    required this.name,
    required this.style,
    required this.fellBack,
  }) : assert(
         (assetPath == null) != (slot == null),
         'exactly one of assetPath and slot must be set',
       );

  /// The asset to draw, under `assets/images/gamepad/`, or null when the
  /// glyph is a drawn slot.
  final String? assetPath;

  /// The diamond position to light, or null when the glyph is an asset.
  final GlyphSlot? slot;

  /// The active style's spoken name for the action (e.g. "Cross" on
  /// PlayStation), for text interpolation later.
  final String name;

  /// The style whose glyph is actually drawn; `xbox` after a fallback.
  final GlyphStyle style;

  /// Whether the active style had no glyph and Xbox was drawn instead.
  final bool fellBack;

  @override
  String toString() =>
      'GlyphResolution(asset: $assetPath, slot: $slot, name: $name, '
      'style: $style, fellBack: $fellBack)';
}

// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Binding Comes From The Navigator"

/// Resolves a [GamepadAction] to a glyph and a spoken name for the active
/// style, and tells listeners when the style changes.
///
/// Synchronous by contract (SPEC-0022 REQ "Concurrency Safety"): [resolve]
/// does no I/O, never awaits and never throws — every table below is a
/// `static const` map loaded with the class.
///
/// The [binding] held by the service is the shared table from slice 1; this
/// service does not dispatch with it. The one exception the spec requires:
/// [resolve] checks `binding.inputsFor(action)` and treats an empty answer as
/// an *unmapped* action, which falls back to Xbox with its own one-time
/// warning — an action the navigator cannot produce must not draw a hint.
///
/// Xbox assets are the shipped set (the only one in the repo today). The
/// Nintendo and PlayStation asset tables are empty until #275 lands, so every
/// action under those styles falls back to Xbox — that is SPEC-0022's
/// "Missing asset" scenario, warned once per (style, action) pair for the
/// lifetime of the service instance.
class GlyphService extends ChangeNotifier {
  GlyphService({
    this.binding = GamepadBinding.defaults,
    GlyphStyle detected = GlyphStyle.xbox,
    GlyphStyle? pinned,
    void Function(String message)? onWarning,
  }) : _detected = detected,
       _pinned = pinned,
       _onWarning =
           onWarning ?? ((message) => LoggerService.instance.w(message));

  /// The app-wide instance.
  static final GlyphService instance = GlyphService();

  /// The shared binding table (slice 1); read only for the unmapped guard.
  final GamepadBinding binding;

  GlyphStyle _detected;
  GlyphStyle? _pinned;
  final void Function(String message) _onWarning;

  /// Keys already warned, so a missing glyph warns once per (style, action)
  /// for the lifetime of this instance.
  final Set<String> _warned = {};

  /// The style the detector picked for the connected pad.
  GlyphStyle get detected => _detected;

  /// The user's pin, or null when the style follows detection.
  GlyphStyle? get pinned => _pinned;

  /// The style hints are drawn with: the pin when there is one, else the
  /// detected style.
  GlyphStyle get activeStyle => _pinned ?? _detected;

  /// Pins a style (or clears the pin with null). Notifies only on change.
  void setPinned(GlyphStyle? style) {
    if (_pinned == style) return;
    _pinned = style;
    notifyListeners();
  }

  /// Records what the detector picked for the connected pad. Notifies only on
  /// change.
  void setDetected(GlyphStyle style) {
    if (_detected == style) return;
    _detected = style;
    notifyListeners();
  }

  /// Resolves [action] for the active style. Synchronous, no I/O, never
  /// throws; falls back to the Xbox glyph with a one-time warning when the
  /// active style has no glyph for the action or the action is unmapped.
  GlyphResolution resolve(GamepadAction action) {
    // An action the navigator cannot produce must not draw a hint: treat it
    // as unmapped and fall back with a warning (once per action).
    if (binding.inputsFor(action).isEmpty) {
      _warnOnce(
        'unmapped:${action.name}',
        'GlyphService: action "${action.name}" is not in the binding table; '
            'using the Xbox glyph',
      );
      return _xboxResolution(action);
    }

    final style = activeStyle;
    final slot = _positionalSlots[action];
    if (style == GlyphStyle.positional && slot != null) {
      return GlyphResolution(
        slot: slot,
        name: _names[GlyphStyle.positional]![action]!,
        style: GlyphStyle.positional,
        fellBack: false,
      );
    }

    // The positional style resolves by slot, not by asset, so it has no
    // entry in _assets: every non-face action under it falls back below.
    final assetPath = _assets[style]?[action];
    if (assetPath != null) {
      return GlyphResolution(
        assetPath: assetPath,
        name: _names[style]![action]!,
        style: style,
        fellBack: false,
      );
    }

    _warnOnce(
      '${style.name}:${action.name}',
      'GlyphService: style "${style.name}" has no glyph for action '
          '"${action.name}"; using the Xbox glyph',
    );
    return _xboxResolution(action);
  }

  /// The active style's spoken name for [action].
  String nameFor(GamepadAction action) => _names[activeStyle]![action]!;

  /// The Xbox glyph for [action]; the name stays the active style's.
  GlyphResolution _xboxResolution(GamepadAction action) => GlyphResolution(
    assetPath: _xboxAssets[action],
    name: _names[activeStyle]![action]!,
    style: GlyphStyle.xbox,
    fellBack: true,
  );

  void _warnOnce(String key, String message) {
    if (!_warned.add(key)) return;
    _onWarning(message);
  }

  /// Xbox asset paths, the shipped set. This file is the ONLY place that may
  /// name `assets/images/gamepad/`
  /// (SPEC-0022 REQ "Actions Not Buttons").
  static const Map<GamepadAction, String> _xboxAssets = {
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

  /// Nintendo asset paths — filled by #275 (the asset sets). Until then
  /// every action under this style falls back to Xbox with a one-time
  /// warning (SPEC-0022 "Missing asset").
  static const Map<GamepadAction, String> _nintendoAssets = {};

  /// PlayStation asset paths — filled by #275 (the asset sets). Until then
  /// every action under this style falls back to Xbox with a one-time
  /// warning (SPEC-0022 "Missing asset").
  static const Map<GamepadAction, String> _playstationAssets = {};

  /// Per style: asset paths. The positional style resolves by slot, not by
  /// asset, so it has no entry here.
  static const Map<GlyphStyle, Map<GamepadAction, String>> _assets = {
    GlyphStyle.xbox: _xboxAssets,
    GlyphStyle.nintendo: _nintendoAssets,
    GlyphStyle.playstation: _playstationAssets,
  };

  /// The positional diamond's lit slot per face action, using the Nintendo
  /// layout (A right, B bottom, X top, Y left) — what SPEC-0022's
  /// "Positional" scenario requires: "back" lights the BOTTOM position.
  /// Every non-face action under positional has no glyph and falls back.
  static const Map<GamepadAction, GlyphSlot> _positionalSlots = {
    GamepadAction.confirm: GlyphSlot.right,
    GamepadAction.back: GlyphSlot.bottom,
    GamepadAction.context: GlyphSlot.top,
    GamepadAction.favourite: GlyphSlot.left,
  };

  /// Spoken names per style, all 17 actions in each. English identifiers for
  /// later text interpolation (SPEC-0022 REQ "Text Follows The Style");
  /// localizing them belongs to the slice that wires them into text.
  static const Map<GlyphStyle, Map<GamepadAction, String>> _names = {
    GlyphStyle.xbox: {
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
    },
    GlyphStyle.nintendo: {
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
    },
    GlyphStyle.playstation: {
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
    },
    GlyphStyle.positional: {
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
    },
  };
}
