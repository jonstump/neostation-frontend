import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/romm/romm_cover_image_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// Cover fetches are bounded and do not re-ask for dead sources.
///
/// `Image.network` ran on Flutter's own process-wide `HttpClient`, separate
/// from `RommService`'s and with no `maxConnectionsPerHost`, so a screenful of
/// grid tiles opened a socket each against the RomM server — competing with
/// the request fetching the next page of games on the same host. On a large
/// platform that is how the page request came to time out. Issue #531.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A 1x1 PNG, so a "successful" fetch decodes to something real.
  final pngBytes = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  late RommService service;

  RommService connected() {
    final s = RommService();
    s.configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');
    return s;
  }

  setUp(() {
    RommDeadCovers.clear();
    service = connected();
  });

  tearDown(() {
    RommService.debugUseHttpClient(null);
    RommDeadCovers.clear();
  });

  Future<void> resolve(String url) {
    final completer = Completer<void>();
    final stream = RommCoverImage(
      url,
      service,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  group('concurrency bound', () {
    test('never more than maxConcurrent fetches are in flight', () async {
      var inFlight = 0;
      var peak = 0;
      final gate = Completer<void>();

      RommService.debugUseHttpClient(
        MockClient((request) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          // Hold every request open until the whole burst has been issued, so
          // the peak reflects real overlap rather than serial completion.
          await gate.future;
          inFlight--;
          return http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );

      // Far more tiles than the bound, as a screenful of a large platform is.
      const burst = 40;
      final pending = [
        for (var i = 0; i < burst; i++)
          resolve('https://romm.local/cover$i.png'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final peakWhileHeld = peak;
      gate.complete();
      await Future.wait(pending);

      // Deliberately a literal, not `RommCoverImage.maxConcurrent`. Asserting
      // against the constant under test is a tautology: raising it to 999
      // would raise the bar with it and the test would pass unbounded code.
      // Eight leaves room to tune the bound without editing this, and still
      // fails a burst of forty.
      expect(
        peakWhileHeld,
        lessThanOrEqualTo(8),
        reason: '40 tiles must not open 40 sockets to the RomM server',
      );
      expect(
        peakWhileHeld,
        lessThan(burst),
        reason: 'a peak equal to the burst means no bound at all',
      );
      expect(
        peakWhileHeld,
        greaterThan(1),
        reason: 'a bound of one would serialise the grid and be its own bug',
      );
    });

    test('every request still goes out, just not all at once', () async {
      var served = 0;
      RommService.debugUseHttpClient(
        MockClient((request) async {
          served++;
          return http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );

      await Future.wait([
        for (var i = 0; i < 12; i++) resolve('https://romm.local/c$i.png'),
      ]);

      expect(served, 12, reason: 'bounding must not drop work');
    });

    test('a fetch that throws releases its slot', () async {
      // A 404 does not exercise this: `fetchImageBytes` answers null for one,
      // and the `throw` that turns it into an image error sits outside the
      // guarded block, so the slot is already back. A transport failure is
      // what actually unwinds through it — and a gate that leaked there would
      // wedge the grid after `maxConcurrent` bad covers.
      RommService.debugUseHttpClient(
        MockClient((request) async => throw const SocketException('down')),
      );

      await Future.wait([
        for (var i = 0; i < 20; i++) resolve('https://romm.local/x$i.png'),
      ]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the semaphore was not released on failure'),
      );
    });
  });

  group('dead sources are remembered', () {
    test('a miss is recorded', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async => http.Response('nope', 404)),
      );

      await resolve('https://romm.local/missing.png');

      expect(RommDeadCovers.contains('https://romm.local/missing.png'), isTrue);
    });

    test('a hit is not recorded', () async {
      RommService.debugUseHttpClient(
        MockClient(
          (request) async => http.Response.bytes(
            pngBytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );

      await resolve('https://romm.local/present.png');

      expect(
        RommDeadCovers.contains('https://romm.local/present.png'),
        isFalse,
      );
      expect(RommDeadCovers.length, 0);
    });
  });

  group('the provider key', () {
    test('the same URL is one ImageCache entry', () {
      // A key that compared by identity would defeat the memory cache the
      // whole design rests on, re-downloading on every rebuild.
      expect(
        RommCoverImage('https://romm.local/a.png', service),
        RommCoverImage('https://romm.local/a.png', service),
      );
      expect(
        RommCoverImage('https://romm.local/a.png', service).hashCode,
        RommCoverImage('https://romm.local/a.png', service).hashCode,
      );
    });

    test('different URLs are different entries', () {
      expect(
        RommCoverImage('https://romm.local/a.png', service),
        isNot(RommCoverImage('https://romm.local/b.png', service)),
      );
    });
  });
}
