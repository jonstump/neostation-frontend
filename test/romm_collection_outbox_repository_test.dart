import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/repositories/collection_repository.dart';
import 'package:neostation/repositories/romm_collection_outbox_repository.dart';
import 'package:neostation/services/romm/romm_collection_outbox_service.dart';

import 'database_test_helper.dart';

/// The origin column through [CollectionRepository] and [CollectionModel],
/// the collection outbox repository's coalescing writes, and the queue rule
/// that only a `local`-origin collection may leave a row.
///
/// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Origin Column",
/// REQ "Follow-Up Pushes", REQ "Database Operation Standards"
void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  const server = 'https://romm.local';
  final syncedAt = DateTime.utc(2026, 9, 8, 10, 30);

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsIndexSql);
    await db.execute(SqliteMigrations.createAppRommCollectionOutboxTableSql);
  });

  tearDown(() => helper.tearDown());

  Future<CollectionModel> model(String id) async => CollectionModel.fromJson(
    (await CollectionRepository.getCollectionById(id))!,
  );

  Future<void> link(
    String id, {
    required String origin,
    String rommId = '12',
  }) => CollectionRepository.setRommProvenance(
    id,
    serverUrl: server,
    collectionId: rommId,
    virtual: false,
    syncedAt: syncedAt,
    origin: origin,
  );

  group('origin column', () {
    test('a plain collection has no origin and is neither kind', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      final c = await model('c1');
      expect(c.rommOrigin, isNull);
      expect(c.isRommMirror, isFalse);
      expect(c.isPushedToRomm, isFalse);
    });

    test('setRommProvenance records the origin with the link', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originLocal);

      final c = await model('c1');
      expect(c.rommOrigin, 'local');
      expect(c.isPushedToRomm, isTrue);
      expect(c.isRommMirror, isTrue, reason: 'linked either way');
      expect(c.rommCollectionId, '12');
    });

    test('the mirror insert writes origin romm', () async {
      await CollectionRepository.insertRommMirrorCollection(
        id: 'c1',
        name: 'Best of SNES',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );
      final c = await model('c1');
      expect(c.rommOrigin, 'romm');
      expect(c.isRommMirror, isTrue);
      expect(c.isPushedToRomm, isFalse);
    });

    test('the listing and the mirror lookup carry the origin too', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originLocal);

      final listed = CollectionModel.fromJson(
        (await CollectionRepository.getCollections()).single,
      );
      expect(listed.isPushedToRomm, isTrue);
      final found = await CollectionRepository.findRommMirror(server, '12');
      expect(found?['romm_origin'], 'local');
    });

    test('setRommOrigin changes only the origin', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originRomm);

      await CollectionRepository.setRommOrigin(
        'c1',
        CollectionModel.originLocal,
      );
      var c = await model('c1');
      expect(c.rommOrigin, 'local');
      expect(c.rommCollectionId, '12');
      expect(c.rommSyncedAt, syncedAt);

      await CollectionRepository.setRommOrigin('c1', null);
      c = await model('c1');
      expect(c.rommOrigin, isNull);
      expect(c.rommCollectionId, '12', reason: 'still linked');
    });

    // Scenario: unlink pushed.
    test('clearRommProvenance clears the origin with the link', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originLocal);

      await CollectionRepository.clearRommProvenance('c1');

      final c = await model('c1');
      expect(c.rommOrigin, isNull);
      expect(c.rommCollectionId, isNull);
      expect(c.isPushedToRomm, isFalse);
      expect(c.name, 'RPGs');
    });

    test('the model round-trips and copies the origin', () {
      final pushed = CollectionModel.fromJson(const {
        'id': 'c1',
        'name': 'RPGs',
        'romm_collection_id': '12',
        'romm_origin': 'local',
      });
      expect(pushed.isPushedToRomm, isTrue);
      expect(pushed.toJson().containsKey('romm_origin'), isFalse);

      final mirror = pushed.copyWith(rommOrigin: CollectionModel.originRomm);
      expect(mirror.isPushedToRomm, isFalse);
      expect(mirror.isRommMirror, isTrue);
      expect(mirror, isNot(equals(pushed)));

      final unlinked = pushed.copyWith(clearRommProvenance: true);
      expect(unlinked.rommOrigin, isNull);
      expect(unlinked.rommCollectionId, isNull);

      expect(
        CollectionModel.fromJson(const {
          'id': 'c1',
          'name': 'x',
          'romm_origin': '',
        }).rommOrigin,
        isNull,
      );
      // Origin without a link is not "pushed": the id is what a push needs.
      expect(
        CollectionModel.fromJson(const {
          'id': 'c1',
          'name': 'x',
          'romm_origin': 'local',
        }).isPushedToRomm,
        isFalse,
      );
    });
  });

  group('RommCollectionOutboxRepository', () {
    Future<bool> mark(
      String id, {
      bool name = false,
      bool artwork = false,
      bool members = false,
      bool delete = false,
    }) => RommCollectionOutboxRepository.upsert(
      collectionId: id,
      rommServerUrl: server,
      rommCollectionId: '12',
      nameDirty: name,
      artworkDirty: artwork,
      membersDirty: members,
      deleteRemote: delete,
    );

    test('marking coalesces into one row per collection', () async {
      expect(await mark('c1', name: true), isTrue);
      expect(await mark('c1', name: true), isTrue);
      expect(await mark('c1', members: true), isTrue);
      expect(await mark('c1', members: true), isTrue);

      final rows = await RommCollectionOutboxRepository.listDirty();
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.collectionId, 'c1');
      expect(row.rommServerUrl, server);
      expect(row.rommCollectionId, '12');
      expect(row.nameDirty, isTrue);
      expect(row.membersDirty, isTrue);
      expect(row.artworkDirty, isFalse);
      expect(row.deleteRemote, isFalse);
      expect(row.lastPushedRomIds, isNull);
      expect(await RommCollectionOutboxRepository.pendingCount(), 1);
    });

    test(
      'a flag only turns on: a later mark never clears an earlier one',
      () async {
        await mark('c1', name: true, artwork: true);
        await mark('c1', members: true);

        final row = (await RommCollectionOutboxRepository.listDirty()).single;
        expect(row.nameDirty, isTrue);
        expect(row.artworkDirty, isTrue);
        expect(row.membersDirty, isTrue);
      },
    );

    test('nothing to mark writes nothing', () async {
      expect(await mark('c1'), isFalse);
      expect(await mark(''), isFalse);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });

    test('rows list oldest change first', () async {
      await mark('newer', name: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await mark('older', name: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await mark('newer', members: true);

      final ids = (await RommCollectionOutboxRepository.listDirty())
          .map((r) => r.collectionId)
          .toList();
      expect(ids, ['older', 'newer']);
    });

    test('clearDirty clears only the given flags and keeps the row', () async {
      await mark('c1', name: true, members: true);

      expect(
        await RommCollectionOutboxRepository.clearDirty('c1', name: true),
        1,
      );
      var row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.nameDirty, isFalse);
      expect(row.membersDirty, isTrue);

      await RommCollectionOutboxRepository.clearDirty('c1', members: true);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      expect(
        await RommCollectionOutboxRepository.get('c1'),
        isNotNull,
        reason: 'a clean row stays as the baseline holder',
      );
      row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.nameDirty, isFalse);
    });

    test(
      'clearDirty with unlessChangedSince spares an edit made meanwhile',
      () async {
        await mark('c1', name: true);
        final listed =
            (await RommCollectionOutboxRepository.listDirty()).single;

        // The user renames again while the push is in flight.
        await Future<void>.delayed(const Duration(milliseconds: 2));
        await mark('c1', name: true);

        final cleared = await RommCollectionOutboxRepository.clearDirty(
          'c1',
          name: true,
          unlessChangedSince: listed.updatedAt,
        );
        expect(cleared, 0);
        final row = (await RommCollectionOutboxRepository.listDirty()).single;
        expect(row.nameDirty, isTrue, reason: 'the second rename still pushes');
      },
    );

    test('clearDirty with an unchanged updatedAt clears', () async {
      await mark('c1', name: true);
      final listed = (await RommCollectionOutboxRepository.listDirty()).single;

      final cleared = await RommCollectionOutboxRepository.clearDirty(
        'c1',
        name: true,
        unlessChangedSince: listed.updatedAt,
      );
      expect(cleared, 1);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });

    test('recordPushedRomIds stores the baseline without dirtying', () async {
      expect(
        await RommCollectionOutboxRepository.recordPushedRomIds(
          'c1',
          [3, 1, 2, 2],
          rommServerUrl: server,
          rommCollectionId: '12',
        ),
        isTrue,
      );
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {1, 2, 3});
      expect(row.rommCollectionId, '12');
      expect(row.updatedAt, isNull);

      // On a dirty row the flags and the edit time are left alone.
      await mark('c1', members: true);
      final before = (await RommCollectionOutboxRepository.get('c1'))!;
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        [9],
        rommServerUrl: server,
        rommCollectionId: '12',
      );
      final after = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(after.membersDirty, isTrue);
      expect(after.updatedAt, before.updatedAt);
      expect(after.lastPushedRomIds, {9});
    });

    test('a corrupt baseline reads as no baseline', () async {
      await mark('c1', members: true);
      await db.execute(
        "UPDATE app_romm_collection_outbox SET last_pushed_rom_ids = 'nope' "
        "WHERE collection_id = 'c1'",
      );
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.lastPushedRomIds, isNull);
    });

    test('delete drops one row, clear drops all', () async {
      await mark('c1', name: true);
      await mark('c2', delete: true);

      expect(await RommCollectionOutboxRepository.delete('c1'), 1);
      expect(await RommCollectionOutboxRepository.delete('c1'), 0);
      expect(await RommCollectionOutboxRepository.pendingCount(), 1);

      expect(await RommCollectionOutboxRepository.clear(), 1);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });

    test('a missing table reads as nothing pending', () async {
      await db.execute('DROP TABLE app_romm_collection_outbox');
      expect(await mark('c1', name: true), isFalse);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      expect(await RommCollectionOutboxRepository.get('c1'), isNull);
    });
  });

  group('RommCollectionOutboxService.queue', () {
    test('a local-origin collection queues with its provenance', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originLocal, rommId: '30');

      expect(await RommCollectionOutboxService.queue('c1', name: true), isTrue);
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.rommServerUrl, server);
      expect(row.rommCollectionId, '30');
      expect(row.nameDirty, isTrue);
    });

    // Scenario: romm-origin collections MUST NOT queue.
    test('a mirror never queues', () async {
      await CollectionRepository.insertRommMirrorCollection(
        id: 'm1',
        name: 'Best of SNES',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );

      expect(
        await RommCollectionOutboxService.queue('m1', members: true),
        isFalse,
      );
      expect(
        await RommCollectionOutboxService.queue('m1', deleteRemote: true),
        isFalse,
      );
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });

    test('an unlinked or unknown collection never queues', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      expect(
        await RommCollectionOutboxService.queue('c1', name: true),
        isFalse,
      );
      expect(
        await RommCollectionOutboxService.queue('nope', name: true),
        isFalse,
      );
      expect(
        await RommCollectionOutboxService.queue('c1'),
        isFalse,
        reason: 'nothing to mark',
      );
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });

    test(
      'a delete queued before the local row goes keeps its target',
      () async {
        await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
        await link('c1', origin: CollectionModel.originLocal, rommId: '30');

        expect(
          await RommCollectionOutboxService.queue('c1', deleteRemote: true),
          isTrue,
        );
        await CollectionRepository.deleteCollection('c1');

        final row = (await RommCollectionOutboxRepository.listDirty()).single;
        expect(row.deleteRemote, isTrue);
        expect(row.rommCollectionId, '30');
      },
    );

    test('discard forgets everything queued for the collection', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await link('c1', origin: CollectionModel.originLocal);
      await RommCollectionOutboxService.queue('c1', name: true, members: true);

      expect(await RommCollectionOutboxService.discard('c1'), 1);
      expect(await RommCollectionOutboxRepository.listDirty(), isEmpty);
    });
  });
}
