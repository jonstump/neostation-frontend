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

    test('a server too old for pairing has its own key', () {
      expect(
        rommPairErrorKey(RommErrorKind.unsupported),
        AppLocale.rommPairServerTooOld,
      );
    });

    test('the classified pairing keys are distinct', () {
      final keys = {
        for (final kind in [
          RommErrorKind.pairCodeInvalid,
          RommErrorKind.pairCodeExpired,
          RommErrorKind.pairRateLimited,
          RommErrorKind.unsupported,
        ])
          rommPairErrorKey(kind),
      };
      expect(keys.length, 4);
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
      // Governing: ADR-0010, SPEC-0010 REQ "Gated Call Sites"
      AppLocale.rommPairServerTooOld,
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
          AppLocale.rommPairServerTooOld,
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

  group('rommLocalizedErrorText', () {
    // The failures the provider words itself: it has no BuildContext, so it
    // records an AppLocale key and the widget layer resolves it. A key that
    // lost its `{error}` token in translation would swallow the exception
    // text, which is the only diagnosis a network or TLS failure leaves.
    // Governing: ADR-0007 (RomM pairing login),
    // SPEC-0007 REQ "Localized User-Facing Text"
    const detailKeys = {
      AppLocale.rommConnectionFailedDetail,
      AppLocale.rommPairingFailedDetail,
    };

    test('every language carries both keys with their placeholder', () {
      expect(_allLanguages.length, 12);
      for (final entry in _allLanguages.entries) {
        for (final key in detailKeys) {
          final value = entry.value[key];
          expect(
            value,
            isA<String>().having((s) => s.trim().isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
          expect(
            value as String,
            contains('{error}'),
            reason: '$key in ${entry.key}',
          );
        }
      }
    });

    test('substitutes the detail into every language\'s sentence', () {
      for (final entry in _allLanguages.entries) {
        final template =
            entry.value[AppLocale.rommPairingFailedDetail] as String;
        final text = const RommLocalizedError(
          AppLocale.rommPairingFailedDetail,
          detail: 'SocketException: refused',
        ).format(template);
        expect(text, contains('SocketException: refused'), reason: entry.key);
        expect(text, isNot(contains('{error}')), reason: entry.key);
      }
    });

    test('English reads as the sentence the provider used to hardcode', () {
      expect(
        const RommLocalizedError(
          AppLocale.rommPairingFailedDetail,
          detail: 'SocketException: refused',
        ).format(AppLocale.en[AppLocale.rommPairingFailedDetail] as String),
        'Pairing failed: SocketException: refused',
      );
      expect(
        const RommLocalizedError(
          AppLocale.rommConnectionFailedDetail,
          detail: 'HandshakeException',
        ).format(AppLocale.en[AppLocale.rommConnectionFailedDetail] as String),
        'Connection failed: HandshakeException',
      );
    });

    test('a sentence without a detail is shown as it is', () {
      final template = AppLocale.en[AppLocale.rommPairServerTooOld] as String;
      expect(
        const RommLocalizedError(
          AppLocale.rommPairServerTooOld,
        ).format(template),
        template,
      );
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
