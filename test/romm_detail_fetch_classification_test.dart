import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/romm_service.dart';

/// The service-layer classification behind the metadata pass's server
/// protection: `fetchRomDetail` must tell an unreachable or rate-limited
/// server apart from a ROM that is genuinely not there, and must parse a
/// `429`'s `Retry-After` (clamped) — so the pass can stop walking a dead
/// server instead of reporting every game as "not found", and can pause for
/// as long as the server asked, but never longer than the cap.
void main() {
  RommService service() {
    final s = RommService();
    s.configure(serverUrl: 'https://romm.invalid', apiKey: 'rmm_test');
    return s;
  }

  Future<RommDetailFetch> detailOf(http.Response response) {
    RommService.debugUseHttpClient(MockClient((_) async => response));
    return service().fetchRomDetail(7);
  }

  tearDown(() => RommService.debugUseHttpClient(null));

  Map<String, dynamic> detailBody() => jsonDecode('{"id": 7}');

  group('fetchRomDetail classification', () {
    test('a 200 with a detail object is a success', () async {
      final fetch = await detailOf(
        http.Response(jsonEncode(detailBody()), 200),
      );
      expect(fetch.detail, isNotNull);
      expect(fetch.miss, isNull);
    });

    test('a 404 is absent — the only "not found" answer', () async {
      final fetch = await detailOf(http.Response('nope', 404));
      expect(fetch.miss, RommDetailMiss.absent);
      expect(fetch.isAbsent, isTrue);
    });

    test('a 410 is absent too', () async {
      final fetch = await detailOf(http.Response('gone', 410));
      expect(fetch.miss, RommDetailMiss.absent);
    });

    test('a 500 is unreachable, not "not found"', () async {
      final fetch = await detailOf(http.Response('boom', 500));
      expect(fetch.miss, RommDetailMiss.unreachable);
    });

    test('a 403 that survived the auth retries is unreachable', () async {
      final fetch = await detailOf(http.Response('forbidden', 403));
      expect(fetch.miss, RommDetailMiss.unreachable);
    });

    test('a 200 with an HTML body is absent (the SPA shell)', () async {
      final fetch = await detailOf(http.Response('<html></html>', 200));
      expect(fetch.miss, RommDetailMiss.absent);
    });

    test('a 429 is rate limited and carries the Retry-After', () async {
      final fetch = await detailOf(
        http.Response('slow down', 429, headers: {'retry-after': '5'}),
      );
      expect(fetch.miss, RommDetailMiss.rateLimited);
      expect(fetch.retryAfter, const Duration(seconds: 5));
    });

    test('a transport failure is unreachable, not "not found"', () async {
      RommService.debugUseHttpClient(
        MockClient((_) async => throw Exception('socket closed')),
      );
      final fetch = await service().fetchRomDetail(7);
      expect(fetch.miss, RommDetailMiss.unreachable);
    });

    test(
      'getRomDetail still collapses every miss to null (its other callers)',
      () async {
        for (final response in [
          http.Response('nope', 404),
          http.Response('boom', 500),
          http.Response('slow down', 429, headers: {'retry-after': '5'}),
        ]) {
          final fetch = await detailOf(response);
          expect(fetch.detail, isNull, reason: '$response');
        }
      },
    );
  });

  group('parseRetryAfter', () {
    test('delay-seconds form is used as-is under the cap', () {
      expect(RommService.parseRetryAfter('5'), const Duration(seconds: 5));
      expect(
        RommService.parseRetryAfter('${RommService.retryAfterCap.inSeconds}'),
        RommService.retryAfterCap,
      );
    });

    test('a delay above the cap is clamped to the cap', () {
      expect(RommService.parseRetryAfter('3600'), RommService.retryAfterCap);
      expect(RommService.parseRetryAfter('999999'), RommService.retryAfterCap);
    });

    test('zero and negative values are zero, not a pause and not an error', () {
      expect(RommService.parseRetryAfter('0'), Duration.zero);
      expect(RommService.parseRetryAfter('-30'), Duration.zero);
    });

    test('a missing or empty header yields null — no invented pause', () {
      expect(RommService.parseRetryAfter(null), isNull);
      expect(RommService.parseRetryAfter(''), isNull);
      expect(RommService.parseRetryAfter('   '), isNull);
    });

    test('malformed values yield null rather than throwing', () {
      expect(RommService.parseRetryAfter('soon'), isNull);
      expect(RommService.parseRetryAfter('1.5'), isNull);
      expect(RommService.parseRetryAfter('Wed, 99 Fob 2026'), isNull);
    });

    test('the HTTP-date form is the delta from now, clamped to the cap', () {
      final now = DateTime.utc(2026, 10, 8, 12, 0, 0);
      // Ten seconds in the future.
      final future = HttpDate.format(now.add(const Duration(seconds: 10)));
      expect(
        RommService.parseRetryAfter(future, now: () => now),
        const Duration(seconds: 10),
      );
      // Far in the future: the cap, not the delta.
      final far = HttpDate.format(now.add(const Duration(hours: 2)));
      expect(
        RommService.parseRetryAfter(far, now: () => now),
        RommService.retryAfterCap,
      );
      // Already past: nothing left to wait.
      final past = HttpDate.format(now.subtract(const Duration(seconds: 10)));
      expect(RommService.parseRetryAfter(past, now: () => now), Duration.zero);
    });
  });
}
