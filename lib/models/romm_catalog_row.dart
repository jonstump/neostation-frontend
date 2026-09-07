import 'package:flutter/foundation.dart';

import 'game_model.dart';
import 'romm_rom.dart';
import 'system_model.dart';

/// One catalogued RomM ROM: the subset of a [RommRom] the library needs to
/// draw it, resolved to a local system and stored per server.
///
/// This is the offline half of the unified library. A row exists whether or
/// not the ROM is on the device — it is what a list shows when the file is
/// missing and what it shows at all when the server is unreachable — and it is
/// deliberately replaceable: the whole catalog is a cache of the server, so
/// nothing here is the user's truth (that is `user_roms` and the link map).
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
@immutable
class RommCatalogRow {
  /// The RomM server this row was read from, as the provider spells its base
  /// URL. Part of the primary key so two servers can be catalogued side by
  /// side and disconnecting one leaves the other alone.
  final String serverUrl;

  /// RomM's ROM id — the id every other RomM feature keys on (the link map,
  /// downloads, play sessions).
  final int rommRomId;

  /// RomM's platform id the ROM belongs to.
  final int platformId;

  /// The local system folder the platform resolved to when the row was
  /// written. Stored rather than re-resolved so a list read is one indexed
  /// query with no platform table behind it.
  final String systemFolder;

  /// Display name.
  final String name;

  /// Filesystem name including extension — the name a download would land
  /// under, and the name the filename match rule compares against.
  final String fsName;

  /// Extension without the leading dot, or null when RomM sent none.
  final String? fsExtension;

  /// Total size in bytes, or null when the server did not say.
  final int? fsSizeBytes;

  /// RomM's `has_multiple_files`: the ROM is served as a multi-part zip.
  final bool hasMultipleFiles;

  /// RomM's server-relative cached cover paths, as sent.
  final String? pathCoverSmall;
  final String? pathCoverLarge;

  /// The metadata provider's own cover URL, as sent.
  final String? urlCover;

  /// RetroAchievements game id RomM matched the ROM to, or null.
  final int? raId;

  /// Genres joined with `, ` — the catalog is read for display, never
  /// filtered on individual genres, so one column is enough.
  final String? genres;

  /// 4-digit release year, or null.
  final String? releaseYear;

  /// RomM's own `updated_at` for the ROM, verbatim.
  final String? serverUpdatedAt;

  /// When the last refresh saw this ROM. A completed platform walk deletes the
  /// rows it did not stamp, which is how a ROM deleted on the server leaves
  /// the catalog.
  final DateTime seenAt;

  const RommCatalogRow({
    required this.serverUrl,
    required this.rommRomId,
    required this.platformId,
    required this.systemFolder,
    required this.name,
    required this.fsName,
    this.fsExtension,
    this.fsSizeBytes,
    this.hasMultipleFiles = false,
    this.pathCoverSmall,
    this.pathCoverLarge,
    this.urlCover,
    this.raId,
    this.genres,
    this.releaseYear,
    this.serverUpdatedAt,
    required this.seenAt,
  });

  /// The row a walk writes for [rom] on [serverUrl], filed under
  /// [systemFolder] and stamped [seenAt].
  factory RommCatalogRow.fromRom(
    RommRom rom, {
    required String serverUrl,
    required String systemFolder,
    required DateTime seenAt,
  }) => RommCatalogRow(
    serverUrl: serverUrl,
    rommRomId: rom.id,
    platformId: rom.platformId,
    systemFolder: systemFolder,
    name: rom.name,
    fsName: rom.fsName,
    fsExtension: rom.fsExtension.isEmpty ? null : rom.fsExtension,
    fsSizeBytes: rom.fsSizeBytes == 0 ? null : rom.fsSizeBytes,
    hasMultipleFiles: rom.isMultiFile,
    pathCoverSmall: rom.pathCoverSmall,
    pathCoverLarge: rom.pathCoverLarge,
    urlCover: rom.urlCover,
    raId: rom.raId,
    genres: rom.genres.isEmpty ? null : rom.genres.join(', '),
    releaseYear: rom.releaseYear,
    serverUpdatedAt: rom.serverUpdatedAt,
    seenAt: seenAt,
  );

