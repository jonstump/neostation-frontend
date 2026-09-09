import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm/rom_upload_source.dart';
import 'package:neostation/services/romm_service.dart';

/// [RommService.uploadRom] over a scripted HTTP client: the exact `start`
/// headers, the chunk sequence and sizes, the retry and its backoff, retry
/// exhaustion, the collision, the gates, cancel, disconnect, the single
/// instance guard and the `complete` timeout.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Chunked Upload
/// Session", REQ "Error Handling Standards", REQ "Concurrency Safety"
void main() {
  const mib = 1024 * 1024;
  final requests = <http.Request>[];
  final sleeps = <Duration>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// Every scope an unrestricted client token holds.
  const allScopes = [
    'me.read',
    'roms.read',
    'platforms.read',
    'assets.read',
    'assets.write',
    'collections.read',
    'firmware.read',
    'roms.write',
    'tasks.run',
  ];

  /// A RomM on [version] whose key holds [scopes], answering everything
  /// under `/api/roms/upload` through [upload].
  void serve(
    FutureOr<http.Response> Function(http.Request) upload, {
    String version = '5.1.0',
    List<String> scopes = allScopes,
  }) {
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
              'oauth_scopes': scopes,
            });
          default:
            return await upload(request);
        }
      }),
    );
  }

  /// The requests this test cares about: an API-key connection verifies
  /// itself once (heartbeat plus `GET /api/users/me`) before its first
  /// authenticated call.
  List<http.Request> calls() => [
    for (final r in requests)
      if (!const {'/api/heartbeat', '/api/users/me'}.contains(r.url.path)) r,
  ];

  List<http.Request> puts() => [
    for (final r in calls())
      if (r.method == 'PUT') r,
  ];

  List<int> putIndexes() => [
    for (final r in puts()) int.parse(r.headers['x-chunk-index']!),
  ];

  bool sent(String method, String path) =>
      calls().any((r) => r.method == method && r.url.path == path);

  /// The happy-path server. [onPut] may answer a chunk itself (or throw) —
  /// it gets the chunk index and how many times that chunk has been tried.
  FutureOr<http.Response> Function(http.Request) server({
    FutureOr<http.Response?> Function(http.Request r, int index, int attempt)?
    onPut,
    http.Response Function()? onStart,
    FutureOr<http.Response> Function()? onComplete,
  }) {
    final attempts = <int, int>{};
    return (r) async {
      final path = r.url.path;
      if (r.method == 'POST' && path == '/api/roms/upload/start') {
        return onStart?.call() ?? json(200, {'upload_id': 'u-1'});
      }
      if (r.method == 'PUT' && path == '/api/roms/upload/u-1') {
        final index = int.parse(r.headers['x-chunk-index']!);
        final attempt = attempts[index] = (attempts[index] ?? 0) + 1;
        final answer = await onPut?.call(r, index, attempt);
        return answer ?? json(200, {'received': index + 1, 'total': 3});
      }
      if (r.method == 'POST' && path == '/api/roms/upload/u-1/complete') {
        return await onComplete?.call() ?? http.Response('', 201);
      }
      if (r.method == 'POST' && path == '/api/roms/upload/u-1/cancel') {
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    };
  }

  RommService service() =>
      RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');

  /// A fake ROM of [size] bytes whose byte at offset `o` is `o % 251`.
  Future<RomUploadSource> source({int size = 25 * mib}) => RomUploadSource.open(
    'content://com.android.externalstorage.documents/document/primary%3Aroms%2Fsnes%2FGame.sfc',
    readers: RomUploadReaders(
      sizeOf: (_) async => size,
      isDirectory: (_) async => false,
      readRange: (_, offset, length) async {
        final bytes = Uint8List(length);
        for (var i = 0; i < length; i++) {
          bytes[i] = (offset + i) % 251;
        }
        return bytes;
      },
    ),
  );

  Matcher failsWith(RommErrorKind kind, {int? status}) => throwsA(
    isA<RommException>()
        .having((e) => e.kind, 'kind', kind)
        .having((e) => e.statusCode, 'statusCode', status),
  );

  setUp(() {
    requests.clear();
    sleeps.clear();
    RommService.debugUseSleeper((d) async => sleeps.add(d));
  });

  tearDown(() {
    RommService.debugUseHttpClient(null);
    RommService.debugUseSleeper(null);
  });

  group('the session', () {
    test('sends start, every chunk in order, then complete', () async {
      serve(server());
      final progress = <(int, int)>[];

      final uploaded = await service().uploadRom(
        await source(),
        platformId: 7,
        fileName: 'Game.sfc',
        onProgress: (sent, total) => progress.add((sent, total)),
      );

      expect(uploaded, isTrue);
      final sequence = calls();
      expect(sequence.map((r) => '${r.method} ${r.url.path}'), [
        'POST /api/roms/upload/start',
        'PUT /api/roms/upload/u-1',
        'PUT /api/roms/upload/u-1',
        'PUT /api/roms/upload/u-1',
        'POST /api/roms/upload/u-1/complete',
      ]);

      // SPEC-0014 REQ "Chunked Upload Session": the four headers, chunks =
      // ceil(25 MiB / 10 MiB) = 3.
      final start = sequence.first;
      expect(start.headers['x-upload-platform'], '7');
      expect(start.headers['x-upload-filename'], 'Game.sfc');
      expect(start.headers['x-upload-total-size'], '${25 * mib}');
      expect(start.headers['x-upload-total-chunks'], '3');
      expect(start.headers['authorization'], 'Bearer rmm_deadbeef');

      // Every chunk but the last is exactly 10 MiB — the server recomputes
      // the size from the headers and rejects anything else.
      expect(putIndexes(), [0, 1, 2]);
      expect(puts().map((r) => r.bodyBytes.length), [
        10 * mib,
        10 * mib,
        5 * mib,
      ]);
      for (final put in puts()) {
        expect(put.headers['content-type'], 'application/octet-stream');
        expect(put.headers['authorization'], 'Bearer rmm_deadbeef');
      }
      // The bytes are the file's, in order.
      expect(puts()[1].bodyBytes.first, (10 * mib) % 251);
      expect(puts()[2].bodyBytes.last, (25 * mib - 1) % 251);

      expect(progress, [
        (0, 25 * mib),
        (10 * mib, 25 * mib),
        (20 * mib, 25 * mib),
        (25 * mib, 25 * mib),
      ]);
      expect(sleeps, isEmpty);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isFalse);
    });

    test('a file that divides evenly sends full chunks only', () async {
      serve(server());

      await service().uploadRom(
        await source(size: 20 * mib),
        platformId: 7,
        fileName: 'Game.sfc',
      );

      expect(calls().first.headers['x-upload-total-chunks'], '2');
      expect(puts().map((r) => r.bodyBytes.length), [10 * mib, 10 * mib]);
    });

    test('a non-Latin-1 name is percent-encoded for the header', () async {
      serve(server());

      await service().uploadRom(
        await source(size: 1),
        platformId: 7,
        fileName: 'ゲーム.sfc',
      );

      expect(
        calls().first.headers['x-upload-filename'],
        Uri.encodeComponent('ゲーム.sfc'),
      );
    });

    test('an upload id under another key is still found', () async {
      serve(server(onStart: () => json(200, {'id': 'u-1'})));
      expect(
        await service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        isTrue,
      );
    });

    test('a start the server never answers is a typed failure', () async {
      serve((r) async {
        if (r.url.path == '/api/roms/upload/start') {
          throw const SocketException('connection refused');
        }
        return http.Response('not found', 404);
      });

      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.uploadFailed),
      );
      // No session was opened, so no chunk and no cancel.
      expect(calls().map((r) => r.url.path), ['/api/roms/upload/start']);
    });

    test('a start answer without an upload id fails without a chunk', () async {
      serve(server(onStart: () => json(200, {'ok': true})));
      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.uploadFailed, status: 200),
      );
      expect(puts(), isEmpty);
    });
  });

  group('retries', () {
    // SPEC-0014 scenario "Retry then success".
    test(
      'a chunk that fails once on a socket error is re-sent after 1 s',
      () async {
        serve(
          server(
            onPut: (_, index, attempt) {
              if (index == 1 && attempt == 1) {
                throw const SocketException('connection reset');
              }
              return null;
            },
          ),
        );

        final uploaded = await service().uploadRom(
          await source(),
          platformId: 7,
          fileName: 'Game.sfc',
        );

        expect(uploaded, isTrue);
        expect(putIndexes(), [0, 1, 1, 2]);
        expect(sleeps, [const Duration(seconds: 1)]);
        expect(sent('POST', '/api/roms/upload/u-1/complete'), isTrue);
        expect(sent('POST', '/api/roms/upload/u-1/cancel'), isFalse);
      },
    );

    test('a 5xx is retried with doubling backoff', () async {
      serve(
        server(
          onPut: (_, index, attempt) =>
              index == 0 && attempt <= 2 ? http.Response('busy', 503) : null,
        ),
      );

      await service().uploadRom(
        await source(size: 1),
        platformId: 7,
        fileName: 'Game.sfc',
      );

      expect(putIndexes(), [0, 0, 0]);
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    // SPEC-0014 scenario "Retry exhaustion": four failures → cancel → a
    // failure naming file and chunk.
    test('a chunk that fails four times sends cancel and fails', () async {
      serve(
        server(
          onPut: (_, index, _) =>
              index == 1 ? http.Response('disk full', 500) : null,
        ),
      );

      await expectLater(
        service().uploadRom(
          await source(),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.uploadFailed)
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('file=Game.sfc'))
              .having((e) => e.message, 'message', contains('chunk=1')),
        ),
      );

      expect(putIndexes(), [0, 1, 1, 1, 1]);
      expect(sleeps, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
      expect(sent('POST', '/api/roms/upload/u-1/complete'), isFalse);
    });

    test('a 4xx on a chunk is not retried', () async {
      serve(
        server(
          onPut: (_, index, _) =>
              index == 0 ? json(400, {'detail': 'Invalid chunk size'}) : null,
        ),
      );

      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.uploadFailed, status: 400),
      );

      expect(putIndexes(), [0]);
      expect(sleeps, isEmpty);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });

    test('the backoff is 1 s × 2^attempt', () {
      expect(RommService.uploadRetryBackoff(0), const Duration(seconds: 1));
      expect(RommService.uploadRetryBackoff(1), const Duration(seconds: 2));
      expect(RommService.uploadRetryBackoff(2), const Duration(seconds: 4));
      expect(RommService.uploadChunkRetries, 3);
    });
  });

  group('collision', () {
    // SPEC-0014 scenario "Collision".
    test(
      'a 400 on start naming the file is alreadyExists with no chunk sent',
      () async {
        serve(
          server(
            onStart: () =>
                json(400, {'detail': 'File Game.sfc already exists'}),
          ),
        );

        await expectLater(
          service().uploadRom(
            await source(),
            platformId: 7,
            fileName: 'Game.sfc',
          ),
          failsWith(RommErrorKind.alreadyExists, status: 400),
        );

        expect(puts(), isEmpty);
        // No session was opened, so there is nothing to cancel.
        expect(calls().map((r) => r.url.path), ['/api/roms/upload/start']);
      },
    );

    test('a 409 on complete naming the file is alreadyExists', () async {
      serve(
        server(
          onComplete: () =>
              json(409, {'detail': 'File Game.sfc already exists'}),
        ),
      );

      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.alreadyExists, status: 409),
      );
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });

    test('a 400 that names nothing of the kind is a plain failure', () async {
      serve(server(onStart: () => json(400, {'detail': 'Invalid platform'})));

      await expectLater(
        service().uploadRom(
          await source(),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.uploadFailed, status: 400),
      );
    });
  });

  group('gates', () {
    test('a server before 4.8.0 gets no request', () async {
      serve(server(), version: '4.7.0');
      final svc = service();
      await svc.authenticate();
      expect(
        svc.supports(RommFeature.romUpload),
        RommFeatureSupport.unsupported,
      );
      requests.clear();

      final uploaded = await svc.uploadRom(
        await source(),
        platformId: 7,
        fileName: 'Game.sfc',
      );

      expect(uploaded, isFalse);
      expect(requests, isEmpty);
    });

    test('a 4.8.0 server is offered the session', () async {
      serve(server(), version: '4.8.0');
      expect(
        await service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        isTrue,
      );
    });

    test('a key without roms.write gets no request', () async {
      serve(
        server(),
        scopes: [
          for (final s in allScopes)
            if (s != 'roms.write') s,
        ],
      );
      final svc = service();
      await svc.authenticate();
      expect(svc.hasScope(RommScopeGroup.romsWrite), RommScopeState.denied);
      requests.clear();

      final uploaded = await svc.uploadRom(
        await source(),
        platformId: 7,
        fileName: 'Game.sfc',
      );

      expect(uploaded, isFalse);
      expect(requests, isEmpty);
    });

    test('a 403 on start settles the group as denied', () async {
      serve(server(onStart: () => http.Response('forbidden', 403)));
      final svc = service();

      await expectLater(
        svc.uploadRom(await source(), platformId: 7, fileName: 'Game.sfc'),
        failsWith(RommErrorKind.scopeDenied, status: 403),
      );

      expect(svc.hasScope(RommScopeGroup.romsWrite), RommScopeState.denied);
      expect(puts(), isEmpty);
    });

    test(
      'a 403 on a chunk settles the group as denied and is not retried',
      () async {
        serve(server(onPut: (_, _, _) => http.Response('forbidden', 403)));
        final svc = service();

        await expectLater(
          svc.uploadRom(
            await source(size: 1),
            platformId: 7,
            fileName: 'Game.sfc',
          ),
          failsWith(RommErrorKind.scopeDenied, status: 403),
        );

        expect(svc.hasScope(RommScopeGroup.romsWrite), RommScopeState.denied);
        expect(putIndexes(), [0]);
        expect(sleeps, isEmpty);
      },
    );
  });

  group('cancel', () {
    test(
      'shouldCancel between chunks sends cancel and skips complete',
      () async {
        serve(server());
        var sentChunks = 0;

        await expectLater(
          service().uploadRom(
            await source(),
            platformId: 7,
            fileName: 'Game.sfc',
            onProgress: (sent, _) => sentChunks = sent ~/ (10 * mib),
            // Cancel once the first chunk is on the server.
            shouldCancel: () => sentChunks >= 1,
          ),
          failsWith(RommErrorKind.uploadCancelled),
        );

        expect(putIndexes(), [0]);
        expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
        expect(sent('POST', '/api/roms/upload/u-1/complete'), isFalse);
      },
    );

    test('shouldCancel before the first chunk still opens no chunk', () async {
      serve(server());

      await expectLater(
        service().uploadRom(
          await source(),
          platformId: 7,
          fileName: 'Game.sfc',
          shouldCancel: () => true,
        ),
        failsWith(RommErrorKind.uploadCancelled),
      );

      expect(puts(), isEmpty);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });

    test('shouldCancel during a retry backoff cancels', () async {
      var cancel = false;
      RommService.debugUseSleeper((d) async {
        sleeps.add(d);
        cancel = true;
      });
      serve(
        server(
          onPut: (_, _, attempt) =>
              attempt == 1 ? http.Response('busy', 503) : null,
        ),
      );

      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
          shouldCancel: () => cancel,
        ),
        failsWith(RommErrorKind.uploadCancelled),
      );

      expect(putIndexes(), [0]);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });

    // SPEC-0014 scenario "Disconnect mid-batch": the open session stops.
    test('a disconnect while the session is open cancels it', () async {
      late RommService svc;
      serve(
        server(
          onPut: (_, index, _) {
            if (index == 0) svc.forgetServerState();
            return null;
          },
        ),
      );
      svc = service();

      await expectLater(
        svc.uploadRom(await source(), platformId: 7, fileName: 'Game.sfc'),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.uploadCancelled)
              .having((e) => e.message, 'message', contains('disconnected')),
        ),
      );

      expect(putIndexes(), [0]);
      expect(sent('POST', '/api/roms/upload/u-1/complete'), isFalse);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });

    test('a cancel the server refuses is logged, not thrown', () async {
      serve((r) async {
        if (r.url.path.endsWith('/cancel')) return http.Response('gone', 404);
        return server(onStart: () => json(200, {'upload_id': 'u-1'}))(r);
      });

      await expectLater(
        service().uploadRom(
          await source(),
          platformId: 7,
          fileName: 'Game.sfc',
          shouldCancel: () => true,
        ),
        failsWith(RommErrorKind.uploadCancelled),
      );
    });
  });

  group('single instance', () {
    test('a second upload while one is in flight throws uploadBusy', () async {
      final gate = Completer<void>();
      final firstChunkSeen = Completer<void>();
      serve(
        server(
          onPut: (_, index, _) async {
            // Hold only the first session's first chunk; the one that runs
            // after it must go straight through.
            if (index == 0 && !firstChunkSeen.isCompleted) {
              firstChunkSeen.complete();
              await gate.future;
            }
            return null;
          },
        ),
      );
      final svc = service();

      final first = svc.uploadRom(
        await source(),
        platformId: 7,
        fileName: 'Game.sfc',
      );
      await firstChunkSeen.future;
      expect(svc.uploadInProgress, isTrue);

      await expectLater(
        svc.uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Other.sfc',
        ),
        failsWith(RommErrorKind.uploadBusy),
      );
      // The refusal sent nothing: only the first session's requests exist.
      expect(
        calls().where((r) => r.headers['x-upload-filename'] == 'Other.sfc'),
        isEmpty,
      );

      gate.complete();
      expect(await first, isTrue);
      expect(svc.uploadInProgress, isFalse);

      // Once the first is done the next one runs.
      expect(
        await svc.uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Other.sfc',
        ),
        isTrue,
      );
    });

    test('the guard is released after a failure', () async {
      serve(server(onStart: () => http.Response('boom', 500)));
      final svc = service();

      await expectLater(
        svc.uploadRom(await source(), platformId: 7, fileName: 'Game.sfc'),
        failsWith(RommErrorKind.uploadFailed, status: 500),
      );
      expect(svc.uploadInProgress, isFalse);
    });
  });

  group('complete', () {
    test('waits at least 600 s for the server to assemble the file', () {
      expect(
        RommService.uploadCompleteTimeout,
        greaterThanOrEqualTo(const Duration(seconds: 600)),
      );

      fakeAsync((async) {
        final never = Completer<http.Response>();
        serve(server(onComplete: () => never.future));
        Object? failure;
        var done = false;
        RomUploadSource.open(
          '/roms/snes/Game.sfc',
          readers: RomUploadReaders(
            sizeOf: (_) async => 1,
            isDirectory: (_) async => false,
            readRange: (_, _, length) async => Uint8List(length),
          ),
        ).then(
          (src) => service()
              .uploadRom(src, platformId: 7, fileName: 'Game.sfc')
              .then<void>(
                (_) {
                  done = true;
                },
                onError: (Object e) {
                  failure = e;
                },
              ),
        );

        async.elapse(const Duration(seconds: 599));
        expect(done, isFalse);
        expect(failure, isNull, reason: 'complete must not time out early');
        expect(sent('POST', '/api/roms/upload/u-1/complete'), isTrue);

        async.elapse(RommService.uploadCompleteTimeout);
        async.flushMicrotasks();
        expect(
          failure,
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.uploadFailed,
          ),
        );
        expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
      });
    });

    test('a 5xx on complete sends cancel and fails', () async {
      serve(server(onComplete: () => http.Response('boom', 500)));

      await expectLater(
        service().uploadRom(
          await source(size: 1),
          platformId: 7,
          fileName: 'Game.sfc',
        ),
        failsWith(RommErrorKind.uploadFailed, status: 500),
      );
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });
  });

  group('the source', () {
    test('a read that comes up short fails the upload and cancels', () async {
      serve(server());
      final src = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: RomUploadReaders(
          sizeOf: (_) async => 25 * mib,
          isDirectory: (_) async => false,
          readRange: (_, offset, length) async =>
              offset == 0 ? Uint8List(length) : Uint8List(length ~/ 2),
        ),
      );

      await expectLater(
        service().uploadRom(src, platformId: 7, fileName: 'Game.sfc'),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.uploadFailed)
              .having((e) => e.message, 'message', contains('short read')),
        ),
      );
      expect(putIndexes(), [0]);
      expect(sent('POST', '/api/roms/upload/u-1/cancel'), isTrue);
    });
  });
}
