import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

/// Who wrote an `app_romm_rom_map` row — persisted in `link_source`.
///
/// Only [manual] changes behaviour: a row the user picked by hand is never
/// replaced by the download path or the automatic link paths, mirroring
/// `ra_match_source` for RetroAchievements. Rows written before the column
/// existed are null in the database and read as [auto], because both the
/// download path and the automatic paths populate `romm_fs_name`, so nothing
/// reliable distinguishes them after the fact.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Provenance Column"
enum RommLinkSource {
  /// Written when the ROM was downloaded from RomM.
  download('download'),

  /// Written by the "already downloaded" paths and the connect-time pass.
  auto('auto'),

  /// Written by the per-game picker; protected from every other writer.
  manual('manual');

  /// The value stored in `link_source`.
  final String dbValue;

  const RommLinkSource(this.dbValue);

  /// Decodes a stored value; null and anything unrecognised read as [auto].
  static RommLinkSource fromDb(Object? value) {
    final text = value?.toString();
    for (final source in values) {
      if (source.dbValue == text) return source;
    }
    return auto;
  }
}

/// A mapping row as read back by [RommSaveMapRepository.getMapping].
typedef RommSaveMapping = ({
  int rommRomId,
  String? fsName,
  RommLinkSource source,
});

/// Every recorded mapping, resolvable without another query.
///
/// [RommSaveMapRepository.getRommRomId] is the single-game path and costs up to
/// two queries per call, one of which scans a whole system folder. A sweep over
/// the library asks the same question thousands of times, so it reads the table
/// once into this and looks up locally. Same matching rules as the single-game
/// path, kept in the repository so there is only one definition of them.
class RommRomIdIndex {
  final Map<String, int> _byKey;

  /// Provenance per key, for callers that need to tell a manual row apart
  /// (the connect-time pass reports them as conflicts). Keys missing here
  /// read as [RommLinkSource.auto], so an index built from ids alone — the
  /// shape tests construct — behaves like a table of legacy null rows.
  final Map<String, RommLinkSource> _sourceByKey;

  const RommRomIdIndex(this._byKey, [this._sourceByKey = const {}]);

  /// Composite key for the two-part identity, built in exactly one place so
  /// that the read and the write cannot drift apart.
  ///
  /// The separator is a tab rather than a space because both halves can contain
  /// spaces: `("Game Boy", "Tetris")` and `("Game", "Boy Tetris")` would
  /// otherwise collide on one key.
  static String _keyFor(String systemFolder, String romname) =>
      '$systemFolder\t$romname';

  /// The RomM ROM id for a local game, or null when it isn't linked.
  int? lookup(String romname, String systemFolder) =>
      _byKey[_keyFor(systemFolder, romname)];

  /// How the local game's row was written, or null when it isn't linked.
  RommLinkSource? sourceFor(String romname, String systemFolder) {
    final key = _keyFor(systemFolder, romname);
    if (!_byKey.containsKey(key)) return null;
    return _sourceByKey[key] ?? RommLinkSource.auto;
  }

  /// Number of mapped games (not index entries — a game is indexed under both
  /// spellings of its name).
  int get mappedGames => _byKey.values.toSet().length;

  bool get isEmpty => _byKey.isEmpty;
}

/// One row to link, for [RommSaveMapRepository.putMappingsIfAbsent].
///
/// [romname] is the library's canonical on-disk filename (the spelling the
/// sync layer looks games up by), [systemFolder] the local system folder, and
/// [fsName] the server-side name the link was made from.
typedef RommSaveMapEntry = ({
  String romname,
  String systemFolder,
  int rommRomId,
  String? fsName,
});

/// Repository for the RomM save-sync mapping table (`app_romm_rom_map`).
///
/// Links a local game (its [romname] within a [systemFolder]) to the RomM ROM
/// id it was downloaded from, so save/state sync can target the correct
/// `rom_id`. Per the architecture rules, this is the only layer that touches
/// [SqliteService] for this data.
///
/// Three kinds of writer share the table, and the rule between them lives
/// here rather than at the call sites: a [RommLinkSource.manual] row is never
/// replaced by a [RommLinkSource.download] or [RommLinkSource.auto] write, a
/// manual write replaces anything, and the insert-if-absent paths never
/// replace at all.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
class RommSaveMapRepository {
  static final _log = LoggerService.instance;

