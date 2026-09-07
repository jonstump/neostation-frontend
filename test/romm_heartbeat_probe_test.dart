import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm_service.dart';

/// The connect-time capability probe and the gates it feeds: the heartbeat
/// never throws whatever the server does, a known-old server costs exactly one
/// token POST with no playtime scopes, and a gated endpoint is never asked.
/// A probe that did not land must leave every one of those paths exactly as it
/// was before ADR-0010.
///
/// Governing: ADR-0010 (RomM heartbeat capability probe), SPEC-0010 REQ
/// "Heartbeat Probe", REQ "Probe Before The Token Grant", REQ "Gated Call
/// Sites"
void main() {
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  Map<String, dynamic> heartbeatBody(String version) => {
    'SYSTEM': {'VERSION': version},
    'FRONTEND': {'DISABLE_USERPASS_LOGIN': false},
  };

  /// A RomM whose heartbeat is [heartbeat] and whose token endpoint answers
  /// [token]; `/api/users/me` always succeeds. Anything else is a 404.
  void serve({
    required http.Response Function() heartbeat,
    http.Response Function(http.Request)? token,
    http.Response Function(http.Request)? playSessions,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return heartbeat();
          case '/api/token':
            return token?.call(request) ??
                json(200, {'access_token': 'tok', 'expires': 3600});
          case '/api/users/me':
            return json(200, {'id': 1, 'username': 'jon'});
          case '/api/play-sessions':
            return playSessions?.call(request) ??
                json(200, {'created': 0, 'skipped': 0, 'results': []});
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  RommService configured({String url = 'https://romm.local'}) {
    final service = RommService();
    service.configure(serverUrl: url, username: 'jon', password: 's3cret');
    return service;
  }

  List<String> paths() => [for (final r in requests) r.url.path];

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('fetchHeartbeat', () {
    test('a 200 stores the parsed capabilities', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = configured();

      await service.fetchHeartbeat();

      expect(service.capabilities, isNotNull);
      expect(service.capabilities!.version, const RommServerVersion(5, 2, 0));
      expect(
        service.supports(RommFeature.playSessions),
        RommFeatureSupport.supported,
      );
      expect(paths(), ['/api/heartbeat']);
    });

    test('it sends no Authorization header', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = configured();
      await service.fetchHeartbeat();
      expect(requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('a 404 leaves capabilities null and unknown support', () async {
      serve(heartbeat: () => http.Response('not found', 404));
      final service = configured();

      await service.fetchHeartbeat();

      expect(service.capabilities, isNull);
      for (final feature in RommFeature.values) {
        expect(service.supports(feature), RommFeatureSupport.unknown);
      }
    });

    test('a timeout is swallowed', () async {
      serve(heartbeat: () => throw TimeoutException('probe'));
      final service = configured();
      await service.fetchHeartbeat();
      expect(service.capabilities, isNull);
    });

    test('an unparseable body is swallowed', () async {
      serve(heartbeat: () => http.Response('<html>nope</html>', 200));
      final service = configured();
      await service.fetchHeartbeat();
      expect(service.capabilities, isNull);
    });

    test('a body that is not an object is swallowed', () async {
      serve(heartbeat: () => json(200, ['a', 'list']));
      final service = configured();
      await service.fetchHeartbeat();
      expect(service.capabilities, isNull);
    });

    test('an empty base URL sends nothing', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = RommService();
      await service.fetchHeartbeat();
      expect(requests, isEmpty);
      expect(service.capabilities, isNull);
    });

    test('configure with a different base URL clears capabilities', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = configured();
      await service.fetchHeartbeat();
      expect(service.capabilities, isNotNull);

      service.configure(
        serverUrl: 'https://other.local',
        username: 'jon',
        password: 's3cret',
      );
      expect(service.capabilities, isNull);
      expect(
        service.supports(RommFeature.playSessions),
        RommFeatureSupport.unknown,
      );
    });

    test('configure with the same base URL keeps them', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = configured();
      await service.fetchHeartbeat();

      service.configure(
        serverUrl: 'https://romm.local/',
        username: 'jon',
        password: 'newpass',
      );
      expect(service.capabilities, isNotNull);
    });

    test('a serverUrl argument points the service first', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = RommService();
      await service.fetchHeartbeat(serverUrl: 'romm.local');
      expect(service.baseUrl, 'https://romm.local');
      expect(service.capabilities!.version, const RommServerVersion(4, 7, 0));
    });
  });

  group('authenticate probes before the token grant', () {
    test('an old server gets exactly one read-scope POST', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = configured();

      await service.authenticate();

      expect(paths(), ['/api/heartbeat', '/api/token']);
      final grant = requests.last;
      expect(grant.bodyFields['scope'], isNot(contains('roms.user.read')));
      expect(grant.bodyFields['scope'], contains('roms.read'));
      expect(service.playtimeSyncAvailable, isFalse);
    });

    test('a new server keeps the playtime scopes', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.8.0')));
      final service = configured();

      await service.authenticate();

      expect(paths(), ['/api/heartbeat', '/api/token']);
      expect(requests.last.bodyFields['scope'], contains('roms.user.write'));
      expect(service.playtimeSyncAvailable, isTrue);
    });

    test(
      'a failed probe still asks for every group and drops only the denied one',
      () async {
        // A server that refuses the playtime scopes and allows the rest. With
        // no heartbeat every group reads as unknown, so all of them are asked
        // for and the negotiation settles them one at a time (ADR-0013).
        serve(
          heartbeat: () => http.Response('blocked', 502),
          token: (request) =>
              request.bodyFields['scope']!.contains('roms.user.')
              ? http.Response('forbidden', 403)
              : json(200, {'access_token': 'tok', 'expires': 3600}),
        );
        final service = configured();

        await service.authenticate();

        expect(
          requests[1].bodyFields['scope'],
          contains('roms.user.write'),
          reason: 'unknown never gates',
        );
        expect(
          requests.last.bodyFields['scope'],
          isNot(contains('roms.user.')),
        );
        expect(
          requests.last.bodyFields['scope'],
          contains('collections.write'),
        );
        expect(service.playtimeSyncAvailable, isFalse);
        expect(
          service.hasScope(RommScopeGroup.collectionsWrite),
          RommScopeState.granted,
        );
      },
    );

    test('the probe runs once per connection', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.8.0')));
      final service = configured();

      await service.authenticate();
      await service.authenticate();

      expect(paths().where((p) => p == '/api/heartbeat').length, 1);
    });

    test('API-key mode probes too', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_key');

      await service.authenticate();

      expect(paths(), ['/api/heartbeat', '/api/users/me']);
      expect(service.capabilities!.version, const RommServerVersion(4, 7, 0));
      expect(service.playtimeSyncAvailable, isFalse);
    });
  });

  group('gated call sites', () {
    final session = RommPlaySession(
      romId: 7,
      startTime: DateTime.utc(2026, 1, 1),
      endTime: DateTime.utc(2026, 1, 1, 0, 10),
      durationMs: 600000,
    );

    test('an old server never reaches /api/play-sessions', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = configured();
      await service.authenticate();
      requests.clear();

      await expectLater(
        service.ingestPlaySessions([session]),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.unsupported,
          ),
        ),
      );

      expect(requests, isEmpty);
      expect(service.playtimeSyncAvailable, isFalse);
    });

    test('getPlaySessions is gated the same way', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = configured();
      await service.authenticate();
      requests.clear();

      await expectLater(
        service.getPlaySessions(romId: 7),
        throwsA(isA<RommException>()),
      );
      expect(requests, isEmpty);
    });

    test('an unknown server still tries the upload', () async {
      serve(
        heartbeat: () => http.Response('blocked', 502),
        playSessions: (_) =>
            json(200, {'created': 1, 'skipped': 0, 'results': []}),
      );
      final service = configured();
      await service.authenticate();
      requests.clear();

      await service.ingestPlaySessions([session]);

      expect(paths(), ['/api/play-sessions']);
    });

    test('a 404 still disables playtime for an unknown server', () async {
      serve(
        heartbeat: () => http.Response('blocked', 502),
        playSessions: (_) => http.Response('not found', 404),
      );
      final service = configured();
      await service.authenticate();

      await expectLater(
        service.ingestPlaySessions([session]),
        throwsA(isA<RommException>()),
      );
      expect(service.playtimeSyncAvailable, isFalse);
    });
  });
}
