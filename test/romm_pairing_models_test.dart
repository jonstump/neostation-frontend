import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_pairing.dart';

/// Pure-model tests for RomM pairing: code normalisation and validation, the
/// QR/pairing-link parser, and the exchange-response model.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Link
/// Parsing", REQ "Pairing Code Exchange"
void main() {
  group('RommPairCode', () {
    test('alphabet is the one RomM uses', () {
      expect(RommPairCode.alphabet, 'ABCDEFGHJKMNPQRSTUVWXYZ23456789');
      expect(RommPairCode.length, 8);
    });

    test('normalize strips dashes and whitespace and upper-cases', () {
      expect(RommPairCode.normalize('abcd-2345 '), 'ABCD2345');
      expect(RommPairCode.normalize(' ab cd\t23-45\n'), 'ABCD2345');
      expect(RommPairCode.normalize('ABCD2345'), 'ABCD2345');
      expect(RommPairCode.normalize(''), '');
    });

    test('isValid accepts exactly eight alphabet characters', () {
      expect(RommPairCode.isValid('ABCD2345'), isTrue);
      expect(RommPairCode.isValid('ZZZZ9999'), isTrue);
    });

    test('isValid rejects the wrong length', () {
      expect(RommPairCode.isValid('ABCD234'), isFalse, reason: '7 chars');
      expect(RommPairCode.isValid('ABCD23456'), isFalse, reason: '9 chars');
      expect(RommPairCode.isValid(''), isFalse);
    });

    test('isValid rejects characters outside the alphabet', () {
      // The ambiguous glyphs RomM leaves out.
      expect(RommPairCode.isValid('ABC1O'), isFalse);
      expect(RommPairCode.isValid('ABCD1234'), isFalse, reason: '1 not used');
      expect(RommPairCode.isValid('ABCD0234'), isFalse, reason: '0 not used');
      expect(RommPairCode.isValid('ABCDI234'), isFalse, reason: 'I not used');
      expect(RommPairCode.isValid('ABCDL234'), isFalse, reason: 'L not used');
      expect(RommPairCode.isValid('ABCDO234'), isFalse, reason: 'O not used');
      expect(RommPairCode.isValid('abcd2345'), isFalse, reason: 'not upper');
      expect(RommPairCode.isValid('ABCD-234'), isFalse, reason: 'dash');
    });

    test('display formats as XXXX-XXXX and leaves other lengths alone', () {
      expect(RommPairCode.display('ABCD2345'), 'ABCD-2345');
      expect(RommPairCode.display('ABC'), 'ABC');
      expect(RommPairCode.display(''), '');
      expect(RommPairCode.display('ABCD23456'), 'ABCD23456');
    });
  });

  group('RommPairLink.parse', () {
    test('accepts a dashed code on an https origin', () {
      final link = RommPairLink.parse(
        'https://romm.example.com/pair?code=ABCD-2345',
      );
      expect(link, isNotNull);
      expect(link!.serverUrl, 'https://romm.example.com');
      expect(link.code, 'ABCD2345');
    });

    test('keeps the port, tolerates a trailing slash and lower case', () {
      final link = RommPairLink.parse(
        'http://192.168.1.10:8080/pair/?code=abcd2345',
      );
      expect(link, isNotNull);
      expect(link!.serverUrl, 'http://192.168.1.10:8080');
      expect(link.code, 'ABCD2345');
    });

    test('drops a default port from the origin', () {
      final link = RommPairLink.parse('https://x:443/pair?code=ABCD2345');
      expect(link?.serverUrl, 'https://x');
    });

    test('keeps an IPv6 literal bracketed', () {
      final link = RommPairLink.parse('http://[::1]:8080/pair?code=ABCD2345');
      expect(link?.serverUrl, 'http://[::1]:8080');
    });

    test('tolerates surrounding whitespace from a scan', () {
      final link = RommPairLink.parse(
        '  https://romm.example.com/pair?code=ABCD2345\n',
      );
      expect(link?.serverUrl, 'https://romm.example.com');
    });

    test('rejects another path', () {
      expect(RommPairLink.parse('https://x/library'), isNull);
      expect(RommPairLink.parse('https://x/pair/extra?code=ABCD2345'), isNull);
      expect(RommPairLink.parse('https://x/?code=ABCD2345'), isNull);
    });

    test('rejects a bare code', () {
      expect(RommPairLink.parse('ABCD2345'), isNull);
      expect(RommPairLink.parse('ABCD-2345'), isNull);
    });

    test('rejects a missing or malformed code parameter', () {
      expect(RommPairLink.parse('https://x/pair'), isNull);
      expect(RommPairLink.parse('https://x/pair?code='), isNull);
      expect(RommPairLink.parse('https://x/pair?code=ABC1O'), isNull);
      expect(RommPairLink.parse('https://x/pair?token=ABCD2345'), isNull);
    });

    test('rejects text that is not a URL', () {
      expect(RommPairLink.parse('not a url'), isNull);
      expect(RommPairLink.parse(''), isNull);
    });

    test('rejects non-http schemes and a missing host', () {
      expect(RommPairLink.parse('ftp://x/pair?code=ABCD2345'), isNull);
      expect(RommPairLink.parse('neostation://pair?code=ABCD2345'), isNull);
      expect(RommPairLink.parse('https:///pair?code=ABCD2345'), isNull);
    });

    test('value semantics', () {
      const a = RommPairLink(serverUrl: 'https://x', code: 'ABCD2345');
      const b = RommPairLink(serverUrl: 'https://x', code: 'ABCD2345');
      const c = RommPairLink(serverUrl: 'https://y', code: 'ABCD2345');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('ABCD-2345'));
    });
  });

  group('RommPairedToken.fromJson', () {
    test('reads every field', () {
      final token = RommPairedToken.fromJson({
        'id': 3,
        'name': 'Retroid Nova',
        'scopes': ['me.read', 'roms.read'],
        'expires_at': '2027-01-02T03:04:05Z',
        'raw_token': 'rmm_${'a' * 64}',
      });
      expect(token.rawToken, startsWith('rmm_'));
      expect(token.name, 'Retroid Nova');
      expect(token.scopes, ['me.read', 'roms.read']);
      expect(token.expiresAt, DateTime.utc(2027, 1, 2, 3, 4, 5));
    });

    test('tolerates a null expires_at and missing metadata', () {
      final token = RommPairedToken.fromJson({
        'raw_token': 'rmm_abc',
        'expires_at': null,
      });
      expect(token.rawToken, 'rmm_abc');
      expect(token.name, '');
      expect(token.scopes, isEmpty);
      expect(token.expiresAt, isNull);
    });

    test('an unparseable expires_at reads as never', () {
      final token = RommPairedToken.fromJson({
        'raw_token': 'rmm_abc',
        'expires_at': 'soon',
      });
      expect(token.expiresAt, isNull);
    });

    test('toString never includes the token', () {
      final token = RommPairedToken.fromJson({
        'raw_token': 'rmm_secret',
        'name': 'Nova',
        'scopes': const <String>[],
      });
      expect(token.toString(), isNot(contains('rmm_secret')));
      expect(token.toString(), contains('Nova'));
    });
  });
}