  /// Columns every row read goes through, so the two spellings of a lookup
  /// (see [_findRow]) decode the same way.
  static const List<String> _rowColumns = [
    'romname',
    'romm_rom_id',
    'romm_fs_name',
    'link_source',
  ];

  /// Records the mapping for a ROM, replacing an existing row unless that row
  /// was written by the user.
  ///
  /// The download path's write: a re-download legitimately re-targets the
  /// row to the ROM that was just fetched — except when the row is
  /// [RommLinkSource.manual], which stays exactly as the user picked it and
  /// the download still completes. The guard is the upsert's `WHERE`, so the
  /// check and the write are one parameterized statement. Returns true when
  /// the row was written, false when a manual row was kept (or on error,
  /// which is logged).
  ///
  /// Only [RommLinkSource.download] replaces; [RommLinkSource.auto] is
  /// routed to [putMappingIfAbsent] and [RommLinkSource.manual] to
  /// [putManualMapping], which has no guard.
  // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
  static Future<bool> putMapping({
    required String romname,
    required String systemFolder,
    required int rommRomId,
    required RommLinkSource source,
    String? fsName,
  }) async {
    if (source == RommLinkSource.manual) {
      return putManualMapping(
        romname: romname,
        systemFolder: systemFolder,
        rommRomId: rommRomId,
        fsName: fsName,
      );
    }
    // An automatic writer never replaces anything (SPEC-0001 "Existing
    // Mappings Are Never Overwritten"); only the download path re-targets a
    // non-manual row. Route `auto` to the insert-if-absent write so a future
    // caller cannot overwrite a download row by picking the wrong source.
    if (source == RommLinkSource.auto) {
      return putMappingIfAbsent(
        romname: romname,
        systemFolder: systemFolder,
        rommRomId: rommRomId,
        fsName: fsName,
      );
    }
    try {
      final db = await SqliteService.getDatabase();
      final changed = await db.rawUpdate(_upsertUnlessManualSql, [
        romname,
        systemFolder,
        rommRomId,
        fsName,
        source.dbValue,
        DateTime.now().toIso8601String(),
        RommLinkSource.manual.dbValue,
      ]);
      if (changed == 0) {
        _log.i(
          'RomM rom map kept the manual link for $systemFolder/$romname; '
          'a ${source.dbValue} write to rom $rommRomId was not applied',
        );
      }
      return changed > 0;
    } catch (e) {
      _log.e('Error saving RomM rom map ($romname/$systemFolder): $e');
      return false;
    }
  }

  /// Records the mapping the user picked, replacing whatever row the key had.
  ///
  /// The picker's write. Unlike [putMapping] there is no guard: the user is
  /// the authority, and a manual row over a manual row is a re-pick. Callers
  /// key it the way the download path does — the on-disk filename within the
  /// system's canonical folder — so it replaces the automatic row for the same
  /// file rather than sitting beside it under another spelling. Returns true
  /// when written, false on error (logged).
  // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
  static Future<bool> putManualMapping({
    required String romname,
    required String systemFolder,
    required int rommRomId,
    String? fsName,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.rawUpdate(_upsertSql, [
        romname,
        systemFolder,
        rommRomId,
        fsName,
        RommLinkSource.manual.dbValue,
        DateTime.now().toIso8601String(),
      ]);
      return true;
    } catch (e) {
      _log.e('Error saving manual RomM rom map ($romname/$systemFolder): $e');
      return false;
    }
  }

  /// Links a local game to a RomM ROM only when no row exists for it yet.
  ///
  /// Returns true when a row was written, false when the `(romname,
  /// systemFolder)` key already held a mapping — which is left exactly as it
  /// was, even if it points at a different ROM. This is the write the link
  /// paths for pre-existing ROMs use: unlike [putMapping], which the download
  /// path legitimately uses to re-target a re-downloaded ROM, a link inferred
  /// from a filename must never clobber a row somebody else wrote (the manual
  /// picker, or a download that finished first). The boolean is what gives
  /// callers their "linked" versus "already linked" counts.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
  static Future<bool> putMappingIfAbsent({
    required String romname,
    required String systemFolder,
    required int rommRomId,
    String? fsName,
  }) async {
    final inserted = await putMappingsIfAbsent([
      (
        romname: romname,
        systemFolder: systemFolder,
        rommRomId: rommRomId,
        fsName: fsName,
      ),
    ]);
    return inserted == 1;
  }

