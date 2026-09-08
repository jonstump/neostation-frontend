import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm_service.dart';

/// Login-time negotiation of the optional scope groups: the combined grant,
/// the per-group probes a 403 buys, the final grant for the union, and the
/// bound on how many token POSTs the whole thing may cost.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional
/// Scope Groups", REQ "Error Handling Standards"
void main() {
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  http.Response okToken() =>
      json(200, {'access_token': 'tok', 'expires': 3600});

  Map<String, dynamic> heartbeatBody(String version) => {
    'SYSTEM': {'VERSION': version},
  };

  /// A RomM on [version] whose token endpoint grants every scope group except
  /// those whose scope string appears in [denied].
  void serve({
    String version = '5.0.0',
    Set<String> denied = const {},
    http.Response Function()? heartbeat,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return heartbeat?.call() ?? json(200, heartbeatBody(version));
          case '/api/token':
            final scope = request.bodyFields['scope'] ?? '';
            final refused = denied.any(scope.contains);
            return refused ? http.Response('forbidden', 403) : okToken();
          case '/api/users/me':
            return json(200, {'id': 1, 'username': 'jon'});
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  RommService configured() => RommService()
    ..configure(
      serverUrl: 'https://romm.local',
      username: 'jon',
      password: 's3cret',
    );

  List<http.Request> tokenPosts() => [
    for (final r in requests)
      if (r.url.path == '/api/token') r,
  ];

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('the combined grant', () {
    test('asks for the read scopes plus every group', () async {
      serve();
      final service = configured();

      await service.authenticate();

      expect(tokenPosts(), hasLength(1));
      final scope = tokenPosts().single.bodyFields['scope']!;
      expect(scope, contains('roms.read'));
      for (final group in RommScopeGroup.values) {
        for (final one in group.scopes.split(' ')) {
          expect(scope, contains(one), reason: '${group.name} was not asked');
        }
      }
      for (final group in RommScopeGroup.values) {
        expect(service.hasScope(group), RommScopeState.granted);
      }
    });

    test('leaves out the groups this server predates', () async {
      // 4.8.x predates both 4.9.0 gates: play sessions (issue #136) and the
      // collection rom endpoints. Only the two ungated groups are asked for.
      serve(version: '4.8.1');
      final service = configured();

      await service.authenticate();

      final scope = tokenPosts().single.bodyFields['scope']!;
      expect(scope, contains('roms.read'));
      expect(scope, contains('roms.write'), reason: 'romsWrite has no gate');
      expect(scope, contains('tasks.run'), reason: 'tasksRun has no gate');
      expect(scope, isNot(contains('roms.user.write')));
      expect(scope, isNot(contains('collections.write')));
      expect(
        service.hasScope(RommScopeGroup.collectionsWrite),
        RommScopeState.denied,
      );
      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.denied);
      expect(service.playtimeSyncAvailable, isFalse);
    });

    test('a 4.9.0 server keeps the playtime group', () async {
      // The other side of the corrected threshold: 4.9.0 is the first release
      // that carries POST /api/play-sessions (issue #136).
      serve(version: '4.9.0');
      final service = configured();

      await service.authenticate();

      final scope = tokenPosts().single.bodyFields['scope']!;
      expect(scope, contains('roms.user.write'));
      expect(scope, contains('collections.write'));
      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.granted);
      expect(service.playtimeSyncAvailable, isTrue);
    });
  });

  group('probing on a 403', () {
    test('keeps the groups the account holds and denies the rest', () async {
      serve(denied: {'collections.write'});
      final service = configured();

      await service.authenticate();

      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.granted);
      expect(
        service.hasScope(RommScopeGroup.collectionsWrite),
        RommScopeState.denied,
      );
      expect(service.playtimeSyncAvailable, isTrue);

      final finalScope = tokenPosts().last.bodyFields['scope']!;
      expect(finalScope, contains('roms.user.write'));
      expect(finalScope, isNot(contains('collections.write')));
    });

    test('costs at most one probe per group plus two grants', () async {
      serve(denied: {'collections.write'});
      final service = configured();

      await service.authenticate();

      // combined + one probe per requested group + final.
      expect(
        tokenPosts().length,
        lessThanOrEqualTo(RommScopeGroup.values.length + 2),
      );
      expect(tokenPosts(), hasLength(RommScopeGroup.values.length + 2));
    });

    test('a server that predates a group shortens the probe run', () async {
      // 4.8.1 drops both 4.9.0-gated groups (playtime and collectionsWrite)
      // before the grant, so only three groups are requested and only three
      // probes can be spent on them.
      serve(version: '4.8.1', denied: {'tasks.run'});
      final service = configured();

      await service.authenticate();

      expect(tokenPosts(), hasLength(3 + 2));
      expect(service.hasScope(RommScopeGroup.tasksRun), RommScopeState.denied);
      expect(
        service.hasScope(RommScopeGroup.romsWrite),
        RommScopeState.granted,
      );
    });

    test(
      'all groups denied still logs the user in with the read scopes',
      () async {
        serve(
          denied: {
            for (final group in RommScopeGroup.values)
              ...group.scopes.split(' '),
          },
        );
        final service = configured();

        await service.authenticate();

        for (final group in RommScopeGroup.values) {
          expect(service.hasScope(group), RommScopeState.denied);
        }
        expect(service.playtimeSyncAvailable, isFalse);
        expect(tokenPosts().last.bodyFields['scope'], RommService.readScopes);
        expect(service.accessToken, 'tok');
      },
    );
  });

  group('failures that are not scope answers', () {
    test(
      'a wrong password fails on the combined grant with no probes',
      () async {
        RommService.debugUseHttpClient(
          MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/heartbeat') {
              return json(200, heartbeatBody('5.0.0'));
            }
            return http.Response('unauthorized', 401);
          }),
        );
        final service = configured();

        await expectLater(
          service.authenticate(),
          throwsA(isA<RommException>()),
        );

        expect(tokenPosts(), hasLength(1));
      },
    );

    test(
      'a 403 the final grant cannot recover from leaves groups unknown',
      () async {
        // Every grant is refused, including the read-only one: this is a
        // credential problem wearing a 403, not a scope verdict.
        RommService.debugUseHttpClient(
          MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/heartbeat') {
              return json(200, heartbeatBody('5.0.0'));
            }
            return http.Response('forbidden', 403);
          }),
        );
        final service = configured();

        await expectLater(
          service.authenticate(),
          throwsA(isA<RommException>()),
        );

        for (final group in RommScopeGroup.values) {
          expect(service.hasScope(group), RommScopeState.unknown);
        }
      },
    );

    test(
      'a probe answering 500 stops the run and surfaces the status',
      () async {
        var posts = 0;
        RommService.debugUseHttpClient(
          MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/api/heartbeat') {
              return json(200, heartbeatBody('5.0.0'));
            }
            posts++;
            if (posts == 1) return http.Response('forbidden', 403);
            return http.Response('boom', 500);
          }),
        );
        final service = configured();

        await expectLater(
          service.authenticate(),
          throwsA(
            isA<RommException>().having((e) => e.statusCode, 'statusCode', 500),
          ),
        );
        expect(tokenPosts(), hasLength(2));
      },
    );
  });

  group('API-key mode', () {
    test(
      'leaves every group unknown until an endpoint says otherwise',
      () async {
        serve();
        final service = RommService()
          ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_key');

        await service.authenticate();

        expect(tokenPosts(), isEmpty);
        for (final group in RommScopeGroup.values) {
          expect(service.hasScope(group), RommScopeState.unknown);
        }
        // Unknown never gates: playtime sync is still attempted.
        expect(service.playtimeSyncAvailable, isTrue);
      },
    );
  });

  group('reconfiguring', () {
    test('forgets what the previous credential negotiated', () async {
      serve(denied: {'collections.write'});
      final service = configured();
      await service.authenticate();
      expect(
        service.hasScope(RommScopeGroup.collectionsWrite),
        RommScopeState.denied,
      );

      service.configure(
        serverUrl: 'https://romm.local',
        username: 'other',
        password: 'other',
      );

      for (final group in RommScopeGroup.values) {
        expect(service.hasScope(group), RommScopeState.unknown);
      }
    });
  });

  group('the threshold table', () {
    test('gates the two write features on RomM 4.9.0', () {
      expect(
        RommFeature.romPropsBareBody.minVersion,
        const RommServerVersion(4, 9, 0),
      );
      expect(
        RommFeature.collectionRomsAddRemove.minVersion,
        const RommServerVersion(4, 9, 0),
      );
    });

    test('each group names the feature that would make it pointless', () {
      expect(RommScopeGroup.playtime.gate, RommFeature.playSessions);
      expect(
        RommScopeGroup.collectionsWrite.gate,
        RommFeature.collectionRomsAddRemove,
      );
      expect(RommScopeGroup.romsWrite.gate, isNull);
    });
  });
}
