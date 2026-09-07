import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

/// One ledger row: what this device already sent to RomM for a game.
///
/// [fileSize] is null for a file the server refused as too large (413). That
/// row exists precisely so the file is never offered again — see
/// [RommScreenshotMapRepository.recordSkipped].
typedef RommScreenshotLedgerEntry = ({
  String fileName,
  int? fileSize,
  int? rommScreenshotId,
});

/// Repository for the RomM screenshot upload ledger (`app_romm_screenshot_map`).
///
/// The table answers exactly one question — "has this device already sent this
/// capture for this ROM?" — keyed on `(rom_path, file_name)` and qualified by
/// size, so a file RomM already holds is never re-read or re-sent. RomM
/// overwrites assets by file name anyway, which is why the ledger compares
/// names and sizes rather than hashing content.
///
/// Per the architecture rules this is the only layer that touches
/// [SqliteService] for this data.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Database Operation Standards"
class RommScreenshotMapRepository {
  static final _log = LoggerService.instance;

  static const String _table = 'app_romm_screenshot_map';

  /// Every recorded file name for [romPath] mapped to the size it was recorded
  /// with (null for a 413-skipped file).
  ///
  /// The collector's exclusion set. Returns an empty map on error, which reads
  /// as "nothing uploaded yet" — the worst case is a re-upload RomM overwrites
  /// in place, never a lost capture.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
  static Future<Map<String, int?>> recordedFor(String romPath) async {
    if (romPath.isEmpty) return const {};
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        columns: ['file_name', 'file_size'],
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
      final out = <String, int?>{};
      for (final row in rows) {
        final name = row['file_name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final rawSize = row['file_size'];
        out[name] = rawSize == null ? null : int.tryParse(rawSize.toString());
      }
      return out;
    } catch (e) {
      _log.e('Error reading the RomM screenshot ledger for $romPath: $e');
      return const {};
    }
  }

  /// Every row for [romPath], for callers that need the RomM ids too.
  static Future<List<RommScreenshotLedgerEntry>> entriesFor(
    String romPath,
  ) async {
    if (romPath.isEmpty) return const [];
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        columns: ['file_name', 'file_size', 'romm_screenshot_id'],
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
      final out = <RommScreenshotLedgerEntry>[];
      for (final row in rows) {
        final name = row['file_name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final rawSize = row['file_size'];
        final rawId = row['romm_screenshot_id'];
        out.add((
          fileName: name,
          fileSize: rawSize == null ? null : int.tryParse(rawSize.toString()),
          rommScreenshotId: rawId == null
              ? null
              : int.tryParse(rawId.toString()),
        ));
      }
      return out;
    } catch (e) {
      _log.e('Error reading the RomM screenshot ledger for $romPath: $e');
      return const [];
    }
  }

  /// Records a screenshot the server accepted.
  ///
  /// [rommScreenshotId] may be null when the upload succeeded but the response
  /// body could not be read as a screenshot — the file still must not be sent
  /// again, and the id is only used by the gallery.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger"
  static Future<bool> recordUploaded({
    required String romPath,
    required String fileName,
    required int fileSize,
    int? rommScreenshotId,
  }) => _record(
    romPath: romPath,
    fileName: fileName,
    fileSize: fileSize,
    rommScreenshotId: rommScreenshotId,
  );

  /// Records a screenshot the server refused as too large (413).
  ///
  /// The row carries a null `file_size`, which the collector reads as "skip
  /// this name whatever it now weighs": a 413 is a property of the server's
  /// limit, not of a particular byte count, so re-offering the same file on
  /// every later session would spend a request to be refused again.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger"
  static Future<bool> recordSkipped({
    required String romPath,
    required String fileName,
  }) => _record(romPath: romPath, fileName: fileName, fileSize: null);

  static Future<bool> _record({
    required String romPath,
    required String fileName,
    required int? fileSize,
    int? rommScreenshotId,
  }) async {
    if (romPath.isEmpty || fileName.isEmpty) return false;
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(_upsertSql, [
        romPath,
        fileName,
        fileSize,
        rommScreenshotId,
        DateTime.now().toUtc().toIso8601String(),
      ]);
      return true;
    } catch (e) {
      _log.e(
        'Error writing the RomM screenshot ledger '
        '(rom_path=$romPath file_name=$fileName): $e',
      );
      return false;
    }
  }

  /// Drops every ledger row for [romPath]; returns how many were removed.
  ///
  /// Deleting a game locally has to clear its ledger, or the rows outlive the
  /// file and a later game that happens to reuse the path inherits them.
  static Future<int> removeFor(String romPath) async {
    if (romPath.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(
        _table,
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
    } catch (e) {
      _log.e('Error clearing the RomM screenshot ledger for $romPath: $e');
      return 0;
    }
  }

  /// Parameterized upsert: the `(rom_path, file_name)` primary-key conflict
  /// becomes an update, so a file re-sent after a size change (or after a 413
  /// row was written) keeps one row rather than failing the insert.
  static const String _upsertSql =
      'INSERT INTO $_table '
      '(rom_path, file_name, file_size, romm_screenshot_id, uploaded_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(rom_path, file_name) DO UPDATE SET '
      'file_size = excluded.file_size, '
      'romm_screenshot_id = excluded.romm_screenshot_id, '
      'uploaded_at = excluded.uploaded_at';
}
