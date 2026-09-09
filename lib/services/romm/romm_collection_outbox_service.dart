import 'dart:io';

import '../../models/collection_model.dart';
import '../../models/romm_server_capabilities.dart';
import '../../repositories/collection_repository.dart';
import '../../repositories/romm_collection_outbox_repository.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../logger_service.dart';
import '../romm_service.dart';

/// What one [RommCollectionOutboxService.flush] did, for the caller's log
/// line.
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
typedef RommCollectionFlushSummary = ({
  /// Collections whose pending aspects the server all confirmed.
  int pushed,

  /// Rows dropped without a push: the collection is gone from the server
  /// (404), gone from the library, or no longer `local`-origin.
  int dropped,

  /// Rows left in place — in full or in part — for the next flush.
  int kept,
});

/// A collection's members as RomM ROM ids: the linked ones, and how many
/// could not be resolved (no link row), which the push outcome reports.
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
typedef RommCollectionMemberIds = ({Set<int> romIds, int unlinked});

/// The queue side of the collection push: the one place a local edit to a
/// pushed collection (rename, image change or clear, member add or remove,
/// delete) turns into an outbox row — and the flush that drains it.
///
/// Purely local on the queue side — no network, no provider — so
/// `CollectionsService` can call it from every edit path regardless of
/// connectivity. The flush runs with the play-state flush from
/// `RommProvider` once a connection exists.
///
/// Layering: this is a service, so it reads and writes through repositories
/// only ([RommCollectionOutboxRepository], [CollectionRepository],
/// [RommSaveMapRepository]) and never touches a datasource.
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Error Handling Standards"
class RommCollectionOutboxService {
  const RommCollectionOutboxService._();

  static final _log = LoggerService.instance;

  /// Queues pending aspects of collection [collectionId].
  ///
  /// The origin rule lives here rather than at the call sites: the
  /// collection row is read, and only a collection with
  /// [CollectionModel.isPushedToRomm] — origin `local` and a RomM id —
  /// queues. A mirror (origin `romm`), an unlinked collection, or one that
  /// no longer exists writes nothing, so a hook can call this on every edit
  /// without checking first.
  ///
  /// [deleteRemote] is queued *before* the local row is deleted: the outbox
  /// row copies the provenance, so the delete still knows its target after
  /// the collection is gone.
  ///
  /// Returns true when a row was written or updated.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
  static Future<bool> queue(
    String collectionId, {
    bool name = false,
    bool artwork = false,
    bool members = false,
    bool deleteRemote = false,
  }) async {
    if (collectionId.isEmpty) return false;
    if (!name && !artwork && !members && !deleteRemote) return false;

    final row = await CollectionRepository.getCollectionById(collectionId);
    if (row == null) return false;
    final collection = CollectionModel.fromJson(row);
    if (!collection.isPushedToRomm) return false;

    return RommCollectionOutboxRepository.upsert(
      collectionId: collectionId,
      rommServerUrl: collection.rommServerUrl,
      rommCollectionId: collection.rommCollectionId,
      nameDirty: name,
      artworkDirty: artwork,
      membersDirty: members,
      deleteRemote: deleteRemote,
    );
  }

  /// Forgets everything queued for [collectionId] — what unlink calls, so a
  /// collection that is no longer pushed is not pushed once more later.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Origin Column"
  static Future<int> discard(String collectionId) =>
      RommCollectionOutboxRepository.delete(collectionId);

  /// The members of collection [collectionId] as RomM ROM ids, resolved
  /// through the link map ([RommSaveMapRepository.getRomIdIndex]) by each
  /// member's filename and system folder. Unlinked members are counted, not
  /// pushed (ADR-0015).
  ///
  /// Membership is read through [CollectionRepository] — the games query,
  /// which joins the system so the folder is known — never from the items
  /// table directly.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Database Operation Standards"
  static Future<RommCollectionMemberIds> resolveMemberRomIds(
    String collectionId,
  ) async {
    final games = await CollectionRepository.getGamesInCollection(collectionId);
    if (games.isEmpty) return (romIds: const <int>{}, unlinked: 0);
    final index = await RommSaveMapRepository.getRomIdIndex();
    final romIds = <int>{};
    var unlinked = 0;
    for (final game in games) {
      final romId = index.lookup(game.filename, game.systemFolderName ?? '');
      if (romId == null) {
        unlinked++;
      } else {
        romIds.add(romId);
      }
    }
    return (romIds: romIds, unlinked: unlinked);
  }

