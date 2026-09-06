import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [RommProvider.connectWithPairCode] end to end against an in-memory
/// database, a fake credential store, and a scripted RomM: the paired token
/// must land in exactly the storage a pasted API key uses, its name and
/// expiry beside it, and nothing may be stored when either the exchange or
/// the verification that follows it fails.
///
/// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Connect Through
/// The API-Key Path", REQ "Error Handling Standards"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rawToken = 'rmm_${'ab' * 32}';
  const expiresAt = '2027-03-04T05:06:07Z';

  final dbHelper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late MemoryBackend secureStore;
  final requests = <http.Request>[];

  /// A RomM that answers the exchange with [exchange] and `/api/users/me`
  /// with [me]; anything else is a 404.
  void serve({
    required http.Response Function() exchange,
    required http.Response Function(http.Request) me,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/client-tokens/exchange':
            return exchange();
          case '/api/users/me':
            return me(request);
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  http.Response tokenOk({String? expires = expiresAt}) => json(200, {
    'id': 7,
    'name': 'Retroid Nova',
    'scopes': ['me.read', 'roms.read'],
    'expires_at': expires,
    'raw_token': rawToken,
  });

  http.Response meOk(http.Request request) {
    // The verification must carry the freshly exchanged token as a bearer.
    expect(request.headers['authorization'], 'Bearer $rawToken');
    return json(200, {'id': 1, 'username': 'jon'});
  }

  setUp(() async {
    requests.clear();
    secureStore = MemoryBackend();
    CredentialStore.debugUseBackends(
      secure: secureStore,
      file: MemoryBackend(),
    );
    db = await dbHelper.setUp();
    // The connect path drains the play-session outbox in the background.
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
  });

  group('connectWithPairCode', () {
    test('success connects and stores the token like a pasted key', () async {
      serve(exchange: tokenOk, me: meOk);
      final provider = RommProvider();

      final error = await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'abcd-2345',
      );

      expect(error, isNull);
      expect(provider.status, RommConnectionStatus.connected);
      expect(provider.lastError, isNull);
      expect(provider.lastErrorKind, isNull);
      expect(provider.serverUrl, 'https://romm.local');
      expect(provider.username, 'jon', reason: 'resolved from /api/users/me');
      expect(provider.service.usesApiKey, isTrue);
      expect(provider.service.apiKey, rawToken);

      // Exactly the API-key secret slot, nothing new.
      expect(secureStore.values['romm_api_key'], rawToken);
      expect(secureStore.values.containsKey('romm_password'), isFalse);
      final config = await RommRepository.getConfig();
      expect(config!['api_key'], rawToken);
      expect(config['password'], '');
      expect(config['access_token'], isNull);

      // Name and expiry beside the connection row and exposed.
      expect(config['token_name'], 'Retroid Nova');
      expect(config['token_expires_at'], DateTime.utc(2027, 3, 4, 5, 6, 7));
      expect(provider.pairedTokenName, 'Retroid Nova');
      expect(provider.pairedTokenExpiresAt, DateTime.utc(2027, 3, 4, 5, 6, 7));

      expect(requests.map((r) => r.url.path).toList(), [
        '/api/client-tokens/exchange',
        '/api/users/me',
      ]);
      expect(requests.first.body, '{"code":"ABCD2345"}');
    });

    test('a token that never expires stores a null expiry', () async {
      serve(exchange: () => tokenOk(expires: null), me: meOk);
      final provider = RommProvider();
      await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABCD2345',
      );
      expect(provider.pairedTokenName, 'Retroid Nova');
      expect(provider.pairedTokenExpiresAt, isNull);
      final row = (await RommRepository.getConfig())!;
      expect(row['token_expires_at'], isNull);
    });

    test(
      'the paired session is restored at startup like a pasted key',
      () async {
        serve(exchange: tokenOk, me: meOk);
        await RommProvider().connectWithPairCode(
          serverUrl: 'https://romm.local',
          code: 'ABCD2345',
        );

        final restored = RommProvider();
        await restored.initialize();

        expect(restored.status, RommConnectionStatus.connected);
        expect(restored.serverUrl, 'https://romm.local');
        expect(restored.service.usesApiKey, isTrue);
        expect(restored.service.apiKey, rawToken);
        expect(restored.pairedTokenName, 'Retroid Nova');
        expect(
          restored.pairedTokenExpiresAt,
          DateTime.utc(2027, 3, 4, 5, 6, 7),
        );
      },
    );

    test('an expired code sets the error and stores nothing', () async {
      serve(
        exchange: () =>
            json(404, {'detail': 'Invalid or expired pairing code'}),
        me: meOk,
      );
      final provider = RommProvider();

      final error = await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABCD2345',
      );

      expect(error, isNotNull);
      expect(provider.status, RommConnectionStatus.error);
      expect(provider.lastError, error);
      expect(provider.lastErrorKind, RommErrorKind.pairCodeExpired);
      expect(provider.pairedTokenName, isNull);
      expect(secureStore.values, isEmpty);
      expect(await RommRepository.getConfig(), isNull);
      expect(requests.map((r) => r.url.path).toList(), [
        '/api/client-tokens/exchange',
      ], reason: 'no verification without a token');
    });

    test('a rate limit is distinguishable', () async {
      serve(exchange: () => http.Response('', 429), me: meOk);
      final provider = RommProvider();
      await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABCD2345',
      );
      expect(provider.lastErrorKind, RommErrorKind.pairRateLimited);
      expect(await RommRepository.getConfig(), isNull);
    });

    test('a malformed code never reaches the server', () async {
      serve(exchange: tokenOk, me: meOk);
      final provider = RommProvider();
      final error = await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABC-1O',
      );
      expect(error, contains('XXXX-XXXX'));
      expect(provider.lastErrorKind, RommErrorKind.pairCodeInvalid);
      expect(requests, isEmpty);
      expect(await RommRepository.getConfig(), isNull);
    });

    test(
      'exchange ok but verification 401 reports that error and stores nothing',
      () async {
        serve(
          exchange: tokenOk,
          me: (_) => json(401, {'detail': 'Not authenticated'}),
        );
        final provider = RommProvider();

        final error = await provider.connectWithPairCode(
          serverUrl: 'https://romm.local',
          code: 'ABCD2345',
        );

        expect(error, 'Invalid API key', reason: 'the verification error');
        expect(provider.status, RommConnectionStatus.error);
        expect(provider.lastError, 'Invalid API key');
        expect(provider.lastErrorKind, RommErrorKind.other);
        expect(provider.pairedTokenName, isNull);
        expect(provider.pairedTokenExpiresAt, isNull);
        expect(secureStore.values, isEmpty, reason: 'token not persisted');
        expect(await RommRepository.getConfig(), isNull);
        expect(requests.map((r) => r.url.path).toList(), [
          '/api/client-tokens/exchange',
          '/api/users/me',
        ]);
      },
    );

    test('disconnect clears the token, its name and its expiry', () async {
      serve(exchange: tokenOk, me: meOk);
      final provider = RommProvider();
      await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABCD2345',
      );
      expect(provider.pairedTokenName, isNotNull);

      await provider.disconnect();

      expect(provider.status, RommConnectionStatus.disconnected);
      expect(provider.pairedTokenName, isNull);
      expect(provider.pairedTokenExpiresAt, isNull);
      expect(provider.lastErrorKind, isNull);
      expect(secureStore.values.containsKey('romm_api_key'), isFalse);
      expect(await RommRepository.getConfig(), isNull);
    });

    test('reconnecting with a pasted key drops the pairing metadata', () async {
      serve(exchange: tokenOk, me: meOk);
      final provider = RommProvider();
      await provider.connectWithPairCode(
        serverUrl: 'https://romm.local',
        code: 'ABCD2345',
      );

      final error = await provider.connect(
        serverUrl: 'https://romm.local',
        apiKey: rawToken,
      );

      expect(error, isNull);
      expect(provider.status, RommConnectionStatus.connected);
      expect(provider.pairedTokenName, isNull);
      expect(provider.pairedTokenExpiresAt, isNull);
      final config = (await RommRepository.getConfig())!;
      expect(config['api_key'], rawToken);
      expect(config['token_name'], isNull);
      expect(config['token_expires_at'], isNull);
    });
  });

  group('RommRepository paired-token metadata', () {
    test('savePairedTokenMetadata needs a connection row', () async {
      expect(
        await RommRepository.savePairedTokenMetadata(
          name: 'x',
          expiresAt: null,
        ),
        isFalse,
      );
    });

    test('stores the expiry as ISO-8601 UTC and reads it back', () async {
      await RommRepository.saveConfig(
        serverUrl: 'https://romm.local',
        apiKey: rawToken,
      );
      final ok = await RommRepository.savePairedTokenMetadata(
        name: 'Nova',
        expiresAt: DateTime.utc(2027, 1, 2, 3, 4, 5),
      );
      expect(ok, isTrue);

      final row = (await db.query('user_romm_config')).first;
      expect(row['romm_token_name'], 'Nova');
      expect(row['romm_token_expires_at'], '2027-01-02T03:04:05.000Z');

      final config = (await RommRepository.getConfig())!;
      expect(config['token_name'], 'Nova');
      expect(config['token_expires_at'], DateTime.utc(2027, 1, 2, 3, 4, 5));

      expect(await RommRepository.clearPairedTokenMetadata(), isTrue);
      final cleared = (await RommRepository.getConfig())!;
      expect(cleared['token_name'], isNull);
      expect(cleared['token_expires_at'], isNull);
      expect(cleared['api_key'], rawToken, reason: 'the key itself stays');
    });
  });
}
