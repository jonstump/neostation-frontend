import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_firmware.dart';
import 'package:neostation/models/romm_firmware_row.dart';
import 'package:neostation/services/romm/romm_firmware_service.dart';
import 'package:neostation/services/romm_service.dart';

/// The local half of the firmware panel: presence decided from `stat` alone,
/// and the streamed md5 the "Verify" action compares.
///
/// Presence must not depend on the bytes — a file of the right name and size
/// reads as present even when its contents are wrong, which is exactly the case
/// Verify exists to catch.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Local Presence And Verification"
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('romm_firmware_presence');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  RommFirmware fw({
    String name = 'scph5501.bin',
    int size = 8,
    String? md5,
    bool missingFromFs = false,
  }) => RommFirmware(
    id: 3,
    platformId: 7,
    fileName: name,
    fileSizeBytes: size,
    md5: md5,
    missingFromFs: missingFromFs,
  );

  Future<File> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  group('presence', () {
    test('a file of the same name and size reads as present', () async {
      await write('scph5501.bin', List<int>.filled(8, 0x41));
      expect(
        await RommFirmwareService.localStateOf(fw(), tmp.path),
        RommFirmwareLocalState.present,
      );
    });

    test('the same name at a different size reads as missing', () async {
      await write('scph5501.bin', List<int>.filled(9, 0x41));
      expect(
        await RommFirmwareService.localStateOf(fw(), tmp.path),
        RommFirmwareLocalState.missing,
      );
    });

    test('contents are irrelevant to presence', () async {
      // Same name, same size, entirely different bytes: still "present".
      await write('scph5501.bin', List<int>.filled(8, 0xFF));
      expect(
        await RommFirmwareService.localStateOf(fw(), tmp.path),
        RommFirmwareLocalState.present,
      );
    });

    test(
      'a size the server never filled in degrades to a name check',
      () async {
        await write('scph5501.bin', List<int>.filled(3, 1));
        expect(
          await RommFirmwareService.localStateOf(fw(size: 0), tmp.path),
          RommFirmwareLocalState.present,
        );
      },
    );

    test('nothing on disk reads as missing', () async {
      expect(
        await RommFirmwareService.localStateOf(fw(), tmp.path),
        RommFirmwareLocalState.missing,
      );
    });

    test('a directory of the right name is not a present file', () async {
      await Directory('${tmp.path}/scph5501.bin').create();
      expect(
        await RommFirmwareService.localStateOf(fw(), tmp.path),
        RommFirmwareLocalState.missing,
      );
    });

    test(
      'a row the server lost reads as serverMissing wherever it is',
      () async {
        await write('scph5501.bin', List<int>.filled(8, 0x41));
        expect(
          await RommFirmwareService.localStateOf(
            fw(missingFromFs: true),
            tmp.path,
          ),
          RommFirmwareLocalState.serverMissing,
        );
      },
    );

    test('no destination is its own state, not "missing"', () async {
      expect(
        await RommFirmwareService.localStateOf(fw(), null),
        RommFirmwareLocalState.unknownDestination,
      );
      expect(
        await RommFirmwareService.localStateOf(fw(), '   '),
        RommFirmwareLocalState.unknownDestination,
      );
    });

    test('describe keeps the listing order and one row per file', () async {
      await write('b.bin', List<int>.filled(8, 2));
      final rows = await RommFirmwareService.describe([
        fw(name: 'a.bin'),
        fw(name: 'b.bin'),
        fw(name: 'c.bin', missingFromFs: true),
      ], tmp.path);
      expect(rows.map((r) => r.firmware.fileName), ['a.bin', 'b.bin', 'c.bin']);
      expect(rows.map((r) => r.state), [
        RommFirmwareLocalState.missing,
        RommFirmwareLocalState.present,
        RommFirmwareLocalState.serverMissing,
      ]);
    });
  });

  group('md5', () {
    test('streams the digest of a file', () async {
      final bytes = List<int>.generate(4096, (i) => i % 251);
      await write('bios.bin', bytes);
      expect(
        await RommFirmwareService.md5OfFile('${tmp.path}/bios.bin'),
        crypto.md5.convert(bytes).toString(),
      );
    });

    test('answers null for a file that is not there', () async {
      expect(
        await RommFirmwareService.md5OfFile('${tmp.path}/absent.bin'),
        isNull,
      );
    });
  });

  group('download guard', () {
    test('a row missing on the server is refused before any request', () async {
      // The client is deliberately unconfigured: it has no base URL to call,
      // so this value can only come from the guard running before the request.
      expect(
        await RommFirmwareService.download(
          fw(missingFromFs: true),
          service: RommService(),
          destDir: tmp.path,
        ),
        RommFirmwareDownloadResult.serverMissing,
      );
    });
  });
}
