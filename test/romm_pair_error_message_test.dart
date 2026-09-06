import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/romm_pair_error_message.dart';

/// The connect screen's pairing-failure wording as a pure function of the
/// exception's sentinel: each pairing kind maps to its own `AppLocale` key,
/// anything else falls back to the provider's message, and every new key
/// resolves in all twelve languages with its placeholders intact.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Error Handling
/// Standards", REQ "Localized User-Facing Text"

const _allLanguages = {
  'en': AppLocale.en,
  'es': AppLocale.es,
  'ru': AppLocale.ru,
  'zh': AppLocale.zh,
  'zh_Hant': AppLocale.zhHant,
  'pt': AppLocale.pt,
  'fr': AppLocale.fr,
  'de': AppLocale.de,
  'it': AppLocale.it,
  'id': AppLocale.id,
  'ja': AppLocale.ja,
  'ko': AppLocale.ko,
};

void main() {
  group('rommPairErrorKey', () {
    test('each pairing kind has its own key', () {
      expect(
        rommPairErrorKey(RommErrorKind.pairCodeInvalid),
        AppLocale.rommPairCodeInvalid,
      );
      expect(
        rommPairErrorKey(RommErrorKind.pairCodeExpired),
        AppLocale.rommPairCodeExpired,
      );
      expect(
        rommPairErrorKey(RommErrorKind.pairRateLimited),
        AppLocale.rommPairRateLimited,
      );
    });

    test('the three pairing keys are distinct', () {
      final keys = {
        for (final kind in [
          RommErrorKind.pairCodeInvalid,
          RommErrorKind.pairCodeExpired,
          RommErrorKind.pairRateLimited,
        ])
          rommPairErrorKey(kind),
      };
      expect(keys.length, 3);
    });

    test('other and null defer to the returned message', () {
      expect(rommPairErrorKey(RommErrorKind.other), isNull);
      expect(rommPairErrorKey(null), isNull);
    });

    test('every kind is decided', () {
      for (final kind in RommErrorKind.values) {
        expect(() => rommPairErrorKey(kind), returnsNormally, reason: '$kind');
      }
    });
  });

  group('pairing-mode strings', () {
    const keys = {
      AppLocale.rommAuthModePairCode,
      AppLocale.rommPairCodeLabel,
      AppLocale.rommPairCodePlaceholder,
      AppLocale.rommPairCodeHint,
      AppLocale.rommPairCodeInvalidLength,
      AppLocale.rommPairCodeInvalid,
      AppLocale.rommPairCodeExpired,
      AppLocale.rommPairRateLimited,
      AppLocale.rommPairedTokenExpires,
      AppLocale.rommPairedTokenName,
    };

    test('every key resolves in every language', () {
      expect(_allLanguages.length, 12);
      for (final entry in _allLanguages.entries) {
        for (final key in keys) {
          expect(
            entry.value[key],
            isA<String>().having((s) => s.trim().isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
        }
      }
    });

    test('the token lines keep their placeholders in every language', () {
      for (final entry in _allLanguages.entries) {
        expect(
          entry.value[AppLocale.rommPairedTokenExpires],
          contains('{date}'),
          reason: entry.key,
        );
        expect(
          entry.value[AppLocale.rommPairedTokenName],
          contains('{name}'),
          reason: entry.key,
        );
      }
    });

    test('the error sentences carry no placeholder', () {
      for (final entry in _allLanguages.entries) {
        for (final key in [
          AppLocale.rommPairCodeInvalid,
          AppLocale.rommPairCodeExpired,
          AppLocale.rommPairRateLimited,
          AppLocale.rommPairCodeInvalidLength,
        ]) {
          expect(
            entry.value[key],
            isNot(contains('{')),
            reason: '$key in ${entry.key}',
          );
        }
      }
    });
  });

  group('rommTokenExpiryDate', () {
    test('formats yyyy-MM-dd in local time with zero padding', () {
      final local = DateTime(2027, 3, 4, 5, 6, 7);
      expect(rommTokenExpiryDate(local), '2027-03-04');
      expect(rommTokenExpiryDate(DateTime(2026, 12, 25)), '2026-12-25');
    });

    test('a UTC instant is shown as the local calendar day', () {
      final utc = DateTime.utc(2027, 3, 4, 12);
      expect(rommTokenExpiryDate(utc), rommTokenExpiryDate(utc.toLocal()));
    });
  });
}
