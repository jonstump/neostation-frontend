import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
}
