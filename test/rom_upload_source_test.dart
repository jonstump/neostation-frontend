import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/romm/rom_upload_source.dart';

/// [RomUploadSource]: the chunk arithmetic the session headers are derived
/// from, range reads through an injected SAF-like reader, the refusals, and
/// the real `dart:io` backing — inline and through the background isolate.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source",
/// REQ "Concurrency Safety"
void main() {
  const mib = 1024 * 1024;
  const chunk = RomUploadSource.chunkSize;

  /// The byte at [offset] of every fake file here, so a read can be checked
  /// for position as well as length.
  int byteAt(int offset) => offset % 251;

  Uint8List bytesFor(int offset, int length) =>
      Uint8List.fromList(List.generate(length, (i) => byteAt(offset + i)));

  /// A SAF-like file of [size] bytes that answers reads by range only and
  /// records every range asked for.
  RomUploadReaders fakeFile(
    int size,
    List<({int offset, int length})> reads, {
    bool directory = false,
  }) => RomUploadReaders(
    sizeOf: (_) async => size,
    isDirectory: (_) async => directory,
    readRange: (_, offset, length) async {
      reads.add((offset: offset, length: length));
      final available = size - offset;
      return bytesFor(offset, length < available ? length : available);
    },
  );

  group('chunk arithmetic', () {
    test('chunkSize is RomM\'s 10 MiB', () {
      expect(chunk, 10 * mib);
    });

    test('a size that is not a multiple of 10 MiB ends in a remainder', () async {
      final source = await RomUploadSource.open(
        'content://com.android.externalstorage.documents/document/primary%3Aroms%2Fsnes%2FGame.sfc',
        readers: fakeFile(25 * mib, []),
      );
      expect(source.size, 25 * mib);
      expect(source.chunkCount, 3);
      expect([0, 1, 2].map(source.chunkOffset), [0, 10 * mib, 20 * mib]);
      expect([0, 1, 2].map(source.chunkLength), [10 * mib, 10 * mib, 5 * mib]);
    });

    test('a multiple of 10 MiB has no short chunk', () async {
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(20 * mib, []),
      );
      expect(source.chunkCount, 2);
      expect(source.chunkLength(1), 10 * mib);
    });

    test('a file smaller than one chunk is one chunk', () async {
      final source = await RomUploadSource.open(
        '/roms/nes/Tiny.nes',
        readers: fakeFile(1, []),
      );
      expect(source.chunkCount, 1);
      expect(source.chunkLength(0), 1);
    });

    test('a chunk index outside the file is refused', () async {
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(25 * mib, []),
      );
      expect(() => source.chunkLength(3), throwsRangeError);
      expect(() => source.chunkOffset(-1), throwsRangeError);
    });
  });

  group('range reads through an injected reader', () {
    // SPEC-0014 REQ "Upload Source" scenario "SAF file": a 25 MiB content://
    // document read as 10, 10 and 5 MiB, in order.
    test('a 25 MiB SAF document is read as 10, 10 and 5 MiB in order', () async {
      final reads = <({int offset, int length})>[];
      final source = await RomUploadSource.open(
        'content://com.android.externalstorage.documents/document/primary%3Aroms%2Fsnes%2FGame.sfc',
        readers: fakeFile(25 * mib, reads),
      );

      final chunks = [
        for (var i = 0; i < source.chunkCount; i++) await source.readChunk(i),
      ];

      expect(chunks.map((c) => c.length), [10 * mib, 10 * mib, 5 * mib]);
      expect(reads, [
        (offset: 0, length: 10 * mib),
        (offset: 10 * mib, length: 10 * mib),
        (offset: 20 * mib, length: 5 * mib),
      ]);
      // The bytes are the file's, at the right positions.
      expect(chunks[0].first, byteAt(0));
      expect(chunks[1].first, byteAt(10 * mib));
      expect(chunks[1].last, byteAt(20 * mib - 1));
      expect(chunks[2].first, byteAt(20 * mib));
      expect(chunks[2].last, byteAt(25 * mib - 1));
    });

    test('never asks for more than one chunk at a time', () async {
      final reads = <({int offset, int length})>[];
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(25 * mib, reads),
      );
      // Opening reads nothing.
      expect(reads, isEmpty);

      for (var i = 0; i < source.chunkCount; i++) {
        await source.readChunk(i);
      }
      expect(reads.map((r) => r.length).reduce((a, b) => a > b ? a : b), chunk);
      expect(reads.fold<int>(0, (sum, r) => sum + r.length), 25 * mib);
    });

    test('a read outside the file is refused before any I/O', () async {
      final reads = <({int offset, int length})>[];
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(100, reads),
      );
      expect(() => source.read(90, 20), throwsRangeError);
      expect(() => source.read(-1, 5), throwsRangeError);
      expect(reads, isEmpty);
    });

    test('a short read is a failure, not a short chunk', () async {
      final source = await RomUploadSource.open(
        'content://x/document/y',
        readers: RomUploadReaders(
          sizeOf: (_) async => 25 * mib,
          isDirectory: (_) async => false,
          // A SAF provider that stopped answering mid-file.
          readRange: (_, offset, length) async => Uint8List(length ~/ 2),
        ),
      );
      await expectLater(
        source.readChunk(1),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('short read'),
          ),
        ),
      );
    });

    test('a zero-length read returns nothing without I/O', () async {
      final reads = <({int offset, int length})>[];
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(100, reads),
      );
      expect(await source.read(50, 0), isEmpty);
      expect(reads, isEmpty);
    });
  });

  group('refusals', () {
    Future<RomUploadRefusal> refusalOf(
      String path, {
      int size = 4096,
      bool directory = false,
    }) async {
      try {
        await RomUploadSource.open(
          path,
          systemFolder: 'psx',
          readers: fakeFile(size, [], directory: directory),
        );
      } on RomUploadRefusedException catch (e) {
        expect(e.romPath, path);
        expect(e.systemFolder, 'psx');
        return e.reason;
      }
      fail('$path was not refused');
    }

    test('a directory is a multi-file game', () async {
      expect(
        await refusalOf('/roms/psx/Game (Disc 1)', directory: true),
        RomUploadRefusal.multiFile,
      );
    });

    test('a SAF tree URI is a multi-file game', () async {
      // A tree URI names a folder; only document URIs name files.
      expect(
        await refusalOf(
          'content://com.android.externalstorage.documents/tree/primary%3Aroms%2Fpsx',
          directory: true,
        ),
        RomUploadRefusal.multiFile,
      );
    });

    test('a playlist is a multi-file game, not a disc container', () async {
      expect(await refusalOf('/roms/psx/Game.m3u'), RomUploadRefusal.multiFile);
      expect(await refusalOf('/roms/psx/GAME.M3U'), RomUploadRefusal.multiFile);
    });

    test('disc containers are refused by extension', () async {
      for (final ext in const [
        '.cue',
        '.chd',
        '.gdi',
        '.ccd',
        '.cso',
        '.rvz',
      ]) {
        expect(
          await refusalOf('/roms/psx/Game$ext'),
          RomUploadRefusal.discContainer,
          reason: ext,
        );
      }
      expect(
        await refusalOf(
          'content://com.android.externalstorage.documents/document/primary%3Aroms%2Fpsx%2FGame.chd',
        ),
        RomUploadRefusal.discContainer,
      );
    });

    test('an empty file is refused', () async {
      expect(
        await refusalOf('/roms/nes/Empty.nes', size: 0),
        RomUploadRefusal.empty,
      );
    });

    test('a file whose size cannot be read is missing', () async {
      await expectLater(
        RomUploadSource.open(
          '/roms/nes/Gone.nes',
          readers: RomUploadReaders(
            sizeOf: (path) async =>
                throw FileSystemException('no such file', path),
            isDirectory: (_) async => false,
            readRange: (_, _, length) async => Uint8List(length),
          ),
        ),
        throwsA(
          isA<RomUploadRefusedException>().having(
            (e) => e.reason,
            'reason',
            RomUploadRefusal.missing,
          ),
        ),
      );
    });

    test('a bare cartridge dump is accepted', () async {
      final source = await RomUploadSource.open(
        '/roms/snes/Game.sfc',
        readers: fakeFile(4096, []),
      );
      expect(source.size, 4096);
      expect(source.chunkCount, 1);
    });

    test('the exception names the path and reason', () {
      expect(
        RomUploadRefusedException(
          '/roms/psx/Game.m3u',
          RomUploadRefusal.multiFile,
          systemFolder: 'psx',
        ).toString(),
        'RomUploadRefusedException(multiFile): path=/roms/psx/Game.m3u system=psx',
      );
    });
  });

  group('the dart:io backing', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('rom_upload_source_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    File rom(String name, int size) {
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(bytesFor(0, size));
      return file;
    }

    test('reads a 21 MiB file by chunk through a RandomAccessFile', () async {
      final file = rom('Game.sfc', 21 * mib);
      final source = await RomUploadSource.open(
        file.path,
        readers: RomUploadSource.defaultReaders,
      );

      expect(source.size, 21 * mib);
      expect(source.chunkCount, 3);
      final last = await source.readChunk(2);
      expect(last.length, 1 * mib);
      expect(last.first, byteAt(20 * mib));
      expect(last.last, byteAt(21 * mib - 1));

      final middle = await source.readChunk(1);
      expect(middle.length, 10 * mib);
      expect(middle.first, byteAt(10 * mib));
    });

    test('a range read returns exactly the slice asked for', () async {
      final file = rom('Game.nes', 3000);
      final source = await RomUploadSource.open(
        file.path,
        readers: RomUploadSource.defaultReaders,
      );
      expect(await source.read(1000, 7), bytesFor(1000, 7));
    });

    test('a missing file is refused as missing', () async {
      await expectLater(
        RomUploadSource.open(
          '${tempDir.path}${Platform.pathSeparator}Gone.nes',
          readers: RomUploadSource.defaultReaders,
        ),
        throwsA(
          isA<RomUploadRefusedException>().having(
            (e) => e.reason,
            'reason',
            RomUploadRefusal.missing,
          ),
        ),
      );
    });

    test('a directory is refused as multi-file', () async {
      final dir = Directory('${tempDir.path}${Platform.pathSeparator}Game')
        ..createSync();
      await expectLater(
        RomUploadSource.open(dir.path, readers: RomUploadSource.defaultReaders),
        throwsA(
          isA<RomUploadRefusedException>().having(
            (e) => e.reason,
            'reason',
            RomUploadRefusal.multiFile,
          ),
        ),
      );
    });

    // The production path: no injected readers, so the read runs in a
    // background isolate initialised with the root isolate token — the same
    // arrangement that makes SAF reads work off the main isolate on a device.
    // Governing: SPEC-0014 REQ "Concurrency Safety"
    test(
      'without injected readers the read runs through the isolate',
      () async {
        final file = rom('Game.gba', 5000);
        final source = await RomUploadSource.open(file.path);

        expect(source.size, 5000);
        expect(await source.read(4000, 1000), bytesFor(4000, 1000));
        expect(await source.readChunk(0), bytesFor(0, 5000));
      },
    );
  });
}
