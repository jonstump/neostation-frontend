import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_play_session.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/logger_service.dart';
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

    // The cap is the budget for the whole probe, retries included. When it was
    // applied per attempt instead, a server that failed TLS slowly and then
    // hung on plain HTTP held the connect path for both timeouts back to back
    // — roughly twice the ceiling SPEC-0010 allows. The MockClient-based
    // timeout test above never caught it because it throws instead of running
    // the clock, so this one drives a fake clock through both attempts.
    // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe"
    test(
      'the scheme fallback shares the 5 s budget, it does not restart it',
      () {
        fakeAsync((async) {
          final schemes = <String>[];
          RommService.debugUseHttpClient(
            MockClient((request) async {
              schemes.add(request.url.scheme);
              if (request.url.scheme == 'https') {
                // A TLS failure that costs real time before it lands.
                await Future<void>.delayed(const Duration(seconds: 3));
                throw const HandshakeException('bad cert');
              }
              // …and a plain-HTTP retry that never answers.
              await Completer<void>().future;
              throw StateError('unreachable');
            }),
          );
          final service = RommService()
            ..configure(
              serverUrl: 'romm.local',
              username: 'jon',
              password: 's3cret',
            );

          var settled = false;
          Object? thrown;
          unawaited(() async {
            try {
              await service.fetchHeartbeat();
            } catch (e) {
              thrown = e;
            }
            settled = true;
          }());

          async.elapse(const Duration(seconds: 4));
          async.flushMicrotasks();
          expect(schemes, [
            'https',
            'http',
          ], reason: 'the TLS failure downgraded the scheme and retried');
          expect(settled, isFalse, reason: 'the budget has not run out yet');

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(
            settled,
            isTrue,
            reason: 'the whole probe is capped at 5 s, not 5 s per attempt',
          );
          expect(thrown, isNull, reason: 'fetchHeartbeat never throws');
          expect(service.capabilities, isNull);
        });
      },
    );

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
      // 4.9.0, not 4.8.0: that is the release play-session ingest shipped in
      // (issue #136).
      serve(heartbeat: () => json(200, heartbeatBody('4.9.0')));
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

  /// Everything [LoggerService] emitted while [body] ran.
  ///
  /// The suite had no way to assert on log output, which left SPEC-0010's
  /// "exactly one line" and "once per connection per feature" clauses readable
  /// in the code but never executed. Governing: SPEC-0010 REQ "Error Handling
  /// Standards".
  Future<List<String>> logsFrom(Future<void> Function() body) async {
    LoggerService.instance.startCapture();
    try {
      await body();
    } finally {
      // Nothing else in this isolate logs during a test, so whatever is here
      // belongs to [body].
    }
    return LoggerService.instance.takeCapture();
  }

  List<String> linesContaining(List<String> logs, String needle) => [
    for (final line in logs)
      if (line.contains(needle)) line,
  ];

  group('probe logging', () {
    // SPEC-0010 REQ "Error Handling Standards": one line, whichever way the
    // probe goes.
    test('a successful probe logs exactly one line', () async {
      serve(heartbeat: () => json(200, heartbeatBody('5.2.0')));
      final service = configured();

      final logs = await logsFrom(service.fetchHeartbeat);

      expect(logs, hasLength(1));
      expect(logs.single, contains('RomM heartbeat ok'));
      expect(logs.single, contains('version=5.2.0'));
    });

    test('a failed probe logs exactly one line', () async {
      serve(heartbeat: () => http.Response('not found', 404));
      final service = configured();

      final logs = await logsFrom(service.fetchHeartbeat);

      expect(logs, hasLength(1));
      expect(logs.single, contains('RomM heartbeat failed'));
      expect(logs.single, contains('reason=status status=404'));
    });

    test('a gate is logged once per connection, not once per probe', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = configured();

      final first = await logsFrom(service.fetchHeartbeat);
      final second = await logsFrom(service.fetchHeartbeat);

      expect(
        linesContaining(first, 'RomM feature gated: feature=playSessions'),
        hasLength(1),
      );
      expect(
        linesContaining(second, 'RomM feature gated:'),
        isEmpty,
        reason: 'the same connection must not repeat a gate line',
      );
    });

    // _gatesLogged used to be cleared only on a base-URL change, so a
    // reconnect to the same server never re-logged the gates and a support log
    // from that session was missing the lines that explain why a feature is
    // unavailable. Governing: SPEC-0010 REQ "Error Handling Standards"
    // ("once per connection per feature").
    test('a reconnect to the same server re-logs the gates', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = configured();
      await service.fetchHeartbeat();

      final logs = await logsFrom(() async {
        service.configure(
          serverUrl: 'https://romm.local',
          username: 'jon',
          password: 's3cret',
        );
      });

      expect(
        linesContaining(logs, 'RomM feature gated: feature=playSessions'),
        hasLength(1),
      );
    });
  });

  group('probing a different server', () {
    // fetchHeartbeat(serverUrl:) cleared the capabilities of the server it was
    // leaving but not the play-session verdict its answers had settled, so a
    // caller that probes without a following configure() inherited it.
    // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe"; ADR-0013,
    // SPEC-0013 REQ "Optional Scope Groups".
    test('clears the previous server play-session state', () async {
      serve(
        heartbeat: () => json(
          200,
          heartbeatBody(
            requests.last.url.host == 'old.local' ? '4.7.0' : '5.2.0',
          ),
        ),
      );
      final service = RommService();

      await service.fetchHeartbeat(serverUrl: 'https://old.local');
      expect(
        service.playtimeSyncAvailable,
        isFalse,
        reason: '4.7.0 predates play sessions',
      );

      await service.fetchHeartbeat(serverUrl: 'https://new.local');

      expect(
        service.playtimeSyncAvailable,
        isTrue,
        reason: 'the new server supports them; the old verdict must not stick',
      );
    });

    test('clears the previous server scope verdicts', () async {
      serve(heartbeat: () => json(200, heartbeatBody('4.7.0')));
      final service = RommService()
        ..configure(
          serverUrl: 'https://old.local',
          username: 'jon',
          password: 's3cret',
        );
      await service.fetchHeartbeat();
      // The version gate settles the playtime group without a request.
      await service.authenticate();
      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.denied);

      await service.fetchHeartbeat(serverUrl: 'https://new.local');

      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.unknown);
    });
  });

  group('request budgets across the scheme fallback', () {
    /// A client whose https attempts fail TLS after [tlsAfter] and whose http
    /// attempts never answer, except `/api/heartbeat` which answers at once so
    /// a login gets past its probe.
    void serveSlowTls({
      required Duration tlsAfter,
      bool heartbeatAnswers = true,
    }) {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          if (heartbeatAnswers && request.url.path == '/api/heartbeat') {
            return json(200, heartbeatBody('5.2.0'));
          }
          if (request.url.scheme == 'https') {
            await Future<void>.delayed(tlsAfter);
            throw const HandshakeException('bad cert');
          }
          await Completer<void>().future;
          throw StateError('unreachable');
        }),
      );
    }

    // The 30 s cap sat *inside* the fallback closure, so each attempt got its
    // own budget and a TLS-misconfigured server kept the login waiting for
    // close to a minute. Same defect shape as #141 fixed for the heartbeat.
    // Governing: ADR-0010; SPEC-0007 REQ "Pairing Code Exchange".
    test('the token grant shares one 30 s budget', () {
      fakeAsync((async) {
        serveSlowTls(tlsAfter: const Duration(seconds: 20));
        final service = RommService()
          ..configure(
            serverUrl: 'romm.local',
            username: 'jon',
            password: 's3cret',
          );

        Object? thrown;
        var settled = false;
        unawaited(() async {
          try {
            await service.authenticate();
          } catch (e) {
            thrown = e;
          }
          settled = true;
        }());

        async.elapse(const Duration(seconds: 29));
        async.flushMicrotasks();
        expect(requests.map((r) => r.url.scheme).toList(), [
          'https',
          'https',
          'http',
        ], reason: 'heartbeat, then the token POST and its http retry');
        expect(settled, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(
          settled,
          isTrue,
          reason: 'both attempts share one 30 s budget, not 30 s each',
        );
        expect((thrown as RommException).message, 'Connection timed out');
      });
    });

    test('the pairing exchange shares one 30 s budget', () {
      fakeAsync((async) {
        serveSlowTls(tlsAfter: const Duration(seconds: 20));
        final service = RommService();

        Object? thrown;
        var settled = false;
        unawaited(() async {
          try {
            await service.exchangePairCode('romm.local', 'ABCD2345');
          } catch (e) {
            thrown = e;
          }
          settled = true;
        }());

        async.elapse(const Duration(seconds: 29));
        async.flushMicrotasks();
        expect(settled, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(settled, isTrue);
        expect((thrown as RommException).message, 'Connection timed out');
      });
    });

    test('the API-key check shares one 30 s budget', () {
      fakeAsync((async) {
        serveSlowTls(tlsAfter: const Duration(seconds: 20));
        final service = RommService()
          ..configure(serverUrl: 'romm.local', apiKey: 'rmm_key');

        Object? thrown;
        var settled = false;
        unawaited(() async {
          try {
            await service.authenticate();
          } catch (e) {
            thrown = e;
          }
          settled = true;
        }());

        async.elapse(const Duration(seconds: 29));
        async.flushMicrotasks();
        expect(settled, isFalse);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(settled, isTrue);
        expect((thrown as RommException).message, 'Connection timed out');
      });
    });

    // Moving the cap outside the fallback left the closure running: a TLS
    // failure landing after the budget expired still rewrote _baseUrl to
    // http:// and fired a request nobody was waiting for. The inner timeout
    // used to suppress that.
    // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe".
    test('a TLS failure after the budget does not downgrade the scheme', () {
      fakeAsync((async) {
        // Later than the 5 s heartbeat cap, so the probe has already returned.
        serveSlowTls(
          tlsAfter: const Duration(seconds: 8),
          heartbeatAnswers: false,
        );
        final service = RommService()
          ..configure(
            serverUrl: 'romm.local',
            username: 'jon',
            password: 's3cret',
          );

        var settled = false;
        unawaited(service.fetchHeartbeat().then((_) => settled = true));

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(settled, isTrue, reason: 'the probe is capped at 5 s');

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(
          requests.map((r) => r.url.scheme).toList(),
          ['https'],
          reason: 'no request may be sent after the call it belonged to ended',
        );
        expect(
          service.baseUrl,
          'https://romm.local',
          reason: 'a late TLS failure must not move the connection to http',
        );
      });
    });
  });
}
