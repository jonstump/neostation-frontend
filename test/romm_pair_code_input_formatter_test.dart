import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/romm_pair_code_input_formatter.dart';

/// What the pairing-code field lets through: upper-cased pairing-alphabet
/// characters plus the dash and space of RomM's `XXXX-XXXX` display, capped
/// at the 8 code characters and echoed as `XXXX-XXXX` once complete.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On
/// The Connect Screen"
void main() {
  group('RommPairCodeInputFormatter.format', () {
    test('upper-cases and keeps a partial code as typed', () {
      expect(RommPairCodeInputFormatter.format('abcd'), 'ABCD');
      expect(RommPairCodeInputFormatter.format('abcd-2'), 'ABCD-2');
      expect(RommPairCodeInputFormatter.format('ab cd'), 'AB CD');
    });

    test('drops characters outside the pairing alphabet', () {
      // 0, O, 1, I and L are not in the alphabet; punctuation never is.
      expect(RommPairCodeInputFormatter.format('a0o1il.b'), 'AB');
      expect(RommPairCodeInputFormatter.format('ab_c/d'), 'ABCD');
    });

    test('echoes the display form once all 8 characters are in', () {
      expect(RommPairCodeInputFormatter.format('abcd2345'), 'ABCD-2345');
      expect(RommPairCodeInputFormatter.format('ABCD-2345'), 'ABCD-2345');
      expect(RommPairCodeInputFormatter.format('abcd 2345'), 'ABCD-2345');
    });

    test('never holds more than 8 code characters', () {
      expect(RommPairCodeInputFormatter.format('ABCD2345XYZ'), 'ABCD-2345');
      expect(RommPairCodeInputFormatter.format('ABCD-2345-XYZ'), 'ABCD-2345');
    });

    test('caps runs of separators at the visible width', () {
      final text = RommPairCodeInputFormatter.format('A${' ' * 20}');
      expect(text.length, RommPairCodeInputFormatter.maxVisibleLength);
    });
  });

  group('RommPairCodeInputFormatter.formatEditUpdate', () {
    const formatter = RommPairCodeInputFormatter();

    test('leaves an already well-formed edit untouched', () {
      const value = TextEditingValue(
        text: 'ABCD-2',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(formatter.formatEditUpdate(TextEditingValue.empty, value), value);
    });

    test('rewrites the text and parks the cursor at the end', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'abcd2345',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      expect(result.text, 'ABCD-2345');
      expect(result.selection, const TextSelection.collapsed(offset: 9));
    });
  });
}
