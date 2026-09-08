import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';

/// The hash fields RomM carries on a ROM and on each of its files, as the
/// link pass's hash stage reads them (SPEC-0011 "Hash Fields On The ROM
/// Model"): normalized for comparison, absent when the server sent nothing,
/// and unioned across the ROM and its files.

// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"

Map<String, dynamic> _romJson({
  Object? crc,
  Object? md5,
  Object? sha1,
  Object? ra,
  List<Map<String, dynamic>> files = const [],
}) => {
  'id': 7,
  'name': 'Game',
  'platform_id': 1,
  'platform_slug': 'snes',
  'fs_name': 'Game.zip',
  'fs_name_no_ext': 'Game',
  'fs_extension': 'zip',
  'crc_hash': crc,
  'md5_hash': md5,
  'sha1_hash': sha1,
  'ra_hash': ra,
  'files': files,
};

Map<String, dynamic> _fileJson(
  int id, {
  Object? crc,
  Object? md5,
  Object? sha1,
  Object? ra,
  Object? chd,
}) => {
  'id': id,
  'file_name': 'Game.sfc',
  'file_size_bytes': 4096,
  'crc_hash': crc,
  'md5_hash': md5,
  'sha1_hash': sha1,
  'ra_hash': ra,
  'chd_sha1_hash': chd,
};

void main() {
  group('normalizeRommHash', () {
    test('lowercases and trims', () {
      expect(normalizeRommHash('  1A2B3C4D '), '1a2b3c4d');
    });

    test('null, empty and blank all read as no hash', () {
      expect(normalizeRommHash(null), isNull);
      expect(normalizeRommHash(''), isNull);
      expect(normalizeRommHash('   '), isNull);
    });
  });

  group('RommRom.fromJson', () {
    test('parses every hash field, normalized', () {
      final rom = RommRom.fromJson(
        _romJson(
          crc: 'DEADBEEF',
          md5: ' 0123456789ABCDEF0123456789ABCDEF ',
          sha1: 'ABC',
          ra: 'RAHASH',
        ),
      );

      expect(rom.crcHash, 'deadbeef');
      expect(rom.md5Hash, '0123456789abcdef0123456789abcdef');
      expect(rom.sha1Hash, 'abc');
      expect(rom.raHash, 'rahash');
    });

    test('absent and empty fields are null', () {
      final absent = RommRom.fromJson(_romJson());
      expect(absent.crcHash, isNull);
      expect(absent.md5Hash, isNull);
      expect(absent.sha1Hash, isNull);
      expect(absent.raHash, isNull);

      final empty = RommRom.fromJson(
        _romJson(crc: '', md5: '', sha1: '', ra: ''),
      );
      expect(empty.crcHash, isNull);
      expect(empty.md5Hash, isNull);
      expect(empty.allCrc32, isEmpty);
      expect(empty.allMd5, isEmpty);
    });

    test('a ROM built without hashes has none', () {
      const rom = RommRom(
        id: 1,
        name: 'Game',
        platformId: 1,
        platformSlug: 'snes',
        fsName: 'Game.sfc',
        fsNameNoExt: 'Game',
        fsExtension: 'sfc',
      );
      expect(rom.crcHash, isNull);
      expect(rom.allCrc32, isEmpty);
      expect(rom.allMd5, isEmpty);
    });
  });

  group('RommRomFile.fromJson', () {
    test('parses every hash field including chd_sha1_hash', () {
      final file = RommRomFile.fromJson(
        _fileJson(1, crc: 'CAFEBABE', md5: 'M', sha1: 'S', ra: 'R', chd: 'C'),
      );

      expect(file.crcHash, 'cafebabe');
      expect(file.md5Hash, 'm');
      expect(file.sha1Hash, 's');
      expect(file.raHash, 'r');
      expect(file.chdSha1Hash, 'c');
    });

    test('absent fields are null', () {
      final file = RommRomFile.fromJson(_fileJson(1));
      expect(file.crcHash, isNull);
      expect(file.chdSha1Hash, isNull);
    });
  });

  group('allCrc32 / allMd5', () {
    // The spec's own scenario: the ROM and its one file carry the same crc in
    // different cases, and neither has an md5.
    test('unions the ROM-level and file-level values, deduplicated', () {
      final rom = RommRom.fromJson(
        _romJson(
          crc: '1A2B3C4D',
          files: [_fileJson(1, crc: '1a2b3c4d', md5: null)],
        ),
      );

      expect(rom.allCrc32, {'1a2b3c4d'});
      expect(rom.allMd5, isEmpty);
    });

    test('a file with a different hash than the ROM adds it', () {
      final rom = RommRom.fromJson(
        _romJson(
          crc: 'aaaaaaaa',
          md5: 'm1',
          files: [
            _fileJson(1, crc: 'bbbbbbbb', md5: 'm2'),
            _fileJson(2, crc: 'cccccccc'),
          ],
        ),
      );

      expect(rom.allCrc32, {'aaaaaaaa', 'bbbbbbbb', 'cccccccc'});
      expect(rom.allMd5, {'m1', 'm2'});
    });

    test('file-level hashes count when the ROM level has none', () {
      final rom = RommRom.fromJson(
        _romJson(
          files: [_fileJson(1, crc: 'DDDDDDDD', md5: 'M3')],
        ),
      );

      expect(rom.crcHash, isNull);
      expect(rom.allCrc32, {'dddddddd'});
      expect(rom.allMd5, {'m3'});
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Rows Follow The Link Rules"
  group('RommLinkSource.hash', () {
    test('is stored and decoded as "hash"', () {
      expect(RommLinkSource.hash.dbValue, 'hash');
      expect(RommLinkSource.fromDb('hash'), RommLinkSource.hash);
    });

    test('an unknown value still reads as auto', () {
      expect(RommLinkSource.fromDb('sha1'), RommLinkSource.auto);
    });
  });
}
