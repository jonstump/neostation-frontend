/// A single file belonging to a [RommRom] (RomM splits multi-disc / multi-part
/// ROMs into multiple files served together as a zip).
class RommRomFile {
  final int id;
  final String fileName;
  final int fileSizeBytes;

  /// RomM's hashes of this stored file, lowercase hex, or null when the
  /// server did not send one. Per file rather than per ROM because RomM
  /// hashes each member of a multi-file ROM on its own.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"
  final String? crcHash;
  final String? md5Hash;
  final String? sha1Hash;
  final String? raHash;
  final String? chdSha1Hash;

  const RommRomFile({
    required this.id,
    required this.fileName,
    this.fileSizeBytes = 0,
    this.crcHash,
    this.md5Hash,
    this.sha1Hash,
    this.raHash,
    this.chdSha1Hash,
  });

  factory RommRomFile.fromJson(Map<String, dynamic> json) {
    return RommRomFile(
      id: (json['id'] as num).toInt(),
      fileName: json['file_name']?.toString() ?? '',
      fileSizeBytes: (json['file_size_bytes'] as num?)?.toInt() ?? 0,
      crcHash: normalizeRommHash(json['crc_hash']),
      md5Hash: normalizeRommHash(json['md5_hash']),
      sha1Hash: normalizeRommHash(json['sha1_hash']),
      raHash: normalizeRommHash(json['ra_hash']),
      chdSha1Hash: normalizeRommHash(json['chd_sha1_hash']),
    );
  }
}

/// A hash as RomM sends it, normalized for comparison: surrounding whitespace
/// removed and lowercased, so a server that stores `1A2B3C4D` and a local
/// fingerprint that reads `1a2b3c4d` compare equal. Absent, null and empty
/// all become null — "no hash", never an empty key in an index.
// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"
String? normalizeRommHash(Object? value) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text.isEmpty ? null : text;
}

/// A ROM entry as exposed by a remote RomM server.
///
/// Describes the *remote* library; kept separate from the local [GameModel].
class RommRom {
  /// RomM internal ROM id (used for `/api/roms/{id}` and downloads).
  final int id;

  /// Display name.
  final String name;

  /// RomM platform id this ROM belongs to.
  final int platformId;

  /// RomM platform slug (e.g. "snes").
  final String platformSlug;

  /// Filesystem name including extension (the download `file_name`).
  final String fsName;

  /// Filesystem name without extension.
  final String fsNameNoExt;

  /// File extension (without leading dot).
  final String fsExtension;

  /// Total size in bytes.
  final int fsSizeBytes;

  /// Constituent files; length > 1 indicates a multi-disc/multi-part ROM
  /// that RomM serves as a zip archive. NOTE: RomM only populates this on the
  /// detail endpoint (`/api/roms/{id}`); the list endpoint returns it empty, so
  /// prefer [hasMultipleFiles] for the multi-file decision.
  final List<RommRomFile> files;

  /// RomM's own `has_multiple_files` flag, present on BOTH the list and detail
  /// endpoints. This is the reliable multi-file signal because [files] is empty
  /// in list responses (which is what the browse/download flow uses).
  final bool hasMultipleFiles;

  /// Relative or absolute cover URL (may need the server base URL + auth).
  ///
  /// This is the metadata provider's own copy (IGDB, SteamGridDB,
  /// ScreenScraper…), which RomM leaves empty for some matches — see
  /// [pathCoverLarge] for the server-cached copy that stands in for it.
  final String? urlCover;

  /// RomM's *locally cached* cover files, as server-relative paths under
  /// `/assets/romm/resources/`, or null when RomM stored no file.
  ///
  /// Same artwork as [urlCover] from a different place: a library can hold
  /// either one, both, or neither, so the cover a ROM actually has is whichever
  /// of the three answers first.
  final String? pathCoverLarge;
  final String? pathCoverSmall;

  /// RetroAchievements game id RomM matched this ROM to, or null if none.
  /// A non-null id means the game has a RetroAchievements set.
  ///
  /// Per-user earned progress is NOT carried on the ROM: RomM exposes it on the
  /// current user (`/api/users/me` → `ra_progression.results`, keyed by this
  /// [raId]). See `RommService.getRaProgression` / `RommProvider.raEarnedFor`.
  final int? raId;

  /// Total number of achievements in the RA set (0 when unknown / no set).
  final int raTotalAchievements;

  /// Every genre from RomM's `metadatum.genres`. Empty when unknown.
  ///
  /// RomM carries `metadatum` on both the list and detail endpoints, so search
  /// filtering gets these without a per-ROM detail fetch.
  final List<String> genres;

  /// Companies credited by RomM (`metadatum.companies`). RomM keeps one flat
  /// list rather than splitting developer from publisher, which is why the
  /// download path files them under the local `developer` column — the search
  /// developer filter matches them the same way.
  final List<String> companies;

  /// 4-digit release year from `metadatum.first_release_date`, or null.
  final String? releaseYear;

  /// RomM's own `updated_at` stamp for the ROM row, verbatim, or null when the
  /// server did not send one.
  ///
  /// Kept as the server's string rather than a parsed [DateTime]: the catalog
  /// stores it only to compare one walk's answer with the next (and, later, to
  /// ask for changes since a date), so re-formatting it would only invent a
  /// timezone the server never claimed.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
  final String? serverUpdatedAt;

