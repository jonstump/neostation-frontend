import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';

/// [RommProvider.reachability] (SPEC-0019 "Reachability"): three states driven
/// by what the last request actually did, a re-probe that backs off while
/// offline, and the catch-up that runs when the server comes back.
///
/// No network: the fake service reports through the same transport hooks the
/// real one calls, which is the whole contract between them. The database is
/// an empty in-memory one, because the reconnect catch-up drains the
/// play-session outbox.

/// A service whose heartbeat answers however the test says, through the
/// transport hooks the real service reports on.
class _FakeService extends RommService {
  bool reachable = false;
  int heartbeats = 0;

  @override
  Future<void> fetchHeartbeat({String? serverUrl}) async {
    heartbeats++;
    if (reachable) {
      onTransportSuccess?.call();
    } else {
      onTransportFailure?.call(const SocketException('no route to host'));
    }
  }
}

/// A connected provider with the fake service behind it.
class _TestProvider extends RommProvider {
  final _FakeService fake;
  bool connected = true;

  _TestProvider(this.fake);

  @override
  RommService get service => fake;

  @override
  bool get isConnected => connected;

  @override
  String get serverUrl => 'https://romm.example';
}

_TestProvider _provider() {
  final provider = _TestProvider(_FakeService())..installTransportHooks();
  return provider;
}

void main() {
  // The reconnect path drains the play-session outbox, which reaches for the
  // database; an empty in-memory one keeps that honest without a server.
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseTestHelper();

  setUp(() async {
    await helper.setUp();
    LoggerService.instance.startCapture();
  });
  tearDown(() async {
    LoggerService.instance.takeCapture();
    await helper.tearDown();
  });

  List<String> reachabilityLines() => LoggerService.instance
      .takeCapture()
      .where((l) => l.contains('RomM reachability changed'))
      .toList();

  test('a saved connection starts unknown, not offline', () {
    final provider = _provider();

    expect(provider.reachability, RommReachability.unknown);

    provider.dispose();
  });

  test('any completed request marks the server reachable', () {
    final provider = _provider();
    var notifications = 0;
    provider.addListener(() => notifications++);

    provider.service.onTransportSuccess!();
    provider.service.onTransportSuccess!();

    expect(provider.reachability, RommReachability.online);
    expect(notifications, 1, reason: 'one notify per change, not per request');
    expect(reachabilityLines(), hasLength(1));

    provider.dispose();
  });

  // Governing: SPEC-0019 REQ "Reachability" — scenario "Goes offline"
  test('a timeout goes offline and schedules a re-probe in 60 s', () {
    fakeAsync((async) {
      final provider = _provider();
      provider.service.onTransportSuccess!();

      provider.service.onTransportFailure!(TimeoutException('page 3'));

      expect(provider.reachability, RommReachability.offline);
      expect(provider.reprobeDelay, const Duration(seconds: 60));
      expect(provider.fake.heartbeats, 0, reason: 'not probed yet');

      async.elapse(const Duration(seconds: 59));
      expect(provider.fake.heartbeats, 0);
      async.elapse(const Duration(seconds: 2));
      expect(provider.fake.heartbeats, 1, reason: 'probed at 60 s');

      provider.dispose();
      async.flushTimers();
    });
  });

  test('a status the server answered with is not an outage', () {
    final provider = _provider();
    provider.service.onTransportSuccess!();

    provider.service.onTransportFailure!(StateError('500 from the server'));

    expect(provider.reachability, RommReachability.online);

    provider.dispose();
  });

  test('the re-probe delay doubles to a five-minute ceiling', () {
    fakeAsync((async) {
      final provider = _provider();
      provider.service.onTransportFailure!(const SocketException('down'));

      final delays = <Duration>[provider.reprobeDelay];
      for (var i = 0; i < 6; i++) {
        async.elapse(provider.reprobeDelay + const Duration(seconds: 1));
        delays.add(provider.reprobeDelay);
      }

      expect(delays.take(5), [
        const Duration(seconds: 60),
        const Duration(minutes: 2),
        const Duration(minutes: 4),
        const Duration(minutes: 5),
        const Duration(minutes: 5),
      ]);
      expect(delays.last, RommProvider.maxReprobeDelay);
      expect(provider.reachability, RommReachability.offline);

      provider.dispose();
      async.flushTimers();
    });
  });

  // Governing: SPEC-0019 REQ "Reachability" — scenario "Comes back"
  test('a re-probe that lands after two failures comes back online', () {
    fakeAsync((async) {
      final provider = _provider();
      final reasons = <String>[];
      provider.onReconnected = () async => reasons.add('reconnect');
      provider.service.onTransportSuccess!();
      final flushesWhenOnline = provider.playtimeFlushes;

      provider.service.onTransportFailure!(const SocketException('down'));
      async.elapse(const Duration(seconds: 61));
      async.elapse(const Duration(minutes: 2, seconds: 1));
      expect(provider.fake.heartbeats, 2);
      expect(provider.reachability, RommReachability.offline);
      expect(reasons, isEmpty);

      provider.fake.reachable = true;
      async.elapse(const Duration(minutes: 4, seconds: 1));

      expect(provider.reachability, RommReachability.online);
      expect(reasons, ['reconnect'], reason: 'one refresh, on the transition');
      expect(
        provider.playtimeFlushes,
        flushesWhenOnline + 1,
        reason: 'the play-session outbox is drained on the way back',
      );
      expect(provider.reprobeDelay, RommProvider.firstReprobeDelay);

      // No further probing once it is back.
      final probes = provider.fake.heartbeats;
      async.elapse(const Duration(minutes: 30));
      expect(provider.fake.heartbeats, probes);

      provider.dispose();
      async.flushTimers();
    });
  });

  test('the first success of a session is not a reconnect', () {
    final provider = _provider();
    var reconnects = 0;
    provider.onReconnected = () async => reconnects++;

    provider.service.onTransportSuccess!();

    expect(provider.reachability, RommReachability.online);
    expect(reconnects, 0, reason: 'unknown -> online has nothing to catch up');

    provider.dispose();
  });

  test('a dispose stops the re-probe', () {
    fakeAsync((async) {
      final provider = _provider();
      provider.service.onTransportFailure!(const SocketException('down'));

      provider.dispose();
      async.elapse(const Duration(minutes: 10));

      expect(provider.fake.heartbeats, 0);
    });
  });

  test('a re-probe on a disconnected provider sends nothing', () async {
    final provider = _provider()..connected = false;

    await provider.reprobeNowForTesting();

    expect(provider.fake.heartbeats, 0);

    provider.dispose();
  });
}
