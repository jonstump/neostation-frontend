import 'dart:convert';

import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

/// One collection's pending pushes, as the flush reads them back.
///
/// The three `*Dirty` flags say which aspects RomM has not been told about;
/// the flush reads the *current* name, image and membership from
/// `user_collections` when it runs, so a row never carries stale values.
/// [rommServerUrl] and [rommCollectionId] are the provenance at queue time,
/// kept on the row so a [deleteRemote] still knows what to delete after the
/// local collection is gone. [lastPushedRomIds] is the set the server was
/// last told (null before the first membership push), the baseline a 4.9.0+
/// server gets an add/remove diff against.
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
typedef RommCollectionOutboxRow = ({
  String collectionId,
  String? rommServerUrl,
  String? rommCollectionId,
  bool nameDirty,
  bool artworkDirty,
  bool membersDirty,
  bool deleteRemote,
  Set<int>? lastPushedRomIds,
  DateTime? updatedAt,
});

/// Repository for the collection push outbox (`app_romm_collection_outbox`).
///
/// One row per pushed collection. Marking coalesces per aspect: renaming a
/// collection three times and toggling two members while offline leaves one
/// row with `name_dirty = 1, members_dirty = 1` and costs one name update
/// and one membership update at the next flush, not five requests.
///
/// The origin rule — only a `local`-origin collection may queue — is
/// enforced by `RommCollectionOutboxService.queue`, which reads the
/// collection row; this layer stores what it is given.
///
/// Per the architecture rules this is the only layer that touches
/// [SqliteService] for this data; the service and provider above it never
/// see a statement.
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Database Operation Standards"
class RommCollectionOutboxRepository {
  static final _log = LoggerService.instance;

  static const String _table = 'app_romm_collection_outbox';

