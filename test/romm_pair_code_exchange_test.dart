import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_pairing.dart';
import 'package:neostation/services/romm_service.dart';

/// [RommService.exchangePairCode] against a scripted HTTP client: the request
/// it sends, the token it returns, and the sentinel kind on each failure.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Code
/// Exchange"
void main() {
  const rawToken =
      'rmm_0123456789abcdef0123456789abcdef'
      '0123456789abcdef0123456789abcdef';

  final requests = <http.Request>[];

  /// Installs a client answering every request with [respond].
  void serve(FutureOr<http.Response> Function(http.Request) respond) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        return await respond(request);
      }),
    );
  }

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  Map<String, dynamic> tokenBody({String? expiresAt}) => {
    'id': 7,
    'name': 'Retroid Nova',
    'scopes': ['me.read', 'roms.read', 'assets.write'],
    'expires_at': expiresAt,
    'last_used_at': null,
    'created_at': '2026-09-05T10:00:00Z',
    'user_id': 1,
    'raw_token': rawToken,
  };

  Future<RommException> failure(Future<RommPairedToken> call) async {
    try {
      await call;
    } on RommException catch (e) {
      return e;
    }
    fail('expected a RommException');
  }

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('exchangePairCode', () {
    test(
      'POSTs the normalised code unauthenticated and returns the token',
      () async {
        serve((_) => json(200, tokenBody(expiresAt: '2027-03-04T05:06:07Z')));

        final token = await RommService().exchangePairCode(
          'https://romm.local',
          'abcd-2345',
        );

        expect(requests, hasLength(1));
        final req = requests.single;
        expect(req.method, 'POST');
        expect(
          req.url.toString(),
          'https://romm.local/api/client-tokens/exchange',
        );
        expect(req.body, '{"code":"ABCD2345"}');
        expect(req.headers['content-type'], startsWith('application/json'));
        expect(
          req.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );

        expect(token.rawToken, rawToken);
        expect(token.rawToken, startsWith('rmm_'));
        expect(token.name, 'Retroid Nova');
        expect(token.scopes, ['me.read', 'roms.read', 'assets.write']);
        expect(token.expiresAt, DateTime.utc(2027, 3, 4, 5, 6, 7));
      },
    );

    test('a null expires_at reads as a token that never expires', () async {
      serve((_) => json(200, tokenBody()));
      final token = await RommService().exchangePairCode(
        'https://romm.local',
        'ABCD2345',
      );
      expect(token.expiresAt, isNull);
    });

    test('normalises the server URL like configure', () async {
      serve((_) => json(200, tokenBody()));
      final service = RommService();
      await service.exchangePairCode('romm.local/', 'ABCD2345');
      expect(service.baseUrl, 'https://romm.local');
      expect(
        requests.single.url.toString(),
        'https://romm.local/api/client-tokens/exchange',
      );
    });

    test('does not touch configured credentials', () async {
      serve((_) => json(200, tokenBody()));
      final service = RommService()
        ..configure(serverUrl: 'https://old.local', apiKey: 'rmm_old');
      await service.exchangePairCode('https://romm.local', 'ABCD2345');
      expect(service.apiKey, 'rmm_old');
      expect(service.baseUrl, 'https://romm.local');
    });

    test('a malformed code is rejected with no request', () async {
      serve((_) => json(200, tokenBody()));

      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABC-1O'),
      );

      expect(e.kind, RommErrorKind.pairCodeInvalid);
      expect(e.statusCode, isNull);
      expect(e.message, contains('XXXX-XXXX'));
      expect(requests, isEmpty);
    });

    test('an empty server URL is rejected with no request', () async {
      serve((_) => json(200, tokenBody()));
      final e = await failure(RommService().exchangePairCode('  ', 'ABCD2345'));
      expect(e.message, 'Server URL is empty');
      expect(requests, isEmpty);
    });

    test('404 is an expired code', () async {
      serve((_) => json(404, {'detail': 'Invalid or expired pairing code'}));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.pairCodeExpired);
      expect(e.statusCode, 404);
      expect(e.message, contains('invalid or expired'));
      expect(e.message, contains('generate a new one'));
    });

    test('410 is an expired code', () async {
      serve((_) => http.Response('', 410));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.pairCodeExpired);
      expect(e.statusCode, 410);
    });

    test('429 is rate limited', () async {
      serve((_) => json(429, {'detail': 'Too many attempts'}));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.pairRateLimited);
      expect(e.statusCode, 429);
      expect(e.message.toLowerCase(), contains('too many'));
      expect(e.message.toLowerCase(), contains('wait a minute'));
    });

    test('any other 4xx is an invalid code', () async {
      serve((_) => json(400, {'detail': 'bad request'}));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.pairCodeInvalid);
      expect(e.statusCode, 400);
    });

    test('a 5xx is a plain failure carrying the status', () async {
      serve((_) => http.Response('boom', 503));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.other);
      expect(e.statusCode, 503);
    });

    test('a 200 without raw_token is a failure, not an empty key', () async {
      serve((_) => json(200, {'name': 'x', 'scopes': const []}));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.other);
      expect(e.message, contains('no token'));
    });

    test('a 200 that is not JSON is a failure', () async {
      serve((_) => http.Response('<html>', 200));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.kind, RommErrorKind.other);
      expect(e.message, contains('Unexpected'));
    });

    test('a timeout reads like the API-key verification', () async {
      serve((_) => throw TimeoutException('slow'));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.message, 'Connection timed out');
      expect(e.kind, RommErrorKind.other);
    });

    test('a socket error names the server', () async {
      serve((_) => throw const SocketException('Connection refused'));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.message, 'Cannot reach server: Connection refused');
    });

    test('falls back to http when the https handshake fails', () async {
      serve((request) {
        if (request.url.scheme == 'https') {
          throw const HandshakeException('bad cert');
        }
        return json(200, tokenBody());
      });
      final service = RommService();
      final token = await service.exchangePairCode('romm.local', 'ABCD2345');
      expect(token.rawToken, rawToken);
      expect(requests.map((r) => r.url.scheme).toList(), ['https', 'http']);
      expect(service.baseUrl, 'http://romm.local');
    });

    test('an explicit https scheme is not downgraded', () async {
      serve((_) => throw const HandshakeException('bad cert'));
      final e = await failure(
        RommService().exchangePairCode('https://romm.local', 'ABCD2345'),
      );
      expect(e.message, contains('TLS handshake failed'));
      expect(requests, hasLength(1));
    });
  });
}
