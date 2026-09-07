/// A RomM user screenshot, returned by `/api/screenshots` and carried on the
/// ROM detail as `user_screenshots`.
///
/// Deliberately separate from [RommAsset]: saves and states share one schema
/// (`/api/saves`, `/api/states`) that screenshots do not — a screenshot has no
/// `emulator`, no `slot` and no content hash, and it carries the two gallery
/// flags RomM added in 5.0.0 instead.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger"
class RommScreenshot {
  /// RomM asset id (used for `/api/screenshots/{id}/content`, 5.0.0+).
  final int id;

  /// The file name RomM filed the screenshot under. RomM overwrites on
  /// `(user, rom, file name)`, so this is the identity of the upload.
  final String fileName;

  /// Size in bytes as the server recorded it.
  final int fileSizeBytes;

  /// Server-relative URL for the raw bytes
  /// (`/api/raw/assets/{file_path}/{file_name}?timestamp=...`).
  final String? downloadPath;

  /// Whether RomM shows the screenshot in the ROM's gallery (5.0.0+; false on
  /// older servers, which have no such flag).
  final bool isGallery;

  /// Whether the screenshot is visible to other RomM users. Uploads from here
  /// are never marked public — RomM's own default is private.
  final bool isPublic;

  const RommScreenshot({
    required this.id,
    required this.fileName,
    required this.fileSizeBytes,
    this.downloadPath,
    this.isGallery = false,
    this.isPublic = false,
  });

  factory RommScreenshot.fromJson(Map<String, dynamic> json) {
    return RommScreenshot(
      id: int.tryParse((json['id'] ?? 0).toString()) ?? 0,
      fileName: (json['file_name'] ?? '').toString(),
      fileSizeBytes:
          int.tryParse((json['file_size_bytes'] ?? '0').toString()) ?? 0,
      downloadPath: _nonEmpty(json['download_path']),
      isGallery: _asBool(json['is_gallery']),
      isPublic: _asBool(json['is_public']),
    );
  }

  /// Reads the screenshot out of whatever `POST /api/screenshots` answered
  /// with.
  ///
  /// RomM's upload route has returned two shapes across the versions we
  /// support: the bare screenshot object, and the ROM detail with the new
  /// entry appended to `user_screenshots`. Both are accepted here so the
  /// caller's ledger write does not depend on the server's version. Returns
  /// null when neither shape is recognisable — a successful upload with an
  /// unreadable body is still an upload, and the caller records it without an
  /// id rather than treating it as a failure.
  static RommScreenshot? fromUploadResponse(Object? decoded) {
    if (decoded is! Map) return null;
    final json = decoded.map((k, v) => MapEntry(k.toString(), v));
    if (json.containsKey('file_name')) return RommScreenshot.fromJson(json);
    final shots = json['user_screenshots'];
    if (shots is List && shots.isNotEmpty) {
      final last = shots.last;
      if (last is Map) {
        return RommScreenshot.fromJson(
          last.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    }
    return null;
  }

  /// A trimmed string, or null when the field is absent or blank.
  static String? _nonEmpty(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  /// RomM sends JSON booleans, but a few proxies stringify them; treat the
  /// absent field as false so an older server reads as "no gallery flags".
  static bool _asBool(Object? raw) {
    if (raw is bool) return raw;
    final s = raw?.toString().toLowerCase();
    return s == 'true' || s == '1';
  }

  @override
  String toString() =>
      'RommScreenshot(id: $id, fileName: $fileName, size: $fileSizeBytes)';
}