  /// Marks aspects of [collectionId] as pending, folding into any row already
  /// queued: a flag only ever turns *on* here (`MAX` in the upsert), and the
  /// provenance columns take the values given, so a re-push under a new
  /// RomM id updates them. `updated_at` moves to now, which is what lets the
  /// flush tell an edit made during a push from the one it just sent.
  ///
  /// Returns false when nothing was written: an empty id, no aspect given,
  /// or a database error — the caller treats that as "not queued".
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
  static Future<bool> upsert({
    required String collectionId,
    required String? rommServerUrl,
    required String? rommCollectionId,
    bool nameDirty = false,
    bool artworkDirty = false,
    bool membersDirty = false,
    bool deleteRemote = false,
  }) async {
    if (collectionId.isEmpty) return false;
    if (!nameDirty && !artworkDirty && !membersDirty && !deleteRemote) {
      return false;
    }
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(_upsertSql, [
        collectionId,
        rommServerUrl,
        rommCollectionId,
        nameDirty ? 1 : 0,
        artworkDirty ? 1 : 0,
        membersDirty ? 1 : 0,
        deleteRemote ? 1 : 0,
        DateTime.now().toUtc().toIso8601String(),
      ]);
      return true;
    } catch (e) {
      _log.e(
        'Error queueing RomM collection push (collection=$collectionId '
        'name=$nameDirty artwork=$artworkDirty members=$membersDirty '
        'delete=$deleteRemote): $e',
      );
      return false;
    }
  }

  /// Records the membership the server now holds for [collectionId] without
  /// marking anything dirty — the baseline the next membership push diffs
  /// against. Creates the row when there is none (the push action calls this
  /// right after the initial push) and leaves every flag and `updated_at`
  /// as they are, so a baseline write never hides or fakes an edit.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
  static Future<bool> recordPushedRomIds(
    String collectionId,
    Iterable<int> romIds, {
    required String? rommServerUrl,
    required String? rommCollectionId,
  }) async {
    if (collectionId.isEmpty) return false;
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(_baselineSql, [
        collectionId,
        rommServerUrl,
        rommCollectionId,
        jsonEncode(romIds.toSet().toList()..sort()),
      ]);
      return true;
    } catch (e) {
      _log.e(
        'Error recording pushed RomM collection members '
        '(collection=$collectionId): $e',
      );
      return false;
    }
  }

  /// Turns the given flags off for [collectionId] once the server confirmed
  /// them. With [unlessChangedSince] the clear applies only while the row's
  /// `updated_at` still equals it — an edit queued while the push was in
  /// flight bumped it, and that edit must survive to the next flush.
  ///
  /// The row itself stays (with its baseline) until [delete]; a row with no
  /// flag set is simply not listed by [listDirty].
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Database Operation Standards"
  static Future<int> clearDirty(
    String collectionId, {
    bool name = false,
    bool artwork = false,
    bool members = false,
    bool deleteRemote = false,
    DateTime? unlessChangedSince,
  }) async {
    if (collectionId.isEmpty) return 0;
    if (!name && !artwork && !members && !deleteRemote) return 0;
    try {
      final db = await SqliteService.getDatabase();
      final sets = <String>[
        if (name) 'name_dirty = 0',
        if (artwork) 'artwork_dirty = 0',
        if (members) 'members_dirty = 0',
        if (deleteRemote) 'delete_remote = 0',
      ];
      final where = StringBuffer('collection_id = ?');
      final args = <Object?>[collectionId];
      if (unlessChangedSince != null) {
        where.write(' AND updated_at = ?');
        args.add(unlessChangedSince.toUtc().toIso8601String());
      }
      return await db.rawUpdate(
        'UPDATE $_table SET ${sets.join(', ')} WHERE $where',
        args,
      );
    } catch (e) {
      _log.e(
        'Error clearing RomM collection outbox flags '
        '(collection=$collectionId): $e',
      );
      return 0;
    }
  }

  /// Every row with at least one aspect pending, oldest change first.
  ///
  /// Ordered by `updated_at` because the flush is allowed to stop early (a
  /// disconnect, a socket error) and the rows it did not reach must be the
  /// newest ones, not an arbitrary slice.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
  static Future<List<RommCollectionOutboxRow>> listDirty() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        columns: _columns,
        where:
            'name_dirty <> 0 OR artwork_dirty <> 0 OR members_dirty <> 0 '
            'OR delete_remote <> 0',
        orderBy: 'updated_at ASC, collection_id ASC',
      );
      return [for (final row in rows) ?_rowOf(row)];
    } catch (e) {
      // An empty list reads as "nothing pending", which makes the flush a
      // no-op rather than a crash; the rows are still there next time.
      _log.e('Error reading the RomM collection outbox: $e');
      return const [];
    }
  }

  /// The row for [collectionId], dirty or not, or null when it has none.
  static Future<RommCollectionOutboxRow?> get(String collectionId) async {
    if (collectionId.isEmpty) return null;
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        _table,
        columns: _columns,
        where: 'collection_id = ?',
        whereArgs: [collectionId],
        limit: 1,
      );
      return rows.isEmpty ? null : _rowOf(rows.first);
    } catch (e) {
      _log.e('Error reading the RomM collection outbox row $collectionId: $e');
      return null;
    }
  }

  /// Number of collections with something still waiting to be pushed.
  static Future<int> pendingCount() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $_table WHERE name_dirty <> 0 '
        'OR artwork_dirty <> 0 OR members_dirty <> 0 OR delete_remote <> 0',
      );
      return int.tryParse(rows.first['c'].toString()) ?? 0;
    } catch (e) {
      _log.e('Error counting the RomM collection outbox: $e');
      return 0;
    }
  }

  /// Drops the row for [collectionId] — baseline included — once the
  /// collection is deleted on the server, gone from it (404), or unlinked.
  /// Returns how many rows went away (0 when there was nothing queued).
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Database Operation Standards"
  static Future<int> delete(String collectionId) async {
    if (collectionId.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(
        _table,
        where: 'collection_id = ?',
        whereArgs: [collectionId],
      );
    } catch (e) {
      _log.e('Error clearing the RomM collection outbox row $collectionId: $e');
      return 0;
    }
  }

  /// Empties the outbox.
  static Future<int> clear() async {
    try {
      final db = await SqliteService.getDatabase();
      return await db.delete(_table);
    } catch (e) {
      _log.e('Error clearing the RomM collection outbox: $e');
      return 0;
    }
  }

  static const List<String> _columns = [
    'collection_id',
    'romm_server_url',
    'romm_collection_id',
    'name_dirty',
    'artwork_dirty',
    'members_dirty',
    'delete_remote',
    'last_pushed_rom_ids',
    'updated_at',
  ];

  static RommCollectionOutboxRow? _rowOf(Map<String, Object?> row) {
    final collectionId = row['collection_id']?.toString() ?? '';
    if (collectionId.isEmpty) return null;
    return (
      collectionId: collectionId,
      rommServerUrl: _nullIfEmpty(row['romm_server_url']),
      rommCollectionId: _nullIfEmpty(row['romm_collection_id']),
      nameDirty: _asBool(row['name_dirty']),
      artworkDirty: _asBool(row['artwork_dirty']),
      membersDirty: _asBool(row['members_dirty']),
      deleteRemote: _asBool(row['delete_remote']),
      lastPushedRomIds: _romIdsOf(row['last_pushed_rom_ids']),
      updatedAt: DateTime.tryParse(row['updated_at']?.toString() ?? ''),
    );
  }

  static String? _nullIfEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// SQLite stores the flags as 0/1; anything unparseable reads as off.
  static bool _asBool(Object? value) =>
      (int.tryParse(value?.toString() ?? '') ?? 0) != 0;

  /// The stored JSON array of ROM ids, or null when no membership push has
  /// happened yet (or the column holds something that is not a list — a
  /// corrupt baseline is no baseline, and the flush falls back to a full
  /// replace rather than trusting it).
  static Set<int>? _romIdsOf(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return null;
      return {for (final e in decoded) ?int.tryParse(e.toString())};
    } catch (_) {
      return null;
    }
  }

  /// Parameterized coalescing upsert: flags only turn on, provenance takes
  /// the new values, `updated_at` moves forward.
  static const String _upsertSql =
      'INSERT INTO $_table '
      '(collection_id, romm_server_url, romm_collection_id, name_dirty, '
      'artwork_dirty, members_dirty, delete_remote, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(collection_id) DO UPDATE SET '
      'romm_server_url = excluded.romm_server_url, '
      'romm_collection_id = excluded.romm_collection_id, '
      'name_dirty = MAX(excluded.name_dirty, $_table.name_dirty), '
      'artwork_dirty = MAX(excluded.artwork_dirty, $_table.artwork_dirty), '
      'members_dirty = MAX(excluded.members_dirty, $_table.members_dirty), '
      'delete_remote = MAX(excluded.delete_remote, $_table.delete_remote), '
      'updated_at = excluded.updated_at';

  /// Baseline write: creates a clean row or sets only the baseline (and the
  /// provenance) on an existing one, flags and `updated_at` untouched.
  static const String _baselineSql =
      'INSERT INTO $_table '
      '(collection_id, romm_server_url, romm_collection_id, '
      'last_pushed_rom_ids) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(collection_id) DO UPDATE SET '
      'romm_server_url = excluded.romm_server_url, '
      'romm_collection_id = excluded.romm_collection_id, '
      'last_pushed_rom_ids = excluded.last_pushed_rom_ids';
}