  /// Batch form of [putMappingIfAbsent]; returns how many rows were inserted.
  ///
  /// For the connect-time link pass, which has a page's worth of matches for
  /// one platform and wants them written in one round trip. All inserts run in
  /// a single transaction so a failure part-way leaves the table as it was,
  /// and each is a parameterized `INSERT OR IGNORE` — existing rows are
  /// skipped, never replaced. Every row written here is tagged
  /// [RommLinkSource.auto].
  ///
  /// The count comes from SQLite's per-statement change counter rather than
  /// the inserted rowid: an ignored insert leaves `last_insert_rowid()` at
  /// whatever the previous insert set it to, so the rowid can't tell "written"
  /// from "skipped", while `changes()` is 0 for a skipped row and 1 for a
  /// written one. The adapter's `rawUpdate` reads that counter immediately
  /// after executing the statement, which is why the insert goes through it.
  ///
  /// Returns 0 on error (logged), which reads as "nothing linked" to callers.
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Database Operation Standards"
  static Future<int> putMappingsIfAbsent(List<RommSaveMapEntry> entries) async {
    if (entries.isEmpty) return 0;
    try {
      final db = await SqliteService.getDatabase();
      final now = DateTime.now().toIso8601String();
      return await db.transaction((txn) async {
        final batch = txn.batch();
        for (final e in entries) {
          batch.rawUpdate(_insertIfAbsentSql, [
            e.romname,
            e.systemFolder,
            e.rommRomId,
            e.fsName,
            RommLinkSource.auto.dbValue,
            now,
          ]);
        }
        final results = await batch.commit();
        var inserted = 0;
        for (final changed in results) {
          if (changed is int && changed > 0) inserted++;
        }
        return inserted;
      });
    } catch (e) {
      _log.e(
        'Error linking ${entries.length} RomM rom map row(s) '
        '(first: ${entries.first.romname}/${entries.first.systemFolder}): $e',
      );
      return 0;
    }
  }

  /// Parameterized insert-if-absent for [putMappingsIfAbsent]. `OR IGNORE`
  /// resolves the `(romname, system_folder)` primary-key conflict by skipping
  /// the new row, leaving the existing one untouched.
  static const String _insertIfAbsentSql =
      'INSERT OR IGNORE INTO app_romm_rom_map '
      '(romname, system_folder, romm_rom_id, romm_fs_name, link_source, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?)';

  /// Parameterized unconditional upsert for [putManualMapping]: the conflict
  /// on the primary key becomes an update of every other column.
  static const String _upsertSql =
      'INSERT INTO app_romm_rom_map '
      '(romname, system_folder, romm_rom_id, romm_fs_name, link_source, '
      'updated_at) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(romname, system_folder) DO UPDATE SET '
      'romm_rom_id = excluded.romm_rom_id, '
      'romm_fs_name = excluded.romm_fs_name, '
      'link_source = excluded.link_source, '
      'updated_at = excluded.updated_at';

  /// [_upsertSql] with the update guarded: the conflicting row is only
  /// rewritten when its `link_source` is not the manual marker (bound as the
  /// last parameter). `IS NOT` rather than `!=` so the legacy null rows
  /// compare as "not manual" instead of as unknown. A guarded-out update
  /// leaves `changes()` at 0, which is how [putMapping] reports the refusal.
  static const String _upsertUnlessManualSql =
      '$_upsertSql WHERE app_romm_rom_map.link_source IS NOT ?';

