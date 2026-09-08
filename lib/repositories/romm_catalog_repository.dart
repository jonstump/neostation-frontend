import 'package:neostation/services/logger_service.dart';

import '../data/datasources/sqlite_service.dart';
import '../models/romm_catalog_row.dart';

/// Repository for the offline-first RomM library catalog
/// (`app_romm_catalog` and `app_romm_catalog_platforms`).
///
/// The catalog is a cache of the server, kept beside — never inside — the
/// local library: `user_roms` is what the user has and `app_romm_rom_map` is
/// the link their saves follow, while everything here can be dropped and
/// rebuilt by the next refresh. That is why [clear] is a plain delete and why
/// nothing in this table is ever merged into a local row.
///
/// Per the architecture rules this is the only layer that touches
/// [SqliteService] for this data; the refresh service goes through here.
// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
class RommCatalogRepository {
  static final _log = LoggerService.instance;

  static const String _table = 'app_romm_catalog';
  static const String _platformTable = 'app_romm_catalog_platforms';

  /// Rows per write transaction.
  ///
  /// A refresh can carry tens of thousands of rows; one transaction for all of
  /// them holds the single connection's write lock for as long as the walk
  /// takes and loses everything if it fails half way. Five hundred is the page
  /// size the walk already fetches in, so a page is normally one commit.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Database Operation Standards"
  static const int upsertChunkSize = 500;

  /// Writes [rows] in chunks of [upsertChunkSize], one transaction per chunk.
  ///
  /// Upsert on the `(server_url, romm_rom_id)` primary key: a ROM the server
  /// renamed keeps its row (and therefore its identity for the link map and
  /// the cover cache) and gains the new name and `seen_at`. Returns how many
  /// rows were written; a chunk that fails is logged with its context and the
  /// rest still go in — a refresh that half succeeds leaves a half-fresh
  /// catalog, never an empty one. A return short of `rows.length` is the
  /// caller's signal that this platform must not be pruned: the rows the failed
  /// chunk would have stamped still carry an older `seen_at` and would read as
  /// gone from the server.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Database Operation Standards"
  static Future<int> upsertRows(List<RommCatalogRow> rows) async {
    if (rows.isEmpty) return 0;
    var written = 0;
    try {
      final db = await SqliteService.getDatabase();
      for (var start = 0; start < rows.length; start += upsertChunkSize) {
        final end = (start + upsertChunkSize).clamp(0, rows.length);
        final chunk = rows.sublist(start, end);
        try {
          await db.transaction((txn) async {
            for (final row in chunk) {
              final values = row.toDbValues();
              await txn.rawInsert(_upsertSql, values.values.toList());
            }
          });
          written += chunk.length;
        } catch (e) {
          _log.e(
            'RomM catalog upsert failed: server=${chunk.first.serverUrl} '
            'platform=${chunk.first.platformId} rows=${chunk.length} '
            'cause=$e',
          );
        }
      }
    } catch (e) {
      _log.e('RomM catalog upsert failed: rows=${rows.length} cause=$e');
    }
    return written;
  }

