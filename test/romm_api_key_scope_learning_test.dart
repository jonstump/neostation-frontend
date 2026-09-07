import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm_service.dart';

/// What an API-key login — and therefore a paired client token, which the
/// provider hands to `configure` as one — learns about the optional scope
/// groups from `GET /api/users/me`.
///
/// Before issue #168 this login mode negotiated nothing, so every group stayed
/// unknown and `canRunServerTasks` (which demands *granted*) could never be
/// true on the pairing/QR path.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional
/// Scope Groups", ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
void main() {
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM on [version] whose `/api/users/me` reports [scopes] — or omits the
  /// field entirely when [scopes] is null.
  void serve({String version = '5.1.0', List<String>? scopes}) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return json(200, {
              'SYSTEM': {'VERSION': version},
            });
          case '/api/users/me':
            return json(200, {
              'id': 1,
              'username': 'jon',
              'oauth_scopes': ?scopes,
            });
          case '/api/roms':
            return json(200, {'items': <dynamic>[]});
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  RommService configured() =>
      RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'client-token');

  /// Every scope RomM would list for an unrestricted client token.
  const allScopes = [
    'me.read',
    'roms.read',
    'platforms.read',
    'assets.read',
    'collections.read',
    'roms.user.read',
    'roms.user.write',
    'collections.write',
    'roms.write',
    'tasks.run',
    'devices.read',
    'devices.write',
  ];

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  test('a token holding tasks.run settles the group as granted', () async {
    serve(scopes: allScopes);
    final service = configured();

    await service.authenticate();

    expect(
      service.hasScope(RommScopeGroup.tasksRun),
      RommScopeState.granted,
      reason: 'the maintenance menu is gated on exactly this',
    );
  });

  test('a token without tasks.run settles the group as denied', () async {
    serve(scopes: allScopes.where((s) => s != 'tasks.run').toList());
    final service = configured();

    await service.authenticate();

    expect(service.hasScope(RommScopeGroup.tasksRun), RommScopeState.denied);
    expect(
      service.hasScope(RommScopeGroup.romsWrite),
      RommScopeState.granted,
      reason: 'one missing scope must cost one group, not every group',
    );
  });

  test('a group needing two scopes is not granted by half of them', () async {
    serve(scopes: const ['roms.read', 'devices.read']);
    final service = configured();

    await service.authenticate();

    expect(
      service.hasScope(RommScopeGroup.devices),
      RommScopeState.denied,
      reason: 'devices needs devices.read *and* devices.write',
    );
  });

  test('learning costs no extra request', () async {
    serve(scopes: allScopes);
    final service = configured();

    await service.authenticate();

    expect(
      requests.where((r) => r.url.path == '/api/users/me'),
      hasLength(1),
      reason: 'the scopes ride along on the call that already verifies the key',
    );
    expect(requests.where((r) => r.url.path == '/api/token'), isEmpty);
  });

  group('an answer that is not an answer leaves the groups unknown', () {
    test('the field is absent', () async {
      serve();
      final service = configured();

      await service.authenticate();

      for (final group in RommScopeGroup.values) {
        expect(
          service.hasScope(group),
          RommScopeState.unknown,
          reason: '$group',
        );
      }
    });

    test('the list is empty', () async {
      serve(scopes: const []);
      final service = configured();

      await service.authenticate();

      // An empty list must not read as "grants nothing": features that run on
      // `!= denied` (playtime) work today because unknown is permissive, and
      // denying them here would be a regression, not a fix.
      for (final group in RommScopeGroup.values) {
        expect(
          service.hasScope(group),
          RommScopeState.unknown,
          reason: '$group',
        );
      }
    });
  });

  test('a version-gated group is denied whatever the token holds', () async {
    // playtime is gated on RommFeature.playSessions; 3.0.0 predates it.
    serve(version: '3.0.0', scopes: allScopes);
    final service = configured();

    await service.authenticate();

    expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.denied);
    expect(service.hasScope(RommScopeGroup.tasksRun), RommScopeState.granted);
  });

  test('the username is still read from the same body', () async {
    serve(scopes: allScopes);
    final service = configured();

    await service.authenticate();

    expect(service.username, 'jon');
  });

  group('a session restored without a connect still learns', () {
    // RommProvider.initialize() rebuilds a saved connection from the database
    // and deliberately does not touch the network, so authenticate() is never
    // called. Before issue #168 that left the groups unknown for the whole run
    // *and* left capabilities unprobed, so version-gated controls rendered on
    // servers that cannot serve them.
    test('the first authenticated call verifies the key and probes', () async {
      serve(scopes: allScopes);
      final service = configured();

      // No authenticate() — straight to a normal browse call.
      await service.getRoms(limit: 1);

      expect(service.hasScope(RommScopeGroup.tasksRun), RommScopeState.granted);
      // The heartbeat must run too. Without it capabilities stay null,
      // `supports` answers `unknown` rather than `unsupported`, and a
      // version-gated control like Surprise Me renders on a server that
      // answers its endpoint with a 422.
      expect(service.capabilities, isNotNull);
      expect(
        service.supports(RommFeature.randomRom),
        RommFeatureSupport.unsupported,
        reason: 'randomRom needs 5.2.0; this server is 5.1.0',
      );
    });

    test('verification happens once, not before every call', () async {
      serve(scopes: allScopes);
      final service = configured();

      await service.getRoms(limit: 1);
      await service.getRoms(limit: 1);
      await service.getRoms(limit: 1);

      expect(
        requests.where((r) => r.url.path == '/api/users/me'),
        hasLength(1),
        reason: 'once per connection, not once per request',
      );
    });

    test('a failed verification does not fail the request', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/heartbeat':
              return json(200, {
                'SYSTEM': {'VERSION': '5.1.0'},
              });
            case '/api/users/me':
              return http.Response('boom', 500);
            default:
              return json(200, {'items': <dynamic>[]});
          }
        }),
      );
      final service = configured();

      await expectLater(service.getRoms(limit: 1), completes);
      for (final group in RommScopeGroup.values) {
        expect(
          service.hasScope(group),
          RommScopeState.unknown,
          reason: '$group',
        );
      }
    });
  });

  group('a verification that never reached the server re-arms', () {
    // A handheld commonly resumes and fires its first request before Wi-Fi is
    // up. Latching the one-shot on a transport error would leave the groups
    // unknown and capabilities null for the rest of the process — issue #168's
    // symptom with a narrower trigger.
    test('a transport failure lets a later call verify', () async {
      var offline = true;
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          if (offline) throw const SocketException('network is down');
          switch (request.url.path) {
            case '/api/heartbeat':
              return json(200, {
                'SYSTEM': {'VERSION': '5.1.0'},
              });
            case '/api/users/me':
              return json(200, {
                'id': 1,
                'username': 'jon',
                'oauth_scopes': allScopes,
              });
            default:
              return json(200, {'items': <dynamic>[]});
          }
        }),
      );
      final service = configured();

      // First call: the server is unreachable, so nothing is learned.
      await expectLater(service.getRoms(limit: 1), throwsA(isA<Exception>()));
      expect(service.hasScope(RommScopeGroup.tasksRun), RommScopeState.unknown);

      // Wi-Fi comes up; the next call must retry the verification.
      offline = false;
      await service.getRoms(limit: 1);

      expect(
        service.hasScope(RommScopeGroup.tasksRun),
        RommScopeState.granted,
        reason: 'a transport error must not spend the one-shot',
      );
    });

    test('a rejected key does not retry', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/heartbeat':
              return json(200, {
                'SYSTEM': {'VERSION': '5.1.0'},
              });
            case '/api/users/me':
              return http.Response('forbidden', 403);
            default:
              return json(200, {'items': <dynamic>[]});
          }
        }),
      );
      final service = configured();

      await service.getRoms(limit: 1);
      await service.getRoms(limit: 1);
      await service.getRoms(limit: 1);

      expect(
        requests.where((r) => r.url.path == '/api/users/me'),
        hasLength(1),
        reason: 'the server answered "no" — asking again only repeats it',
      );
    });
  });
}