  /// Returns the on-disk indexed name (`romname`) recorded for [rommRomId]
  /// within [systemFolder], or null if that ROM hasn't been downloaded here.
  ///
  /// Used to recognise an already-downloaded multi-disc game whose bundled
  /// playlist kept an unpredictable basename we can't reconstruct from the
  /// ROM's fsName — the recorded name is the authoritative on-disk `.m3u`.
  static Future<String?> getIndexedNameForRomId(
    int rommRomId,
    String systemFolder,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'app_romm_rom_map',
        columns: ['romname'],
        where: 'romm_rom_id = ? AND system_folder = ?',
        whereArgs: [rommRomId, systemFolder],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final name = rows.first['romname']?.toString();
      return (name == null || name.isEmpty) ? null : name;
    } catch (e) {
      _log.e('Error reading RomM rom map for id $rommRomId: $e');
      return null;
    }
  }

  /// Returns the RomM ROM id for a local game, or null if not mapped.
  static Future<int?> getRommRomId(String romname, String systemFolder) async {
    return (await getMapping(romname, systemFolder))?.rommRomId;
  }

  /// Returns the mapping row for a local game with its provenance, or null if
  /// not mapped. Same resolution as [getRommRomId] — exact name first, then
  /// the extension-stripped spelling (see [_romIdByStem]) — so the Manage tab
  /// reports the row that sync actually uses. A null `link_source` reads as
  /// [RommLinkSource.auto].
  // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Provenance Column"
  static Future<RommSaveMapping?> getMapping(
    String romname,
    String systemFolder,
  ) async {
    try {
      final db = await SqliteService.getDatabase();
      final row = await _findRow(db, romname, systemFolder);
      if (row == null) return null;
      final romId = int.tryParse(row['romm_rom_id'].toString());
      if (romId == null) return null;
      final fsName = row['romm_fs_name']?.toString();
      return (
        rommRomId: romId,
        fsName: (fsName == null || fsName.isEmpty) ? null : fsName,
        source: RommLinkSource.fromDb(row['link_source']),
      );
    } catch (e) {
      _log.e('Error reading RomM rom map ($romname/$systemFolder): $e');
      return null;
    }
  }

  /// Reads the whole mapping table into a [RommRomIdIndex].
  ///
  /// For callers that resolve many games at once (the pending-upload sweep and
  /// the connect-time link pass): one query instead of two per game. Each row
  /// is indexed under both the stored name and its extension-stripped form,
  /// for the same reason [_romIdByStem] exists — the table is written with the
  /// on-disk filename (`Game.zip`) while a `GameModel` carries it already
  /// stripped. The row's provenance rides along under the same keys.
  ///
  /// Returns an empty index on error, which reads as "no games are linked" and
  /// makes the sweep a no-op rather than a crash.
  static Future<RommRomIdIndex> getRomIdIndex() async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'app_romm_rom_map',
        columns: ['romname', 'system_folder', 'romm_rom_id', 'link_source'],
      );
      final index = <String, int>{};
      final sources = <String, RommLinkSource>{};
      for (final row in rows) {
        final romId = int.tryParse(row['romm_rom_id'].toString());
        final stored = row['romname']?.toString() ?? '';
        final folder = row['system_folder']?.toString() ?? '';
        if (romId == null || stored.isEmpty || folder.isEmpty) continue;
        final source = RommLinkSource.fromDb(row['link_source']);
        final exactKey = RommRomIdIndex._keyFor(folder, stored);
        index[exactKey] = romId;
        sources[exactKey] = source;
        final stemKey = RommRomIdIndex._keyFor(folder, _stripExtension(stored));
        // Only ever *add* the stem spelling: an exact match must win, matching
        // the order the single-game path tries them in. The source follows the
        // id so both describe the same row.
        if (!index.containsKey(stemKey)) {
          index[stemKey] = romId;
          sources[stemKey] = source;
        }
      }
      return RommRomIdIndex(index, sources);
    } catch (e) {
      _log.e('Error reading the RomM rom map: $e');
      return const RommRomIdIndex({});
    }
  }

  /// Drops the mapping for a local game, returning the RomM id it was linked
  /// to (null when the game had no row).
  ///
  /// Deleting a game locally has to unlink it, or the row outlives the file:
  /// save sync would keep targeting that `rom_id`, and a later scan of an
  /// unrelated game that happens to share the name would inherit the link.
  /// Resolution goes through [getRommRomId] so the extension-stripped callers
  /// (see [_romIdByStem]) unlink too, then deletes by id within the system —
  /// matching whichever spelling of the name the row was written with.
  ///
  /// Removes the row whatever its [RommLinkSource]: the unlink action is the
  /// user's, and a deleted game's manual link has nothing left to protect.
  static Future<int?> removeMapping(String romname, String systemFolder) async {
    try {
      final romId = await getRommRomId(romname, systemFolder);
      if (romId == null) return null;
      final db = await SqliteService.getDatabase();
      await db.delete(
        'app_romm_rom_map',
        where: 'romm_rom_id = ? AND system_folder = ?',
        whereArgs: [romId, systemFolder],
      );
      return romId;
    } catch (e) {
      _log.e('Error removing RomM rom map ($romname/$systemFolder): $e');
      return null;
    }
  }

  /// Resolves RomM ROM ids to the local `rom_path` of the game they're linked
  /// to, skipping ids that aren't linked here or whose row no longer has a
  /// matching game.
  ///
  /// For the connect-time playtime pull, which starts from a short list of ids
  /// the *server* named and has to get back to local rows. Deliberately not
  /// built on [getRomIdIndex] + the game list: that pair resolves every linked
  /// game in the library to answer a question about a handful of them, and this
  /// runs on connect whether or not RomM is the active save provider.
  ///
  /// Both spellings of the stored name are tried, for the reason [_romIdByStem]
  /// exists — the mapping is written with the on-disk filename (`Game.zip`)
  /// while `user_roms.filename` carries it stripped. Only the *stored* name is
  /// stripped, never the one read back, so a title with its own dot ("Mr. Do")
  /// can't be cut short.
  static Future<Map<int, String>> getRomPathsForRomIds(
    Iterable<int> romIds,
  ) async {
    final ids = romIds.toSet();
    if (ids.isEmpty) return const {};
    final out = <int, String>{};
    try {
      final db = await SqliteService.getDatabase();
      final placeholders = List.filled(ids.length, '?').join(',');
      final mapRows = await db.query(
        'app_romm_rom_map',
        columns: ['romname', 'system_folder', 'romm_rom_id'],
        where: 'romm_rom_id IN ($placeholders)',
        whereArgs: ids.toList(),
      );
      for (final row in mapRows) {
        final romId = int.tryParse(row['romm_rom_id'].toString());
        final stored = row['romname']?.toString() ?? '';
        final folder = row['system_folder']?.toString() ?? '';
        if (romId == null || stored.isEmpty || folder.isEmpty) continue;
        if (out.containsKey(romId)) continue;

        final games = await db.rawQuery(
          '''
          SELECT ur.rom_path
          FROM user_roms ur
          JOIN app_systems s ON ur.app_system_id = s.id
          WHERE s.folder_name = ? AND ur.filename IN (?, ?)
          LIMIT 1
          ''',
          [folder, stored, _stripExtension(stored)],
        );
        if (games.isEmpty) continue;
        final path = games.first['rom_path']?.toString() ?? '';
        if (path.isNotEmpty) out[romId] = path;
      }
    } catch (e) {
      // An empty result reads as "nothing to pull", which is the right
      // degradation for a statistic.
      _log.e('Error resolving RomM rom paths: $e');
    }
    return out;
  }

  /// The row for a local game: an exact match on the stored name first, then
  /// [_romIdByStem]. Shared by every single-game read so they cannot disagree
  /// about which row a game resolves to.
  static Future<Map<String, Object?>?> _findRow(
    dynamic db,
    String romname,
    String systemFolder,
  ) async {
    final rows = await db.query(
      'app_romm_rom_map',
      columns: _rowColumns,
      where: 'romname = ? AND system_folder = ?',
      whereArgs: [romname, systemFolder],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first;
    return await _romIdByStem(db, romname, systemFolder);
  }

  /// Second pass for [_findRow], matching on the extension-stripped name.
  ///
  /// Callers disagree about what a "romname" is. The mapping is written with
  /// the on-disk filename (`Game.zip`) — and [getIndexedNameForRomId] depends
  /// on that staying intact — while a [GameModel] carries `romname` with the
  /// extension already stripped. An exact match therefore misses for every
  /// game launched normally, and since an unresolved id reads as "not a RomM
  /// game", save sync and playtime both went quietly nowhere.
  ///
  /// Scoped to one system folder, which the table's index covers, and only
  /// reached when the exact match fails.
  static Future<Map<String, Object?>?> _romIdByStem(
    dynamic db,
    String romname,
    String systemFolder,
  ) async {
    final rows = await db.query(
      'app_romm_rom_map',
      columns: _rowColumns,
      where: 'system_folder = ?',
      whereArgs: [systemFolder],
    );
    // Only the stored name is stripped. [romname] arrives already extensionless
    // here (the exact match above covers callers that pass a full filename),
    // and stripping it again would cut a title at its own dot — "Mr. Do"
    // becoming "Mr", matching the wrong ROM or nothing at all.
    for (final row in rows) {
      final stored = row['romname']?.toString() ?? '';
      if (_stripExtension(stored) == romname) return row;
    }
    return null;
  }

  /// Drops a trailing file extension, matching `DatabaseGameModel.romname`.
  static String _stripExtension(String name) {
    final lastDot = name.lastIndexOf('.');
    return lastDot > 0 ? name.substring(0, lastDot) : name;
  }
}
