import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_firmware.dart';

/// [RommFirmware.fromJson] against RomM's `FirmwareSchema`.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Firmware Model And Service"
void main() {
  Map<String, dynamic> schema({
    Object? id = 12,
    Object? platformId = 3,
    Object? fileName = 'scph5501.bin',
    Object? fileSizeBytes = 524288,
    Object? crc = '0BAD1BAD',
    Object? md5 = 'D786A9AA0E1FBE9C1B4C5B2A3E4F5061',
    Object? sha1 = 'AABBCCDDEEFF00112233445566778899AABBCCDD',
    Object? isVerified = true,
    Object? missingFromFs = false,
  }) => {
    'id': id,
    'platform_id': platformId,
    'file_name': fileName,
    'file_size_bytes': fileSizeBytes,
    'crc_hash': crc,
    'md5_hash': md5,
    'sha1_hash': sha1,
    'is_verified': isVerified,
    'missing_from_fs': missingFromFs,
  };

  group('RommFirmware.fromJson', () {
    test('maps every FirmwareSchema field', () {
      final fw = RommFirmware.fromJson(schema());

      expect(fw.id, 12);
      expect(fw.platformId, 3);
      expect(fw.fileName, 'scph5501.bin');
      expect(fw.fileSizeBytes, 524288);
      expect(fw.isVerified, isTrue);
      expect(fw.missingFromFs, isFalse);
    });

    test('lowercases the hashes so a local digest compares equal', () {
      final fw = RommFirmware.fromJson(schema());

      expect(fw.crc32, '0bad1bad');
      expect(fw.md5, 'd786a9aa0e1fbe9c1b4c5b2a3e4f5061');
      expect(fw.sha1, 'aabbccddeeff00112233445566778899aabbccdd');
    });

    test('collapses blank and absent hashes to null', () {
      final blank = RommFirmware.fromJson(
        schema(crc: '', md5: '   ', sha1: null),
      );
      expect(blank.crc32, isNull);
      expect(blank.md5, isNull);
      expect(blank.sha1, isNull);

      final absent = RommFirmware.fromJson(const {
        'id': 1,
        'platform_id': 2,
        'file_name': 'bios.bin',
        'file_size_bytes': 10,
      });
      expect(absent.crc32, isNull);
      expect(absent.md5, isNull);
      expect(absent.sha1, isNull);
      expect(absent.isVerified, isFalse);
      expect(absent.missingFromFs, isFalse);
    });

    test('tolerates numeric and string booleans', () {
      expect(
        RommFirmware.fromJson(
          schema(isVerified: 1, missingFromFs: 0),
        ).isVerified,
        isTrue,
      );
      expect(
        RommFirmware.fromJson(
          schema(isVerified: 'false', missingFromFs: 'true'),
        ).missingFromFs,
        isTrue,
      );
    });

    test('tolerates string ids and sizes', () {
      final fw = RommFirmware.fromJson(schema(id: '77', fileSizeBytes: '2048'));

      expect(fw.id, 77);
      expect(fw.fileSizeBytes, 2048);
    });

    test('falls back to zero rather than throwing on junk numbers', () {
      final fw = RommFirmware.fromJson(
        schema(id: 'nope', platformId: null, fileSizeBytes: 'big'),
      );

      expect(fw.id, 0);
      expect(fw.platformId, 0);
      expect(fw.fileSizeBytes, 0);
    });
  });
}
