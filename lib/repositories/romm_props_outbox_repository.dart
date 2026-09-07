import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

/// One queued play-state change, as the flush reads it back.
///
/// [hidden] and [favourite] are null when the game has no pending change for
/// that field — the flush skips the corresponding call rather than writing a
/// value nobody asked for.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
typedef RommPropsOutboxRow = ({
  String romPath,
  bool? hidden,
  bool? favourite,
  bool touchLastPlayed,
  DateTime? updatedAt,
});

/// Repository for the RomM play-state push outbox (`app_romm_props_outbox`).
///
/// The table answers "what has this device changed that RomM has not been told
/// about?", one row per linked game. Writes coalesce per column, so hiding a
/// game and then unhiding it before a flush leaves one row saying `hidden = 0`
/// and costs one request rather than two.
///
/// Per the architecture rules this is the only layer that touches
/// [SqliteService] for this data; the service and provider above it never see
/// a statement.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Database Operation Standards"
class RommPropsOutboxRepository {
  static final _log = LoggerService.instance;

  static const String _table = 'app_romm_props_outbox';

  /// Queues (or folds into an existing row) a pending change for [romPath].
  ///
  /// A null [hidden] or [favourite] means "no opinion": the stored value is
  /// kept, so a favourite toggle never clears a pending hide. A non-null value
  /// wins outright — the last thing the user did is what RomM should end up
  /// with. [touchLastPlayed] only ever turns on: a session that finished did
  /// finish, and a later hide must not forget it.
  ///
  /// Returns false when nothing was written (an empty path, no actual change
  /// to record, or a database error); the caller treats that as "not queued".
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
  static Future<bool> upsert({
    required String romPath,
    bool? hidden,
    bool? favourite,
    bool touchLastPlayed = false,
  }) async {
    if (romPath.isEmpty) return false;
    if (hidden == null && favourite == null && !touchLastPlayed) return false;
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(_upsertSql, [
        romPath,
        hidden == null ? null : (hidden ? 1 : 0),
        favourite == null ? null : (favourite ? 1 : 0),
        touchLastPlayed ? 1 : 0,
        DateTime.now().toUtc().toIso8601String(),
      ]);
      return true;
    } catch (e) {
      _log.e(
        'Error queueing RomM play-state push (rom_path=$romPath '
        'hidden=$hidden favourite=$favourite '
        'touch_last_played=$touchLastPlayed): $e',
      );
      return false;
    }
  }

  /// Every queued row, oldest change first.
  ///
  /// Ordered by `updated_at` because the flush is allowed to stop early (a
  /// disconnect, a socket error) and the rows it did not reach must be the
  /// newest ones, not an arbitrary slice.
  // Governing: ADR-0013, SPEC-0013 REQ "Props Outbox"
  static Future<List<RommPropsOutboxRow>> list({int? limit}) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        columns: [
          'rom_path',
          'hidden',
          'favourite',
          'touch_last_played',
          'updated_at',
        ],
        orderBy: 'updated_at ASC, rom_path ASC',
        limit: limit,
      );
      final out = <RommPropsOutboxRow>[];
      for (final row in rows) {
        final romPath = row['rom_path']?.toString() ?? '';
        if (romPath.isEmpty) continue;
        out.add((
          romPath: romPath,
          hidden: _asBool(row['hidden']),
          favourite: _asBool(row['favourite']),
          touchLastPlayed: _asBool(row['touch_last_played']) ?? false,
          updatedAt: DateTime.tryParse(row['updated_at']?.toString() ?? ''),
        ));
      }
      return out;
    } catch (e) {
      // An empty list reads as "nothing pending", which makes the flush a
      // no-op rather than a crash; the rows are still there next time.
      _log.e('Error reading the RomM play-state outbox: $e');
      return const [];
    }
  }

  /// Number of rows still waiting to be pushed.
  static Future<int> pendingCount() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $_table');
      return int.tryParse(rows.first['c'].toString()) ?? 0;
    } catch (e) {
      _log.e('Error counting the RomM play-state outbox: $e');
      return 0;
    }
  }

  /// Drops the row for [romPath] once the server has confirmed it; returns how
  /// many rows went away (0 when there was nothing queued).
  ///
  /// One statement per row, deliberately: a flush that dies half way through
  /// must leave every unconfirmed row exactly where it was.
  // Governing: ADR-0013, SPEC-0013 REQ "Database Operation Standards"
  static Future<int> delete(String romPath) async {
    if (romPath.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(
        _table,
        where: 'rom_path = ?',
        whereArgs: [romPath],
      );
    } catch (e) {
      _log.e('Error clearing the RomM play-state outbox row $romPath: $e');
      return 0;
    }
  }

  /// Empties the outbox — used when the push toggle is turned off, so nothing
  /// queued under it is pushed later behind the user's back.
  // Governing: ADR-0013, SPEC-0013 REQ "Push Toggle"
  static Future<int> clear() async {
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(_table);
    } catch (e) {
      _log.e('Error clearing the RomM play-state outbox: $e');
      return 0;
    }
  }

  /// SQLite stores these as 0/1 (and NULL for "no opinion"); anything else is
  /// a corrupt row and reads as no opinion rather than as false.
  static bool? _asBool(Object? value) {
    if (value == null) return null;
    final n = int.tryParse(value.toString());
    if (n == null) return null;
    return n != 0;
  }

  /// Parameterized coalescing upsert.
  ///
  /// `COALESCE(excluded.x, stored.x)` is what makes a null mean "leave it
  /// alone" while a real value wins, and `MAX` is what makes
  /// `touch_last_played` sticky once set.
  static const String _upsertSql =
      'INSERT INTO $_table '
      '(rom_path, hidden, favourite, touch_last_played, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(rom_path) DO UPDATE SET '
      'hidden = COALESCE(excluded.hidden, $_table.hidden), '
      'favourite = COALESCE(excluded.favourite, $_table.favourite), '
      'touch_last_played = MAX(excluded.touch_last_played, '
      '$_table.touch_last_played), '
      'updated_at = excluded.updated_at';
}