  /// RomM's hashes of the ROM as stored, lowercase hex, or null when the
  /// server did not send one. Whether these describe the archive or the image
  /// inside it depends on the server version and file type, which is why the
  /// link pass compares against [allCrc32] / [allMd5] — the union with the
  /// per-file hashes — rather than against these alone.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"
  final String? crcHash;
  final String? md5Hash;
  final String? sha1Hash;
  final String? raHash;

  const RommRom({
    required this.id,
    required this.name,
    required this.platformId,
    required this.platformSlug,
    required this.fsName,
    required this.fsNameNoExt,
    required this.fsExtension,
    this.fsSizeBytes = 0,
    this.files = const [],
    this.hasMultipleFiles = false,
    this.urlCover,
    this.pathCoverLarge,
    this.pathCoverSmall,
    this.raId,
    this.raTotalAchievements = 0,
    this.genres = const [],
    this.companies = const [],
    this.releaseYear,
    this.serverUpdatedAt,
    this.crcHash,
    this.md5Hash,
    this.sha1Hash,
    this.raHash,
  });

  /// Every crc32 RomM holds for this ROM: its own plus each file's,
  /// deduplicated. Empty when the server sent none.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"
  Set<String> get allCrc32 => {?crcHash, for (final f in files) ?f.crcHash};

  /// Every md5 RomM holds for this ROM: its own plus each file's,
  /// deduplicated. Empty when the server sent none.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Fields On The ROM Model"
  Set<String> get allMd5 => {?md5Hash, for (final f in files) ?f.md5Hash};

  /// Primary genre, or null when unknown — the list UI shows a single compact
  /// label rather than the whole set.
  String? get genre => genres.isEmpty ? null : genres.first;

  /// True when RomM serves this ROM as a multi-file zip archive. Uses RomM's
  /// `has_multiple_files` flag (reliable on both endpoints) and falls back to
  /// the [files] list, which is only populated on the detail endpoint.
  bool get isMultiFile => hasMultipleFiles || files.length > 1;

  /// True when this ROM has a RetroAchievements set (per RomM metadata).
  bool get hasRetroAchievements => raId != null && raTotalAchievements > 0;

  factory RommRom.fromJson(Map<String, dynamic> json) {
    final filesJson = json['files'];
    final files = <RommRomFile>[];
    if (filesJson is List) {
      for (final f in filesJson) {
        if (f is Map<String, dynamic>) {
          files.add(RommRomFile.fromJson(f));
        }
      }
    }

    return RommRom(
      id: (json['id'] as num).toInt(),
      name:
          json['name']?.toString() ?? json['fs_name']?.toString() ?? 'Unknown',
      platformId: (json['platform_id'] as num?)?.toInt() ?? 0,
      platformSlug: json['platform_slug']?.toString() ?? '',
      fsName: json['fs_name']?.toString() ?? '',
      fsNameNoExt: json['fs_name_no_ext']?.toString() ?? '',
      fsExtension: json['fs_extension']?.toString() ?? '',
      fsSizeBytes: (json['fs_size_bytes'] as num?)?.toInt() ?? 0,
      files: files,
      hasMultipleFiles: json['has_multiple_files'] == true,
      urlCover: json['url_cover']?.toString(),
      pathCoverLarge: json['path_cover_large']?.toString(),
      pathCoverSmall: json['path_cover_small']?.toString(),
      raId: (json['ra_id'] as num?)?.toInt(),
      raTotalAchievements: _parseRaTotal(json),
      genres: _parseStringList(json, 'genres'),
      companies: _parseStringList(json, 'companies'),
      releaseYear: _parseReleaseYear(json),
      serverUpdatedAt: _nonEmpty(json['updated_at']),
      crcHash: normalizeRommHash(json['crc_hash']),
      md5Hash: normalizeRommHash(json['md5_hash']),
      sha1Hash: normalizeRommHash(json['sha1_hash']),
      raHash: normalizeRommHash(json['ra_hash']),
    );
  }

  /// [value] as a trimmed string, or null when it is absent or blank.
  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// Non-empty strings under `metadatum.<key>`, in server order.
  static List<String> _parseStringList(Map<String, dynamic> json, String key) {
    final md = json['metadatum'];
    if (md is! Map) return const [];
    final list = md[key];
    if (list is! List) return const [];
    return [
      for (final v in list)
        if ((v?.toString() ?? '').trim().isNotEmpty) v.toString().trim(),
    ];
  }

  /// Year from `metadatum.first_release_date`, which RomM sends as epoch
  /// milliseconds (the same field the download path turns into release_date).
  static String? _parseReleaseYear(Map<String, dynamic> json) {
    final md = json['metadatum'];
    if (md is! Map) return null;
    final frd = md['first_release_date'];
    if (frd is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      frd.toInt(),
      isUtc: true,
    ).year.toString().padLeft(4, '0');
  }

  /// Total achievements in the RA set. Prefers the length of the merged
  /// metadata's achievement list, falling back to numeric count fields.
  static int _parseRaTotal(Map<String, dynamic> json) {
    final meta = json['merged_ra_metadata'];
    if (meta is Map) {
      final ach = meta['achievements'];
      if (ach is List) return ach.length;
      final maxPossible = (meta['max_possible'] as num?)?.toInt();
      if (maxPossible != null) return maxPossible;
    }
    return (json['num_achievements'] as num?)?.toInt() ?? 0;
  }
}