  /// The row as the database stores it. Booleans become integers and the
  /// timestamp an ISO-8601 UTC string, the spelling every other table uses.
  Map<String, Object?> toDbValues() => {
    'server_url': serverUrl,
    'romm_rom_id': rommRomId,
    'platform_id': platformId,
    'system_folder': systemFolder,
    'name': name,
    'fs_name': fsName,
    'fs_extension': fsExtension,
    'fs_size_bytes': fsSizeBytes,
    'has_multiple_files': hasMultipleFiles ? 1 : 0,
    'path_cover_small': pathCoverSmall,
    'path_cover_large': pathCoverLarge,
    'url_cover': urlCover,
    'ra_id': raId,
    'genres': genres,
    'release_year': releaseYear,
    'server_updated_at': serverUpdatedAt,
    'seen_at': seenAt.toUtc().toIso8601String(),
  };

  /// Reads a stored row back. Tolerant of nulls and of numbers arriving as
  /// text, which is what SQLite hands back for an untyped column.
  factory RommCatalogRow.fromDbRow(Map<String, Object?> row) => RommCatalogRow(
    serverUrl: row['server_url']?.toString() ?? '',
    rommRomId: _int(row['romm_rom_id']) ?? 0,
    platformId: _int(row['platform_id']) ?? 0,
    systemFolder: row['system_folder']?.toString() ?? '',
    name: row['name']?.toString() ?? '',
    fsName: row['fs_name']?.toString() ?? '',
    fsExtension: _text(row['fs_extension']),
    fsSizeBytes: _int(row['fs_size_bytes']),
    hasMultipleFiles: (_int(row['has_multiple_files']) ?? 0) == 1,
    pathCoverSmall: _text(row['path_cover_small']),
    pathCoverLarge: _text(row['path_cover_large']),
    urlCover: _text(row['url_cover']),
    raId: _int(row['ra_id']),
    genres: _text(row['genres']),
    releaseYear: _text(row['release_year']),
    serverUpdatedAt: _text(row['server_updated_at']),
    seenAt:
        DateTime.tryParse(row['seen_at']?.toString() ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  /// The primary genre — the single compact label the list tiles show.
  String? get primaryGenre {
    final all = genres;
    if (all == null || all.isEmpty) return null;
    final first = all.split(',').first.trim();
    return first.isEmpty ? null : first;
  }

  /// This row as a game the library views can draw, filed under [system].
  ///
  /// [GameModel.romPath] is deliberately null: nothing local backs the entry,
  /// and every consumer that needs a file already treats a null path as "not
  /// on this device". The remote-entry fields the views read
  /// (`rommRomId`, `remoteSizeBytes`, `isRemote`) arrive with the merge in
  /// `GameListService`; this helper is the one place that decides how a
  /// catalog row becomes a game so that merge has nothing to restate.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Remote Entries In The Game Model"
  GameModel toGameModel(SystemModel system) => GameModel(
    romname: fsName,
    realname: name,
    name: name,
    year: releaseYear ?? '',
    developer: '',
    publisher: '',
    genre: primaryGenre ?? '',
    players: '',
    rating: 0.0,
    romPath: null,
    idRa: raId,
    systemId: system.id,
    systemFolderName: system.folderName,
    systemRealName: system.realName,
    systemShortName: system.shortName,
    systemRaId: system.raId,
  );

  static int? _int(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static String? _text(Object? value) {
    final text = value?.toString() ?? '';
    return text.isEmpty ? null : text;
  }
}

/// One catalogued RomM platform: what the last walk recorded for it.
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
@immutable
class RommCatalogPlatform {
  final String serverUrl;
  final int platformId;

  /// The local system folder the platform resolved to.
  final String systemFolder;

  /// RomM's display name for the platform.
  final String name;

  /// ROMs the last completed walk recorded for it.
  final int romCount;

  /// When that walk finished, or null when no walk has completed. A platform
  /// whose walk failed keeps its previous stamp — a failure must never read as
  /// a fresh catalog.
  final DateTime? refreshedAt;

  const RommCatalogPlatform({
    required this.serverUrl,
    required this.platformId,
    required this.systemFolder,
    required this.name,
    this.romCount = 0,
    this.refreshedAt,
  });

  factory RommCatalogPlatform.fromDbRow(Map<String, Object?> row) =>
      RommCatalogPlatform(
        serverUrl: row['server_url']?.toString() ?? '',
        platformId: RommCatalogRow._int(row['platform_id']) ?? 0,
        systemFolder: row['system_folder']?.toString() ?? '',
        name: row['name']?.toString() ?? '',
        romCount: RommCatalogRow._int(row['rom_count']) ?? 0,
        refreshedAt: DateTime.tryParse(
          row['refreshed_at']?.toString() ?? '',
        )?.toUtc(),
      );
}
