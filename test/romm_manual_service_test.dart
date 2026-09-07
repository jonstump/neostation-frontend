import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/services/romm/romm_manual_cache.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

/// The manual URL, the streamed download, the extension refusal, and the cache
/// rules that keep a second open off the network.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
void main() {
  late Directory tmp;
  final requests = <http.Request>[];

  RommService service({String serverUrl = 'https://romm.local'}) {
    final s = RommService();
    s.configure(
      serverUrl: serverUrl,
      username: 'testuser',
      password: 's3cret',
      accessToken: 'token',
    );
    return s;
  }

  RommRom rom({
    int id = 42,
    String? pathManual = 'roms/snes/Chrono Trigger/manual.pdf',
  }) => RommRom(
    id: id,
    name: 'Chrono Trigger',
    platformId: 3,
    platformSlug: 'snes',
    fsName: 'Chrono Trigger.sfc',
    fsNameNoExt: 'Chrono Trigger',
    fsExtension: 'sfc',
    pathManual: pathManual,
    hasManual: pathManual != null,
  );

  /// Installs a client answering every request with [respond].
  void serve(http.Response Function(http.Request) respond) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
  }

  setUp(() {
    requests.clear();
    tmp = Directory.systemTemp.createTempSync('romm_manual_test');
  });

  tearDown(() {
    RommService.debugUseHttpClient(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('manualUrlFor', () {
    test('builds the static resource URL', () {
      expect(
        service().manualUrlFor(rom(pathManual: 'manuals/ct.pdf')),
        'https://romm.local/assets/romm/resources/manuals/ct.pdf',
      );
    });

    test('percent-encodes each path segment, keeping the separators', () {
      expect(
        service().manualUrlFor(rom()),
        'https://romm.local/assets/romm/resources/roms/snes/'
        'Chrono%20Trigger/manual.pdf',
      );
    });

    test('a leading slash on path_manual does not double up', () {
      expect(
        service().manualUrlFor(rom(pathManual: '/manuals/ct.pdf')),
        'https://romm.local/assets/romm/resources/manuals/ct.pdf',
      );
    });

    test('is null when the ROM has no manual', () {
      expect(service().manualUrlFor(rom(pathManual: null)), isNull);
    });
  });

  group('downloadManual', () {
    test('streams to a .part file and renames it into place', () async {
      serve((_) => http.Response('%PDF-1.4 body', 200));
      final dest = p.join(tmp.path, 'manuals', '42.pdf');

      final progress = <int>[];
      await service().downloadManual(
        rom(),
        destFilePath: dest,
        onProgress: (received, _) => progress.add(received),
      );

      expect(File(dest).readAsStringSync(), '%PDF-1.4 body');
      expect(File('$dest.part').existsSync(), isFalse);
      expect(progress, isNotEmpty);
      expect(requests.single.url.path, contains('/assets/romm/resources/'));
    });

    test('refuses an unsupported extension without a request', () async {
      serve((_) => http.Response('nope', 200));

      await expectLater(
        service().downloadManual(
          rom(pathManual: 'manuals/ct.docx'),
          destFilePath: p.join(tmp.path, 'manuals', '42.docx'),
        ),
        throwsA(isA<RommException>()),
      );
      expect(requests, isEmpty);
    });

    test('refuses a ROM with no manual without a request', () async {
      serve((_) => http.Response('nope', 200));

      await expectLater(
        service().downloadManual(
          rom(pathManual: null),
          destFilePath: p.join(tmp.path, 'manuals', '42.pdf'),
        ),
        throwsA(isA<RommException>()),
      );
      expect(requests, isEmpty);
    });

    test('a 404 carries the status and leaves no file behind', () async {
      serve((_) => http.Response('not found', 404));
      final dest = p.join(tmp.path, 'manuals', '42.pdf');

      await expectLater(
        service().downloadManual(rom(), destFilePath: dest),
        throwsA(
          isA<RommException>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('a cancelled download cleans up its temp file', () async {
      serve((_) => http.Response('%PDF-1.4 body', 200));
      final dest = p.join(tmp.path, 'manuals', '42.pdf');

      await expectLater(
        service().downloadManual(
          rom(),
          destFilePath: dest,
          shouldCancel: () => true,
        ),
        throwsA(isA<RommCancelledException>()),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });

  group('RommManualCache', () {
    test('caches under <mediaCache>/manuals/<romId>.<ext>', () {
      expect(
        RommManualCache.pathFor(mediaRoot: '/m', romId: 42, extension: 'pdf'),
        p.join('/m', 'manuals', '42.pdf'),
      );
    });

    test('a second open reads the cache and makes no request', () async {
      var served = 0;
      serve((_) {
        served++;
        return http.Response('%PDF-1.4 body', 200);
      });

      final first = await RommManualCache.ensure(
        service: service(),
        rom: rom(),
        mediaRoot: tmp.path,
      );
      expect(served, 1);

      final second = await RommManualCache.ensure(
        service: service(),
        rom: rom(),
        mediaRoot: tmp.path,
      );
      expect(second, first);
      expect(served, 1, reason: 'a cached manual must not be re-fetched');
    });

    test('refresh re-downloads over the cached copy', () async {
      var served = 0;
      serve((_) {
        served++;
        return http.Response('body $served', 200);
      });

      await RommManualCache.ensure(
        service: service(),
        rom: rom(),
        mediaRoot: tmp.path,
      );
      final path = await RommManualCache.ensure(
        service: service(),
        rom: rom(),
        mediaRoot: tmp.path,
        refresh: true,
      );

      expect(served, 2);
      expect(File(path).readAsStringSync(), 'body 2');
    });

    test('a refresh that changes the type drops the stale sibling', () async {
      serve((_) => http.Response('text body', 200));
      final stale = File(
        RommManualCache.pathFor(
          mediaRoot: tmp.path,
          romId: 42,
          extension: 'pdf',
        ),
      );
      stale.createSync(recursive: true);
      stale.writeAsStringSync('old pdf');

      final path = await RommManualCache.ensure(
        service: service(),
        rom: rom(pathManual: 'manuals/ct.txt'),
        mediaRoot: tmp.path,
        refresh: true,
      );

      expect(p.extension(path), '.txt');
      expect(stale.existsSync(), isFalse);
    });

    test('cachedPathFor finds any accepted extension, or nothing', () async {
      expect(
        await RommManualCache.cachedPathFor(mediaRoot: tmp.path, romId: 42),
        isNull,
      );

      final md = File(
        RommManualCache.pathFor(
          mediaRoot: tmp.path,
          romId: 42,
          extension: 'md',
        ),
      );
      md.createSync(recursive: true);
      md.writeAsStringSync('# Manual');

      expect(
        await RommManualCache.cachedPathFor(mediaRoot: tmp.path, romId: 42),
        md.path,
      );
    });
  });
}