  /// Deletes the rows of one platform that the current run did not stamp.
  ///
  /// Called once a platform has been paged to completion: anything still
  /// carrying a `seen_at` from before [before] was not on the server this
  /// time, so it is gone. Never called for a platform whose walk failed, or
  /// whose [upsertRows] returned short — a partial view of a platform would
  /// delete ROMs that are still there.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  static Future<int> deleteUnseen({
    required String serverUrl,
    required int platformId,
    required DateTime before,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(
        _table,
        where: 'server_url = ? AND platform_id = ? AND seen_at < ?',
        whereArgs: [serverUrl, platformId, before.toUtc().toIso8601String()],
      );
    } catch (e) {
      _log.e(
        'RomM catalog delete failed: server=$serverUrl '
        'platform=$platformId cause=$e',
      );
      return 0;
    }
  }

  /// Every catalogued ROM of one system, name-ordered.
  ///
  /// Reads through the `(server_url, system_folder)` index — the one question
  /// a list build asks.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Database Operation Standards"
  static Future<List<RommCatalogRow>> rowsForSystem({
    required String serverUrl,
    required String systemFolder,
  }) async {
    if (serverUrl.isEmpty || systemFolder.isEmpty) return const [];
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        where: 'server_url = ? AND system_folder = ?',
        whereArgs: [serverUrl, systemFolder],
        orderBy: 'name COLLATE NOCASE ASC',
      );
      return [for (final row in rows) RommCatalogRow.fromDbRow(row)];
    } catch (e) {
      _log.e(
        'RomM catalog read failed: server=$serverUrl '
        'system=$systemFolder cause=$e',
      );
      return const [];
    }
  }

  /// One catalogued ROM by its RomM id, or null when the server has no row
  /// for it (never catalogued, or deleted by a later walk).
  ///
  /// A primary-key read: what the download path asks when a remote entry is
  /// confirmed, since the entry itself carries only what a card draws.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
  static Future<RommCatalogRow?> rowForRomId({
    required String serverUrl,
    required int rommRomId,
  }) async {
    if (serverUrl.isEmpty) return null;
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        where: 'server_url = ? AND romm_rom_id = ?',
        whereArgs: [serverUrl, rommRomId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return RommCatalogRow.fromDbRow(rows.first);
    } catch (e) {
      _log.e(
        'RomM catalog read failed: server=$serverUrl rom=$rommRomId cause=$e',
      );
      return null;
    }
  }

  /// A page of catalogued ROMs whose name contains [term], for the search
  /// screen while the server is unreachable.
  ///
  /// Name-ordered and case-insensitive; [systemFolder] narrows to one system
  /// and [genre] to rows whose genre list mentions it, the two filters the
  /// catalog can answer (it holds no companies). [total] is the match count
  /// across the whole catalog so the section can say how many there are
  /// beyond the page.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
  static Future<RommCatalogSearchPage> searchRows({
    required String serverUrl,
    required String term,
    String? systemFolder,
    String? genre,
    int limit = 30,
    int offset = 0,
  }) async {
    if (serverUrl.isEmpty || term.trim().isEmpty) {
      return const RommCatalogSearchPage(rows: [], total: 0);
    }
    try {
      final db = await SqliteService.getDatabase();
      final where = StringBuffer('server_url = ? AND name LIKE ? ESCAPE ?');
      final args = <Object?>[serverUrl, '%${_escapeLike(term.trim())}%', r'\'];
      if (systemFolder != null && systemFolder.isNotEmpty) {
        where.write(' AND system_folder = ?');
        args.add(systemFolder);
      }
      if (genre != null && genre.isNotEmpty) {
        where.write(' AND genres LIKE ? ESCAPE ?');
        args
          ..add('%${_escapeLike(genre)}%')
          ..add(r'\');
      }
      final counted = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $_table WHERE $where',
        args,
      );
      final total = counted.isEmpty
          ? 0
          : int.tryParse(counted.first['n']?.toString() ?? '0') ?? 0;
      final rows = await db.query(
        _table,
        where: where.toString(),
        whereArgs: args,
        orderBy: 'name COLLATE NOCASE ASC',
        limit: limit,
        offset: offset,
      );
      return RommCatalogSearchPage(
        rows: [for (final row in rows) RommCatalogRow.fromDbRow(row)],
        total: total,
      );
    } catch (e) {
      _log.e(
        'RomM catalog search failed: server=$serverUrl term=$term cause=$e',
      );
      return const RommCatalogSearchPage(rows: [], total: 0);
    }
  }

  /// [value] with the LIKE wildcards escaped, so a name containing `%` or
  /// `_` is matched literally.
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Every system folder this server has catalogued ROMs for.
  ///
  /// What the systems carousel unions with the detected systems to show a
  /// platform the device has no folder for.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Remote-Only Systems"
  static Future<List<String>> systemsWithRows(String serverUrl) async {
    if (serverUrl.isEmpty) return const [];
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT DISTINCT system_folder FROM $_table WHERE server_url = ? '
        'ORDER BY system_folder COLLATE NOCASE ASC',
        [serverUrl],
      );
      return [
        for (final row in rows)
          if ((row['system_folder']?.toString() ?? '').isNotEmpty)
            row['system_folder'].toString(),
      ];
    } catch (e) {
      _log.e('RomM catalog systems read failed: server=$serverUrl cause=$e');
      return const [];
    }
  }

  /// How many ROMs are catalogued per system folder, in one query.
  ///
  /// What the systems carousel needs for every remote-only card at once:
  /// [systemsWithRows] plus a [countForSystem] per folder would be one query
  /// per platform on every carousel rebuild.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Remote-Only Systems"
  static Future<Map<String, int>> countsBySystem(String serverUrl) async {
    if (serverUrl.isEmpty) return const {};
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT system_folder, COUNT(*) AS n FROM $_table '
        'WHERE server_url = ? GROUP BY system_folder',
        [serverUrl],
      );
      final counts = <String, int>{};
      for (final row in rows) {
        final folder = row['system_folder']?.toString() ?? '';
        if (folder.isEmpty) continue;
        counts[folder] = int.tryParse(row['n']?.toString() ?? '0') ?? 0;
      }
      return counts;
    } catch (e) {
      _log.e('RomM catalog counts read failed: server=$serverUrl cause=$e');
      return const {};
    }
  }

  /// How many ROMs are catalogued for one system.
  static Future<int> countForSystem({
    required String serverUrl,
    required String systemFolder,
  }) async {
    if (serverUrl.isEmpty || systemFolder.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $_table '
        'WHERE server_url = ? AND system_folder = ?',
        [serverUrl, systemFolder],
      );
      if (rows.isEmpty) return 0;
      return int.tryParse(rows.first['n']?.toString() ?? '0') ?? 0;
    } catch (e) {
      _log.e(
        'RomM catalog count failed: server=$serverUrl '
        'system=$systemFolder cause=$e',
      );
      return 0;
    }
  }

  /// Records a platform the walk completed: its system, its name, how many
  /// ROMs it holds and when the walk finished.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
  static Future<bool> recordPlatform({
    required String serverUrl,
    required int platformId,
    required String systemFolder,
    required String name,
    required int romCount,
    DateTime? refreshedAt,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawInsert(_platformUpsertSql, [
        serverUrl,
        platformId,
        systemFolder,
        name,
        romCount,
        refreshedAt?.toUtc().toIso8601String(),
      ]);
      return true;
    } catch (e) {
      _log.e(
        'RomM catalog platform write failed: server=$serverUrl '
        'platform=$platformId cause=$e',
      );
      return false;
    }
  }

  /// When one platform's walk last completed, or null when none has.
  static Future<DateTime?> platformRefreshedAt({
    required String serverUrl,
    required int platformId,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _platformTable,
        columns: ['refreshed_at'],
        where: 'server_url = ? AND platform_id = ?',
        whereArgs: [serverUrl, platformId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return DateTime.tryParse(
        rows.first['refreshed_at']?.toString() ?? '',
      )?.toUtc();
    } catch (e) {
      _log.e(
        'RomM catalog platform read failed: server=$serverUrl '
        'platform=$platformId cause=$e',
      );
      return null;
    }
  }

  /// The most recent completed platform walk on this server.
  ///
  /// The hourly guard's clock and the settings "as of {time}" line read the
  /// same value, so what the user is told is exactly what the guard used.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Refresh Shares The Walk"
  static Future<DateTime?> newestRefreshedAt(String serverUrl) async {
    if (serverUrl.isEmpty) return null;
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT MAX(refreshed_at) AS newest FROM $_platformTable '
        'WHERE server_url = ?',
        [serverUrl],
      );
      if (rows.isEmpty) return null;
      return DateTime.tryParse(rows.first['newest']?.toString() ?? '')?.toUtc();
    } catch (e) {
      _log.e('RomM catalog stamp read failed: server=$serverUrl cause=$e');
      return null;
    }
  }

  /// Every catalogued platform of a server, for the settings summary.
  static Future<List<RommCatalogPlatform>> platformsFor(
    String serverUrl,
  ) async {
    if (serverUrl.isEmpty) return const [];
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _platformTable,
        where: 'server_url = ?',
        whereArgs: [serverUrl],
        orderBy: 'system_folder COLLATE NOCASE ASC',
      );
      return [for (final row in rows) RommCatalogPlatform.fromDbRow(row)];
    } catch (e) {
      _log.e('RomM catalog platforms read failed: server=$serverUrl cause=$e');
      return const [];
    }
  }

  /// Drops everything catalogued for one server.
  ///
  /// Disconnecting or changing server must not leave a library on screen that
  /// nothing can download from; the rows are a cache, so deleting them costs
  /// one refresh and nothing else.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Settings And Actions"
  static Future<int> clear(String serverUrl) async {
    if (serverUrl.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      final removed = await db.delete(
        _table,
        where: 'server_url = ?',
        whereArgs: [serverUrl],
      );
      await db.delete(
        _platformTable,
        where: 'server_url = ?',
        whereArgs: [serverUrl],
      );
      return removed;
    } catch (e) {
      _log.e('RomM catalog clear failed: server=$serverUrl cause=$e');
      return 0;
    }
  }

  /// Parameterized upsert on the catalog's primary key. Every column except
  /// the key is refreshed, so a renamed, re-covered or re-sized ROM updates in
  /// place rather than failing the insert or duplicating the row.
  static const String _upsertSql =
      'INSERT INTO $_table '
      '(server_url, romm_rom_id, platform_id, system_folder, name, fs_name, '
      'fs_extension, fs_size_bytes, has_multiple_files, path_cover_small, '
      'path_cover_large, url_cover, ra_id, genres, release_year, '
      'server_updated_at, seen_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(server_url, romm_rom_id) DO UPDATE SET '
      'platform_id = excluded.platform_id, '
      'system_folder = excluded.system_folder, '
      'name = excluded.name, '
      'fs_name = excluded.fs_name, '
      'fs_extension = excluded.fs_extension, '
      'fs_size_bytes = excluded.fs_size_bytes, '
      'has_multiple_files = excluded.has_multiple_files, '
      'path_cover_small = excluded.path_cover_small, '
      'path_cover_large = excluded.path_cover_large, '
      'url_cover = excluded.url_cover, '
      'ra_id = excluded.ra_id, '
      'genres = excluded.genres, '
      'release_year = excluded.release_year, '
      'server_updated_at = excluded.server_updated_at, '
      'seen_at = excluded.seen_at';

  static const String _platformUpsertSql =
      'INSERT INTO $_platformTable '
      '(server_url, platform_id, system_folder, name, rom_count, refreshed_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(server_url, platform_id) DO UPDATE SET '
      'system_folder = excluded.system_folder, '
      'name = excluded.name, '
      'rom_count = excluded.rom_count, '
      // A write without a stamp (a platform recorded before its walk finished)
      // must never blank the stamp a completed walk left.
      'refreshed_at = COALESCE(excluded.refreshed_at, '
      '$_platformTable.refreshed_at)';
}

/// One page of a catalog search: the rows and how many match in all.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
class RommCatalogSearchPage {
  final List<RommCatalogRow> rows;
  final int total;

  const RommCatalogSearchPage({required this.rows, required this.total});
}
