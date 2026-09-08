import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

/// `RommService.getRomByHash` (SPEC-0011 "ROM Lookup By Hash") against a fake
/// client: the request carries exactly the hashes it was given, lowercased
/// the way RomM stores them; 200 is a ROM, 404 is null, anything else throws;
/// and a server the heartbeat placed before the endpoint is never asked, with
/// the gate logged once per connection.
///
/// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "ROM Lookup By
/// Hash", REQ "Error Handling Standards"
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

  Map<String, dynamic> romBody(int id) => {
    'id': id,
    'name': 'Rom $id',
    'platform_id': 1,
    'platform_slug': 'snes',
    'fs_name': 'rom$id.sfc',
    'fs_name_no_ext': 'rom$id',
    'fs_extension': 'sfc',
    'crc_hash': 'deadbeef',
  };

  /// A RomM whose heartbeat answers [heartbeat] and whose by-hash endpoint
  /// answers [byHash]; the token and identity endpoints always succeed.
  void serve({
    required http.Response Function() heartbeat,
    required http.Response Function(http.Request) byHash,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return heartbeat();
          case '/api/token':
            return json(200, {'access_token': 'tok', 'expires': 3600});
          case '/api/users/me':
            return json(200, {'id': 1, 'username': 'jon'});
          case '/api/roms/by-hash':
            return byHash(request);
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  RommService configured() {
    final service = RommService();
    service.configure(
      serverUrl: 'https://romm.local',
      username: 'jon',
      password: 's3cret',
    );
    return service;
  }

  List<http.Request> byHashRequests() => [
    for (final r in requests)
      if (r.url.path == '/api/roms/by-hash') r,
  ];

  Future<List<String>> logsFrom(Future<void> Function() body) async {
    LoggerService.instance.startCapture();
    await body();
    return LoggerService.instance.takeCapture();
  }

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('the request', () {
    // Scenario "Hit": crc32 and md5 given, 200 answered.
    test('carries only the hashes it was given, lowercased', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => json(200, romBody(41)),
      );
      final service = configured();
      await service.fetchHeartbeat();

      final rom = await service.getRomByHash(
        crc32: 'DEADBEEF',
        md5: ' 0123456789abcdef0123456789abcdef ',
      );

      expect(rom?.id, 41);
      final sent = byHashRequests();
      expect(sent, hasLength(1));
      expect(sent.single.url.queryParameters, {
        'crc_hash': 'deadbeef',
        'md5_hash': '0123456789abcdef0123456789abcdef',
      });
    });

    test('sends a lone sha1 as sha1_hash and nothing else', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => json(200, romBody(7)),
      );
      final service = configured();

      await service.getRomByHash(sha1: 'a' * 40);

      expect(byHashRequests().single.url.queryParameters, {
        'sha1_hash': 'a' * 40,
      });
    });

    test('refuses to run with no hash at all', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => json(200, romBody(7)),
      );
      final service = configured();

      await expectLater(
        () => service.getRomByHash(crc32: '', md5: null),
        throwsA(isA<ArgumentError>()),
      );
      expect(byHashRequests(), isEmpty);
    });
  });

  group('the answer', () {
    // Scenario "Miss" (the picker's): 404 is no ROM, not an error.
    test('404 is null', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => http.Response('not found', 404),
      );
      final service = configured();

      expect(await service.getRomByHash(crc32: 'deadbeef'), isNull);
      expect(byHashRequests(), hasLength(1));
    });

    test('any other failure throws RommException with the status', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => http.Response('boom', 500),
      );
      final service = configured();

      await expectLater(
        () => service.getRomByHash(crc32: 'deadbeef'),
        throwsA(
          isA<RommException>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('an empty 200 body is null', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.5.0')),
        byHash: (_) => http.Response('', 200),
      );
      final service = configured();

      expect(await service.getRomByHash(crc32: 'deadbeef'), isNull);
    });
  });

  group('the capability gate', () {
    // Scenario "Old server": 4.4.0 predates the endpoint.
    test('a 4.4.0 server is not asked and the gate is logged once', () async {
      serve(
        heartbeat: () => json(200, heartbeatBody('4.4.0')),
        byHash: (_) => json(200, romBody(41)),
      );
      final service = configured();
      await service.fetchHeartbeat();

      final first = await logsFrom(() async {
        expect(await service.getRomByHash(crc32: 'deadbeef'), isNull);
      });
      final second = await logsFrom(() async {
        expect(await service.getRomByHash(crc32: 'deadbeef'), isNull);
      });

      expect(byHashRequests(), isEmpty);
      final gateLines = [
        for (final line in [...first, ...second])
          if (line.contains('RomM feature gated: feature=romLookupByHash'))
            line,
      ];
      expect(gateLines, hasLength(1));
      expect(gateLines.single, contains('version=4.4.0'));
    });

    test('an unknown version still asks, per ADR-0010', () async {
      serve(
        heartbeat: () => http.Response('blocked', 403),
        byHash: (_) => json(200, romBody(41)),
      );
      final service = configured();
      await service.fetchHeartbeat();

      final rom = await service.getRomByHash(crc32: 'deadbeef');

      expect(rom?.id, 41);
      expect(byHashRequests(), hasLength(1));
    });
  });
}