  /// Pushes every dirty collection to RomM through [service], oldest change
  /// first.
  ///
  /// Per row: **one** `PUT` ([RommService.updateCollection]) carrying every
  /// dirty aspect — `name` when the name is dirty, `artwork` (or
  /// `remove_cover` when the collection has no image any more) when the
  /// artwork is dirty — and always `rom_ids`, which RomM requires on every
  /// PUT: the resolved current members when the members are dirty, else
  /// the row's `last_pushed_rom_ids` baseline (what the server holds), else
  /// the resolved members. The one exception is a members-only change on a
  /// server that answers [RommFeature.collectionRomsAddRemove] (4.9.0+)
  /// with a baseline to diff against: that goes out as an add/remove diff,
  /// which leaves a RomM-side membership edit alone where a replace would
  /// overwrite it. A row flagged `delete_remote` gets one
  /// [RommService.deleteCollection] instead. The aspects a confirmed
  /// request carried are cleared together, and the baseline is refreshed
  /// after any request that carried members.
  ///
  /// Rows that can never succeed are dropped rather than retried forever:
  /// a collection the server no longer has (404 — its provenance and origin
  /// are cleared locally, one warning names it), one the library no longer
  /// holds, one that is no longer `local`-origin, or one queued under a RomM
  /// id that is not the collection's any more. A row for another server than
  /// the connected one is kept untouched.
  ///
  /// A denied scope or a gated feature leaves the row in place: the service
  /// sends nothing and logs why once per connection, and the edits wait for
  /// a connection that can carry them. Any other failure keeps the row with
  /// one warning naming the collection and status. Stops early — leaving the
  /// remaining rows for next time — when [isConnected] turns false between
  /// rows, and when a call fails without a status (the server is
  /// unreachable, so every later row would fail the same way).
  ///
  /// Never throws; a failure reading the outbox reads as "nothing pending".
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Error Handling Standards"
  static Future<RommCollectionFlushSummary> flush(
    RommService service, {
    required bool Function() isConnected,
  }) async {
    var pushed = 0;
    var dropped = 0;
    var kept = 0;

    final rows = await RommCollectionOutboxRepository.listDirty();
    if (rows.isEmpty) return (pushed: 0, dropped: 0, kept: 0);

    final serverUrl = service.baseUrl;
    var index = 0;
    for (; index < rows.length; index++) {
      final row = rows[index];
      if (!isConnected()) {
        _log.i(
          'RomM collection flush stopped: reason=disconnected '
          'remaining=${rows.length - index}',
        );
        break;
      }
      if (row.rommServerUrl != null && row.rommServerUrl != serverUrl) {
        _log.d(
          'RomM collection row kept: collection=${row.collectionId} '
          'reason=other_server server=${row.rommServerUrl}',
        );
        kept++;
        continue;
      }

      final _RowOutcome outcome;
      try {
        outcome = row.deleteRemote
            ? await _deleteRemote(service, row)
            : await _pushRow(service, row);
      } on RommException catch (e) {
        if (e.statusCode == 404) {
          // The server no longer has it: nothing to push to, ever. The local
          // collection stays as an ordinary one; only the link goes.
          _log.w(
            'RomM collection gone from server (unlinked): '
            'collection=${row.collectionId} romm_id=${row.rommCollectionId} '
            'status=404',
          );
          await CollectionRepository.clearRommProvenance(row.collectionId);
          await RommCollectionOutboxRepository.delete(row.collectionId);
          dropped++;
          continue;
        }
        _log.w(
          'RomM collection push failed (kept queued): '
          'collection=${row.collectionId} romm_id=${row.rommCollectionId} '
          'status=${e.statusCode} kind=${e.kind.name} error=${e.message}',
        );
        kept++;
        if (e.statusCode == null) {
          // No status means no server: the connection is gone or timed out,
          // and every row behind this one would fail the same way.
          index++;
          break;
        }
        continue;
      } catch (e) {
        _log.w(
          'RomM collection push failed (kept queued): '
          'collection=${row.collectionId} romm_id=${row.rommCollectionId} '
          'error=$e',
        );
        kept++;
        continue;
      }

      switch (outcome) {
        case _RowOutcome.pushed:
          pushed++;
        case _RowOutcome.dropped:
          dropped++;
        case _RowOutcome.kept:
          kept++;
      }
    }
    kept += rows.length - index;

    if (pushed > 0 || dropped > 0 || kept > 0) {
      _log.i(
        'RomM collection flush: pushed=$pushed dropped=$dropped kept=$kept',
      );
    }
    return (pushed: pushed, dropped: dropped, kept: kept);
  }

