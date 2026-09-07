import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_firmware.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/services/romm_service.dart';

/// [RommService.listFirmware] and [RommService.downloadFirmware] against a
/// scripted HTTP client: the routes they call, the models they parse, the
/// `.part` temp file they leave (or do not leave) behind, and the sentinel kind
/// a 403 carries.
///
/// The service is put in API-key mode on purpose: that mode skips the shared
/// 401/403 re-auth retry, so a scripted 403 reaches the mapping under test in
/// one round trip instead of provoking a token request the mock would have to
/// answer.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Firmware Model And Service"
void main() {
  late Directory tmp;
  final requests = <http.BaseRequest>[];

  RommService service() {
    final s = RommService();
    s.configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');
    return s;
  }

  /// A password-grant connection holding a token the server will reject, so the
  /// shared retry's re-authenticate step actually runs. The API-key service
  /// above cannot exercise it: API-key mode skips the retry entirely.
  RommService passwordService() {
    final s = RommService();
    s.configure(
      serverUrl: 'https://romm.local',
      username: 'ada',
      password: 'hunter2',
      accessToken: 'stale-but-presented',
      tokenExpiresMs:
          DateTime.now().millisecondsSinceEpoch +
          const Duration(hours: 1).inMilliseconds,
    );
    return s;
  }

  /// Answers every request with a buffered [respond] result.
  void serve(FutureOr<http.Response> Function(http.Request) respond) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        return await respond(request);
      }),
    );
  }

  /// Answers every request with a streamed response, so a download can be
  /// cancelled or failed part-way through the body.
  void serveStream(
    FutureOr<http.StreamedResponse> Function(http.BaseRequest) respond,
  ) {
    RommService.debugUseHttpClient(
      MockClient.streaming((request, _) async {
        requests.add(request);
        return await respond(request);
      }),
    );
  }

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  Map<String, dynamic> fwJson({
    required int id,
    required String fileName,
    int size = 512,
    bool missing = false,
  }) => {
    'id': id,
    'platform_id': 3,
    'file_name': fileName,
    'file_size_bytes': size,
    'crc_hash': '',
    'md5_hash': 'ABC123',
    'sha1_hash': null,
    'is_verified': true,
    'missing_from_fs': missing,
  };

  Future<RommException> failure(Future<void> call) async {
    try {
      await call;
    } on RommException catch (e) {
      return e;
    }
    fail('expected a RommException');
  }

  setUp(() {
    requests.clear();
    tmp = Directory.systemTemp.createTempSync('neostation_firmware_test');
  });

  tearDown(() {
    RommService.debugUseHttpClient(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('listFirmware', () {
    test('GETs /api/firmware for the platform and parses every row', () async {
      serve(
        (_) => json(200, [
          fwJson(id: 1, fileName: 'scph5500.bin'),
          fwJson(id: 2, fileName: 'scph5501.bin'),
          fwJson(id: 3, fileName: 'scph5502.bin', missing: true),
        ]),
      );

      final list = await service().listFirmware(3);

      expect(requests.single.method, 'GET');
      expect(
        requests.single.url.toString(),
        'https://romm.local/api/firmware?platform_id=3',
      );
      expect(requests.single.headers['Authorization'], 'Bearer rmm_deadbeef');

      expect(list, hasLength(3));
      expect(list.map((f) => f.fileName), [
        'scph5500.bin',
        'scph5501.bin',
        'scph5502.bin',
      ]);
      expect(list.where((f) => f.missingFromFs).map((f) => f.id), [3]);
      expect(list.first.md5, 'abc123');
    });

    test('accepts the paginated {items: [...]} envelope', () async {
      serve(
        (_) => json(200, {
          'items': [fwJson(id: 9, fileName: 'bios.bin')],
        }),
      );

      final list = await service().listFirmware(3);

      expect(list.single.id, 9);
    });

    test('is empty when the platform has no firmware', () async {
      serve((_) => json(200, const []));

      expect(await service().listFirmware(3), isEmpty);
    });

    test('surfaces a 403 as scopeDenied', () async {
      serve((_) => json(403, {'detail': 'forbidden'}));

      final e = await failure(service().listFirmware(3));

      expect(e.kind, RommErrorKind.scopeDenied);
      expect(e.statusCode, 403);
    });

    test('leaves other failures on the generic kind', () async {
      serve((_) => json(500, {'detail': 'boom'}));

      final e = await failure(service().listFirmware(3));

      expect(e.kind, RommErrorKind.other);
      expect(e.statusCode, 500);
    });
  });

  group('downloadFirmware', () {
    RommFirmware firmware({
      int id = 42,
      String fileName = 'scph5501.bin',
      bool missing = false,
    }) => RommFirmware.fromJson(
      fwJson(id: id, fileName: fileName, missing: missing),
    );

    http.StreamedResponse ok(List<List<int>> chunks) => http.StreamedResponse(
      Stream.fromIterable(chunks),
      200,
      contentLength: chunks.fold<int>(0, (a, c) => a + c.length),
    );

    test('streams the content route into the destination file', () async {
      serveStream((_) => ok([_bytes('BIOS'), _bytes('DATA')]));
      final dest = '${tmp.path}/bios/scph5501.bin';
      final progress = <int>[];

      await service().downloadFirmware(
        firmware(),
        destFilePath: dest,
        onProgress: (received, _) => progress.add(received),
      );

      expect(
        requests.single.url.toString(),
        'https://romm.local/api/firmware/42/content/scph5501.bin',
      );
      expect(File(dest).readAsStringSync(), 'BIOSDATA');
      expect(File('$dest.part').existsSync(), isFalse);
      expect(progress, [4, 8]);
    });

    test('URL-encodes a file name with spaces', () async {
      serveStream((_) => ok([_bytes('x')]));

      await service().downloadFirmware(
        firmware(fileName: 'PS2 bios.bin'),
        destFilePath: '${tmp.path}/PS2 bios.bin',
      );

      expect(
        requests.single.url.toString(),
        'https://romm.local/api/firmware/42/content/PS2%20bios.bin',
      );
    });

    test(
      'removes the .part and writes nothing when cancelled mid-stream',
      () async {
        serveStream(
          (_) => ok([_bytes('AAAA'), _bytes('BBBB'), _bytes('CCCC')]),
        );
        final dest = '${tmp.path}/scph5501.bin';
        var seen = 0;

        final e = await failure(
          service().downloadFirmware(
            firmware(),
            destFilePath: dest,
            shouldCancel: () => seen++ >= 1,
          ),
        );

        expect(e, isA<RommCancelledException>());
        expect(File(dest).existsSync(), isFalse);
        expect(File('$dest.part').existsSync(), isFalse);
      },
    );

    test('removes the .part when the socket drops mid-stream', () async {
      serveStream((_) => http.StreamedResponse(_dropsAfterFirstChunk(), 200));
      final dest = '${tmp.path}/scph5501.bin';

      final e = await failure(
        service().downloadFirmware(firmware(), destFilePath: dest),
      );

      expect(e, isNot(isA<RommCancelledException>()));
      expect(e.message, contains('Download error'));
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('surfaces a 403 as scopeDenied and leaves no .part', () async {
      serveStream((_) => http.StreamedResponse(const Stream.empty(), 403));
      final dest = '${tmp.path}/scph5501.bin';

      final e = await failure(
        service().downloadFirmware(firmware(), destFilePath: dest),
      );

      expect(e.kind, RommErrorKind.scopeDenied);
      expect(e.statusCode, 403);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('replaces an existing destination file', () async {
      serveStream((_) => ok([_bytes('NEW')]));
      final dest = '${tmp.path}/scph5501.bin';
      File(dest).writeAsStringSync('OLD');

      await service().downloadFirmware(firmware(), destFilePath: dest);

      expect(File(dest).readAsStringSync(), 'NEW');
    });

    test('clears a stale .part left by an earlier attempt', () async {
      serveStream((_) => ok([_bytes('NEW')]));
      final dest = '${tmp.path}/scph5501.bin';
      File('$dest.part').writeAsStringSync('half a file');

      await service().downloadFirmware(firmware(), destFilePath: dest);

      expect(File(dest).readAsStringSync(), 'NEW');
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('refuses a missing_from_fs row without sending anything', () async {
      // ADR-0012 Decision Outcome 1: a row the server flagged missing_from_fs
      // is listed but not downloadable. The panel and RommFirmwareService gate
      // it too, but this is the layer no caller can go around.
      serveStream((_) => ok([_bytes('SHOULD NOT BE FETCHED')]));
      final dest = '${tmp.path}/scph5502.bin';

      final e = await failure(
        service().downloadFirmware(
          firmware(fileName: 'scph5502.bin', missing: true),
          destFilePath: dest,
        ),
      );

      expect(e.kind, RommErrorKind.other);
      expect(requests, isEmpty);
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });

  group('a 403 raised while re-authenticating', () {
    /// A password-grant 403 sends the shared retry to `authenticate()`, which
    /// throws its own 403 when the credential no longer works. Mapping *that*
    /// to scopeDenied told a user who had changed their RomM password that
    /// their account has no firmware access.
    ///
    /// Governing: SPEC-0012 REQ "Error Handling Standards"
    http.Response tokenResponse(int status) => status == 200
        ? json(200, {'access_token': 'fresh', 'expires': 3600})
        : json(status, {'detail': 'forbidden'});

    /// Answers the heartbeat, the token grant and everything else separately,
    /// so a test can fail one stage at a time.
    void serveAuth({required int token, required int endpoint}) {
      serve((request) {
        final path = request.url.path;
        if (path.contains('/api/heartbeat')) return json(404, {});
        if (path.contains('/api/token')) return tokenResponse(token);
        return json(endpoint, {'detail': 'forbidden'});
      });
    }

    test('surfaces the credential failure, not scopeDenied', () async {
      serveAuth(token: 403, endpoint: 403);

      final e = await failure(passwordService().listFirmware(3));

      expect(e, isA<RommAuthException>());
      expect(e.kind, isNot(RommErrorKind.scopeDenied));
      expect(e.message, 'Invalid username or password');
    });

    test('still maps the endpoint\'s own 403 to scopeDenied', () async {
      // The credential is fine — the re-auth succeeds — and the firmware route
      // answers 403 again, which is a genuine missing `firmware.read`.
      serveAuth(token: 200, endpoint: 403);

      final e = await failure(passwordService().listFirmware(3));

      expect(e, isNot(isA<RommAuthException>()));
      expect(e.kind, RommErrorKind.scopeDenied);
      expect(e.statusCode, 403);
    });
  });

  group('downloadRom (shares the extracted streaming helper)', () {
    test('still streams the ROM content route into place', () async {
      serveStream(
        (_) => http.StreamedResponse(
          Stream.fromIterable([_bytes('ROM')]),
          200,
          contentLength: 3,
        ),
      );
      final dest = '${tmp.path}/game.sfc';

      await service().downloadRom(
        const RommRom(
          id: 7,
          name: 'Game',
          platformId: 1,
          platformSlug: 'snes',
          fsName: 'game.sfc',
          fsNameNoExt: 'game',
          fsExtension: 'sfc',
        ),
        destFilePath: dest,
      );

      expect(
        requests.single.url.toString(),
        'https://romm.local/api/roms/7/content/game.sfc',
      );
      expect(File(dest).readAsStringSync(), 'ROM');
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A body that delivers one chunk and then fails, standing in for a socket
/// that drops part-way through a transfer.
Stream<List<int>> _dropsAfterFirstChunk() async* {
  yield _bytes('AAAA');
  throw const SocketException('connection reset by peer');
}
