import 'package:flutter/services.dart';

import '../models/romm_pairing.dart';

/// Shapes what the pairing-code field will hold: upper-case, only the
/// pairing alphabet plus the `-` and space a user may type or paste from
/// RomM's `XXXX-XXXX` display, never more than the 8 code characters, and
/// echoed as [RommPairCode.display] the moment all 8 are in. Anything else
/// (lower case is folded, `0`/`O`/`1`/`I`/`L` are dropped) is refused as it
/// is typed so the form's own validation only ever sees a well-formed code.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
class RommPairCodeInputFormatter extends TextInputFormatter {
  const RommPairCodeInputFormatter();

  /// `XXXX-XXXX`: the longest text the field ever shows.
  static const int maxVisibleLength = RommPairCode.length + 1;

  static final RegExp _allowed = RegExp('[${RommPairCode.alphabet}\\- ]');

  /// The text the field should show for what the user typed. Pure so tests
  /// can cover it without a [TextEditingValue].
  static String format(String raw) {
    final kept = raw
        .toUpperCase()
        .split('')
        .where((ch) => _allowed.hasMatch(ch))
        .join();
    final normalized = RommPairCode.normalize(kept);
    if (normalized.length >= RommPairCode.length) {
      return RommPairCode.display(normalized.substring(0, RommPairCode.length));
    }
    return kept.length > maxVisibleLength
        ? kept.substring(0, maxVisibleLength)
        : kept;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = format(newValue.text);
    if (text == newValue.text) return newValue;
    // The rewrite can insert or drop characters anywhere, so the safe cursor
    // is the end of the code, which is where the next character goes.
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