  /// The delete half of the flush: the row's own RomM id is the target, so
  /// this works whether or not the local collection still exists. A
  /// confirmed (or already-gone) delete drops the row and, when the local
  /// collection is still around, its provenance — it is not on RomM any more.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Delete", REQ "Error Handling Standards"
  static Future<_RowOutcome> _deleteRemote(
    RommService service,
    RommCollectionOutboxRow row,
  ) async {
    final rommId = int.tryParse(row.rommCollectionId ?? '');
    if (rommId == null) {
      _log.i(
        'RomM collection row dropped: collection=${row.collectionId} '
        'reason=no_romm_id',
      );
      await RommCollectionOutboxRepository.delete(row.collectionId);
      return _RowOutcome.dropped;
    }
    final ok = await service.deleteCollection(rommId);
    if (!ok) return _RowOutcome.kept; // gated; the service said why once
    final local = await CollectionRepository.getCollectionById(
      row.collectionId,
    );
    if (local != null) {
      await CollectionRepository.clearRommProvenance(row.collectionId);
    }
    await RommCollectionOutboxRepository.delete(row.collectionId);
    _log.i(
      'RomM collection deleted: collection=${row.collectionId} '
      'romm_id=$rommId',
    );
    return _RowOutcome.pushed;
  }

  /// The push half of the flush: the diff for a members-only change on a
  /// server with the add/remove route, one combined PUT otherwise, the
  /// aspects it carried cleared once the server confirms. Throws
  /// [RommException] out to [flush], which decides what a status means for
  /// the row.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Error Handling Standards"
  static Future<_RowOutcome> _pushRow(
    RommService service,
    RommCollectionOutboxRow row,
  ) async {
    final local = await CollectionRepository.getCollectionById(
      row.collectionId,
    );
    final collection = local == null ? null : CollectionModel.fromJson(local);
    if (collection == null || !collection.isPushedToRomm) {
      _log.i(
        'RomM collection row dropped: collection=${row.collectionId} '
        'reason=${collection == null ? 'deleted' : 'not_local_origin'}',
      );
      await RommCollectionOutboxRepository.delete(row.collectionId);
      return _RowOutcome.dropped;
    }
    final rommId = int.tryParse(collection.rommCollectionId ?? '');
    if (rommId == null ||
        (row.rommCollectionId != null &&
            row.rommCollectionId != collection.rommCollectionId)) {
      _log.i(
        'RomM collection row dropped: collection=${row.collectionId} '
        'reason=romm_id_changed queued=${row.rommCollectionId} '
        'now=${collection.rommCollectionId}',
      );
      await RommCollectionOutboxRepository.delete(row.collectionId);
      return _RowOutcome.dropped;
    }

    final baseline = row.lastPushedRomIds;
    final aspectsBesideMembers = row.nameDirty || row.artworkDirty;

    // The diff only for a members-only change with a baseline on a server
    // that has the route: a PUT for a name or image must carry `rom_ids`
    // anyway, so a members change riding along costs nothing extra there,
    // and a replace with the resolved members is what that PUT sends.
    if (row.membersDirty &&
        !aspectsBesideMembers &&
        baseline != null &&
        service.supports(RommFeature.collectionRomsAddRemove) ==
            RommFeatureSupport.supported) {
      final members = await resolveMemberRomIds(row.collectionId);
      final add = members.romIds.difference(baseline);
      final remove = baseline.difference(members.romIds);
      var confirmed = true;
      if (add.isNotEmpty) {
        confirmed = await service.addCollectionRoms(rommId, add) && confirmed;
      }
      if (confirmed && remove.isNotEmpty) {
        confirmed = await service.removeCollectionRoms(rommId, remove);
      }
      if (!confirmed) return _kept(row, rommId);
      await _confirmMembers(row, collection, rommId, members);
      await RommCollectionOutboxRepository.clearDirty(
        row.collectionId,
        members: true,
        unlessChangedSince: row.updatedAt,
      );
      return _RowOutcome.pushed;
    }

    // Everything else is one PUT. `rom_ids` is required by the server on
    // every PUT, so a rename or an image change carries the members too:
    // the resolved set when they are dirty (the edit the row is for), the
    // last pushed set otherwise (what the server holds, so nothing changes),
    // and the resolved set again when there is no baseline to repeat.
    final RommCollectionMemberIds members;
    if (row.membersDirty || baseline == null) {
      members = await resolveMemberRomIds(row.collectionId);
    } else {
      members = (romIds: baseline, unlinked: 0);
    }

    String? artworkPath;
    var removeArtwork = false;
    if (row.artworkDirty) {
      final imagePath = collection.imagePath;
      if (imagePath != null && File(imagePath).existsSync()) {
        artworkPath = imagePath;
      } else {
        removeArtwork = true;
      }
    }

    final ok = await service.updateCollection(
      rommId,
      romIds: members.romIds,
      name: row.nameDirty ? collection.name : null,
      artworkPath: artworkPath,
      removeArtwork: removeArtwork,
    );
    if (!ok) return _kept(row, rommId);
    await _confirmMembers(row, collection, rommId, members);
    await RommCollectionOutboxRepository.clearDirty(
      row.collectionId,
      name: row.nameDirty,
      artwork: row.artworkDirty,
      members: row.membersDirty,
      unlessChangedSince: row.updatedAt,
    );
    return _RowOutcome.pushed;
  }

