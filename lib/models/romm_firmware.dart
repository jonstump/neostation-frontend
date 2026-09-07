/// A BIOS/firmware file RomM holds for a platform, returned by
/// `GET /api/firmware?platform_id=` (RomM's `FirmwareSchema`).
///
/// One row of the per-system BIOS panel: the name and size drive the local
/// presence check, the hashes drive the optional "Verify" action, and
/// [missingFromFs] marks a record whose bytes the server itself no longer has
/// (listed, but not downloadable).
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
class RommFirmware {
  /// RomM firmware id (used for `/api/firmware/{id}/content/{file_name}`).
  final int id;

  /// Id of the RomM platform this firmware belongs to.
  final int platformId;

  /// Stored file name, e.g. `scph5501.bin`. Also the last path segment of the
  /// content route, so it must be sent back verbatim (URL-encoded).
  final String fileName;

  /// Size in bytes, as the server reports it. Half of the local presence check
  /// (name + size), which deliberately never reads file contents.
  final int fileSizeBytes;

  /// CRC32 of the server's copy, lowercase hex, or null when absent/blank.
  final String? crc32;

  /// MD5 of the server's copy, lowercase hex, or null when absent/blank. The
  /// only hash the "Verify" action can check, since it is the one NeoStation
  /// already streams for local files.
  final String? md5;

  /// SHA-1 of the server's copy, lowercase hex, or null when absent/blank.
  final String? sha1;

  /// RomM's own "this matches a known-good BIOS" flag.
  final bool isVerified;

  /// True when RomM has the database record but no longer has the file on
  /// disk. Such a row is shown but cannot be downloaded.
  final bool missingFromFs;

  const RommFirmware({
    required this.id,
    required this.platformId,
    required this.fileName,
    required this.fileSizeBytes,
    this.crc32,
    this.md5,
    this.sha1,
    this.isVerified = false,
    this.missingFromFs = false,
  });

  factory RommFirmware.fromJson(Map<String, dynamic> json) {
    return RommFirmware(
      id: int.tryParse((json['id'] ?? 0).toString()) ?? 0,
      platformId: int.tryParse((json['platform_id'] ?? 0).toString()) ?? 0,
      fileName: (json['file_name'] ?? '').toString(),
      fileSizeBytes:
          int.tryParse((json['file_size_bytes'] ?? '0').toString()) ?? 0,
      crc32: _hash(json['crc_hash']),
      md5: _hash(json['md5_hash']),
      sha1: _hash(json['sha1_hash']),
      isVerified: _bool(json['is_verified']),
      missingFromFs: _bool(json['missing_from_fs']),
    );
  }

  /// Normalizes a server hash: trimmed and lowercased, with `""` collapsed to
  /// null so callers only have to test for absence one way. RomM emits
  /// uppercase hex for some importers, and a comparison against a locally
  /// computed digest is case-sensitive.
  static String? _hash(dynamic raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    return s.isEmpty ? null : s;
  }

  /// Tolerates the JSON booleans RomM emits and the `0`/`1`/`"true"` forms a
  /// proxy or an older server can substitute.
  static bool _bool(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final s = raw?.toString().trim().toLowerCase() ?? '';
    return s == 'true' || s == '1';
  }

  @override
  String toString() =>
      'RommFirmware(id: $id, platform: $platformId, file: $fileName, '
      'size: $fileSizeBytes, verified: $isVerified, '
      'missingFromFs: $missingFromFs)';
}
