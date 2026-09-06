import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/repositories/collection_repository.dart';

import 'database_test_helper.dart';

/// [CollectionRepository]'s RomM mirror operations against an in-memory
/// database: provenance find/set/clear, the one-transaction membership
/// replace, and the chunked delete a large virtual collection needs.
///
/// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ
/// "Collection Provenance Columns", REQ "Database Operation Standards"
void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  const server = 'https://romm.local';
  final syncedAt = DateTime.utc(2026, 9, 5, 10, 30);

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsIndexSql);
  });

  tearDown(() => helper.tearDown());

  Future<Set<String>> members(String id) =>
      CollectionRepository.getMemberRomPaths(id);

  Future<CollectionModel> model(String id) async => CollectionModel.fromJson(
    (await CollectionRepository.getCollectionById(id))!,
  );

  group('provenance', () {
    test('a plain collection has none and is no mirror', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      final c = await model('c1');
      expect(c.isRommMirror, isFalse);
      expect(c.rommServerUrl, isNull);
      expect(c.rommCollectionId, isNull);
      expect(c.rommCollectionVirtual, isFalse);
      expect(c.rommSyncedAt, isNull);
      expect(await CollectionRepository.findRommMirror(server, '12'), isNull);
    });

    test('setRommProvenance links and findRommMirror finds it', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'RPGs');
      await CollectionRepository.setRommProvenance(
        'c1',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );

      final found = await CollectionRepository.findRommMirror(server, '12');
      expect(found?['id'], 'c1');
      expect(found?['game_count'], 0);

      final c = await model('c1');
      expect(c.isRommMirror, isTrue);
      expect(c.rommServerUrl, server);
      expect(c.rommCollectionId, '12');
      expect(c.rommCollectionVirtual, isFalse);
      expect(c.rommSyncedAt, syncedAt);
      expect(c.name, 'RPGs', reason: 'provenance never touches the name');
    });

    test('provenance is scoped per server and per id', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.setRommProvenance(
        'c1',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );
      expect(
        await CollectionRepository.findRommMirror('https://other', '12'),
        isNull,
      );
      expect(await CollectionRepository.findRommMirror(server, '13'), isNull);
    });

    test('the listing query carries provenance too', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.setRommProvenance(
        'c1',
        serverUrl: server,
        collectionId: 'genre:rpg',
        virtual: true,
        syncedAt: syncedAt,
      );
      final rows = await CollectionRepository.getCollections();
      final c = CollectionModel.fromJson(rows.single);
      expect(c.rommCollectionId, 'genre:rpg');
      expect(c.rommCollectionVirtual, isTrue);
    });

    test('clearRommProvenance unlinks and keeps everything else', () async {
      await CollectionRepository.insertRommMirrorCollection(
        id: 'c1',
        name: 'Best of SNES',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );
      await CollectionRepository.updateCollection('c1', color1: '#123456');
      await CollectionRepository.addRomToCollection('c1', '/roms/snes/a.sfc');

      await CollectionRepository.clearRommProvenance('c1');

      final c = await model('c1');
      expect(c.isRommMirror, isFalse);
      expect(c.rommServerUrl, isNull);
      expect(c.rommSyncedAt, isNull);
      expect(c.name, 'Best of SNES');
      expect(c.color1, '#123456');
      expect(await members('c1'), {'/roms/snes/a.sfc'});
      expect(await CollectionRepository.findRommMirror(server, '12'), isNull);
    });

    test('insertRommMirrorCollection creates row and provenance', () async {
      await CollectionRepository.insertCollection(id: 'c0', name: 'First');
      await CollectionRepository.insertRommMirrorCollection(
        id: 'c1',
        name: 'Best of SNES',
        serverUrl: server,
        collectionId: '12',
        virtual: false,
        syncedAt: syncedAt,
      );
      final c = await model('c1');
      expect(c.name, 'Best of SNES');
      expect(c.isRommMirror, isTrue);
      expect(c.rommServerUrl, server);
      expect(c.rommCollectionId, '12');
      expect(c.rommSyncedAt, syncedAt);
      expect(c.sortOrder, 1, reason: 'appended after the existing one');
      expect(c.imagePath, isNull);
    });
  });

  group('replaceMembers', () {
    test('adds every path to an empty collection', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      final change = await CollectionRepository.replaceMembers('c1', {
        '/r/a.sfc',
        '/r/b.sfc',
      });
      expect(change, (added: 2, removed: 0));
      expect(await members('c1'), {'/r/a.sfc', '/r/b.sfc'});
      final rows = await db.rawQuery(
        'SELECT rom_path, sort_order FROM user_collection_items '
        'WHERE collection_id = ? ORDER BY sort_order',
        ['c1'],
      );
      expect(rows.map((r) => r['sort_order']).toList(), [0, 1]);
    });

    test('adds missing and removes stale, keeping the rest', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.addRomToCollection('c1', '/r/keep.sfc');
      await CollectionRepository.addRomToCollection('c1', '/r/stale.sfc');

      final change = await CollectionRepository.replaceMembers('c1', {
        '/r/keep.sfc',
        '/r/new.sfc',
      });

      expect(change, (added: 1, removed: 1));
      expect(await members('c1'), {'/r/keep.sfc', '/r/new.sfc'});
    });

    test('an empty set empties the collection', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.addRomToCollection('c1', '/r/a.sfc');
      final change = await CollectionRepository.replaceMembers('c1', {});
      expect(change, (added: 0, removed: 1));
      expect(await members('c1'), isEmpty);
    });

    test('the same set is a no-op', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.addRomToCollection('c1', '/r/a.sfc');
      final change = await CollectionRepository.replaceMembers('c1', {
        '/r/a.sfc',
      });
      expect(change, (added: 0, removed: 0));
      expect(await members('c1'), {'/r/a.sfc'});
    });

    test('compares paths case-insensitively like the column', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.addRomToCollection('c1', '/r/Game.sfc');
      final change = await CollectionRepository.replaceMembers('c1', {
        '/r/game.sfc',
      });
      expect(change, (added: 0, removed: 0));
      expect(await members('c1'), {'/r/Game.sfc'});
    });

    test('only touches the named collection', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.insertCollection(id: 'c2', name: 'B');
      await CollectionRepository.addRomToCollection('c2', '/r/a.sfc');
      await CollectionRepository.addRomToCollection('c2', '/r/b.sfc');

      await CollectionRepository.replaceMembers('c1', {'/r/a.sfc'});

      expect(await members('c1'), {'/r/a.sfc'});
      expect(await members('c2'), {'/r/a.sfc', '/r/b.sfc'});
    });

    test('adds and removes atomically — both or neither', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      await CollectionRepository.addRomToCollection('c1', '/r/stale.sfc');
      // Make the second insert of the replace fail mid-transaction: the
      // delete of the stale member and the first insert already ran and
      // must roll back with it.
      await db.execute('''
        CREATE TRIGGER reject_poison BEFORE INSERT ON user_collection_items
        WHEN NEW.rom_path = '/r/poison.sfc'
        BEGIN SELECT RAISE(ABORT, 'poison'); END
      ''');

      await expectLater(
        () => CollectionRepository.replaceMembers('c1', {
          '/r/aaa_other.sfc',
          '/r/poison.sfc',
        }),
        throwsA(anything),
      );

      expect(await members('c1'), {
        '/r/stale.sfc',
      }, reason: 'neither the delete nor the first insert may survive');
      // The connection is usable afterwards: the transaction was closed.
      final change = await CollectionRepository.replaceMembers('c1', {
        '/r/fine.sfc',
      });
      expect(change, (added: 1, removed: 1));
      expect(await members('c1'), {'/r/fine.sfc'});
    });

    test('chunks large sets past the SQLite variable limit', () async {
      await CollectionRepository.insertCollection(id: 'c1', name: 'A');
      final first = {for (var i = 0; i < 1200; i++) '/r/first_$i.sfc'};
      final change1 = await CollectionRepository.replaceMembers('c1', first);
      expect(change1, (added: 1200, removed: 0));
      expect((await members('c1')).length, 1200);

      // Replace all 1200 with 1200 others: 1200 deletes (three chunks) and
      // 1200 inserts in one transaction.
      final second = {for (var i = 0; i < 1200; i++) '/r/second_$i.sfc'};
      final change2 = await CollectionRepository.replaceMembers('c1', second);
      expect(change2, (added: 1200, removed: 1200));
      expect(await members('c1'), second);
    });
  });
}