  /// After a confirmed request that carried members: the baseline is what
  /// the server holds now, and a push that left unlinked members behind
  /// says so once.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes"
  static Future<void> _confirmMembers(
    RommCollectionOutboxRow row,
    CollectionModel collection,
    int rommId,
    RommCollectionMemberIds members,
  ) async {
    await RommCollectionOutboxRepository.recordPushedRomIds(
      row.collectionId,
      members.romIds,
      rommServerUrl: collection.rommServerUrl,
      rommCollectionId: collection.rommCollectionId,
    );
    if (members.unlinked > 0) {
      _log.i(
        'RomM collection members pushed: collection=${row.collectionId} '
        'romm_id=$rommId linked=${members.romIds.length} '
        'unlinked=${members.unlinked}',
      );
    }
  }

  /// A row the service declined to send: the scope group is denied, and
  /// the service already logged which gate, once per connection.
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up Pushes", REQ "Error Handling Standards"
  static _RowOutcome _kept(RommCollectionOutboxRow row, int rommId) {
    _log.i(
      'RomM collection row kept: collection=${row.collectionId} '
      'romm_id=$rommId reason=gated',
    );
    return _RowOutcome.kept;
  }
}

/// What the flush did with one row.
enum _RowOutcome { pushed, dropped, kept }
