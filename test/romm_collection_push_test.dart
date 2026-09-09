import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/repositories/collection_repository.dart';
import 'package:neostation/repositories/romm_collection_outbox_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/collections/collections_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'multipart_test_helper.dart';

/// The push side of ADR-0015 through [CollectionsService]: the push action
/// (create → membership → provenance with origin `local` → baseline → the
/// counts the toast reads), the edit hooks that queue only for a pushed
/// collection and ask for a flush, the delete that queues the remote delete
/// before the local row goes, and the unlink that clears origin and forgets
/// the queue.
///
/// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Push Action",
/// REQ "Follow-Up Pushes", REQ "Delete", REQ "Origin Badge"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();

  const server = 'https://romm.local';
  const zeldaPath = '/roms/snes/zelda.smc';
  const marioPath = '/roms/snes/mario.smc';
  const metroidPath = '/roms/nes/metroid.nes';
  const kirbyPath = '/roms/nes/kirby.nes';
  const contraPath = '/roms/nes/contra.nes';

  final requests = <http.Request>[];
  late Directory tmp;
  late RommService romm;
  var flushes = 0;

  /// The calls the push itself made, without the API-key verification.
  List<http.Request> calls() => requests
      .where(
        (r) => !const {'/api/heartbeat', '/api/users/me'}.contains(r.url.path),
      )
      .toList();

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM on [version] whose create answers [createStatus] with
  /// [createBody] (a created collection with id 77 by default) and whose
  /// other collection routes answer [collectionStatus].
  Future<void> serve({
    String version = '5.0.0',
    int createStatus = 201,
    String? createBody,
    int collectionStatus = 200,
    List<String>? scopes = const ['collections.write'],
  }) async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        switch (path) {
          case '/api/heartbeat':
            return json(200, {
              'SYSTEM': {'VERSION': version},
            });
          case '/api/users/me':
            return json(200, {
              'id': 1,
              'username': 'jon',
              'oauth_scopes': ?scopes,
            });
        }
        if (path == '/api/collections' && request.method == 'POST') {
          if (createBody != null) {
            return http.Response(
              createBody,
              createStatus,
              headers: const {'content-type': 'application/json'},
            );
          }
          return json(createStatus, {
            'id': 77,
            'name': MultipartBody.of(request).fields['name'],
            'rom_count': 0,
            'rom_ids': <int>[],
          });
        }
        if (path.startsWith('/api/collections/')) {
          if (request.method == 'PUT' &&
              !MultipartBody.of(request).fields.containsKey('rom_ids')) {
            return json(422, {'detail': 'rom_ids required'});
          }
          return json(collectionStatus, {'id': 77});
        }
        return http.Response('not found', 404);
      }),
    );
    await romm.authenticate();
  }

  Future<void> link(String romname, int romId, {String folder = 'snes'}) =>
      RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: folder,
        rommRomId: romId,
      );

  GameModel gameAt(String romPath) {
    final romname = romPath.split('/').last;
    return GameModel(
      romname: romname,
      realname: romname,
      name: romname,
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0.0,
      romPath: romPath,
    );
  }

  Future<CollectionModel> model(String id) async => CollectionModel.fromJson(
    (await CollectionRepository.getCollectionById(id))!,
  );

  /// An ordinary local collection holding [members].
  Future<String> local(
    String id, {
    String name = 'RPGs',
    String? imagePath,
    Iterable<String> members = const [],
  }) async {
    await CollectionRepository.insertCollection(
      id: id,
      name: name,
      imagePath: imagePath,
    );
    for (final path in members) {
      await CollectionRepository.addRomToCollection(id, path);
    }
    return id;
  }

  /// A collection linked to RomM id [rommId] with [origin].
  Future<String> linked(
    String id, {
    required String origin,
    String rommId = '30',
    Iterable<String> members = const [],
  }) async {
    await local(id, members: members);
    await CollectionRepository.setRommProvenance(
      id,
      serverUrl: server,
      collectionId: rommId,
      virtual: false,
      syncedAt: DateTime.utc(2026, 9, 8),
      origin: origin,
    );
    return id;
  }

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsIndexSql);
    await db.execute(SqliteMigrations.createAppRommCollectionOutboxTableSql);
    await db.execute('INSERT INTO user_config (id) VALUES (1)');
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('nes', 'Nintendo', 'nes')",
    );
    for (final (name, path, system) in const [
      ('zelda.smc', zeldaPath, 'snes'),
      ('mario.smc', marioPath, 'snes'),
      ('metroid.nes', metroidPath, 'nes'),
      ('kirby.nes', kirbyPath, 'nes'),
      ('contra.nes', contraPath, 'nes'),
    ]) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id) '
        "VALUES ('$name', '$path', '$system')",
      );
    }

    requests.clear();
    flushes = 0;
    CollectionsService.onRommOutboxQueued = () => flushes++;
    tmp = Directory.systemTemp.createTempSync('neostation_push_');
    SharedPreferences.setMockInitialValues({'custom_user_data_path': tmp.path});
    romm = RommService()..configure(serverUrl: server, apiKey: 'rmm_deadbeef');
  });

  tearDown(() async {
    CollectionsService.onRommOutboxQueued = null;
    RommService.debugUseHttpClient(null);
    tmp.deleteSync(recursive: true);
    await helper.tearDown();
  });

  group('pushToRomm', () {
    // Scenario: push with unlinked members — five games, three linked: the
    // RomM collection is created with three ROMs and the outcome reads
    // "3 pushed, 2 not linked".
    test(
      'creates, adds the linked members, records provenance and baseline',
      () async {
        await link('zelda.smc', 42);
        await link('mario.smc', 43);
        await link('metroid.nes', 44, folder: 'nes');
        final id = await local(
          'c1',
          name: 'Best of 16-bit',
          members: [zeldaPath, marioPath, metroidPath, kirbyPath, contraPath],
        );
        await serve(version: '5.0.0');

        final outcome = await CollectionsService.pushToRomm(id, romm);

        expect(outcome, (pushed: 3, unlinked: 2));

        final sent = calls();
        expect(sent, hasLength(2));
        expect(sent[0].method, 'POST');
        expect(sent[0].url.path, '/api/collections');
        final form = MultipartBody.of(sent[0]);
        expect(form.fields, {'name': 'Best of 16-bit'});
        expect(form.files, isEmpty);
        expect(sent[1].method, 'POST');
        expect(sent[1].url.path, '/api/collections/77/roms');
        expect(
          (jsonDecode(sent[1].body) as Map)['rom_ids'],
          unorderedEquals([42, 43, 44]),
        );

        final pushed = await model(id);
        expect(pushed.isPushedToRomm, isTrue);
        expect(pushed.isRommMirror, isTrue);
        expect(pushed.rommOrigin, CollectionModel.originLocal);
        expect(pushed.rommCollectionId, '77');
        expect(pushed.rommServerUrl, romm.baseUrl);

        final row = await RommCollectionOutboxRepository.get(id);
        expect(row, isNotNull);
        expect(row!.lastPushedRomIds, {42, 43, 44});
        expect(row.rommCollectionId, '77');
        expect(row.membersDirty, isFalse);
        expect(row.nameDirty, isFalse);
        expect(row.artworkDirty, isFalse);
        // Nothing was queued: the push itself is not an edit to flush.
        expect(flushes, 0);
      },
    );

    test('uploads the local artwork with the create', () async {
      final cover = File('${tmp.path}/cover.png')
        ..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      final id = await local('c1', imagePath: cover.path);
      await serve();

      await CollectionsService.pushToRomm(id, romm);

      final form = MultipartBody.of(calls().single);
      expect(form.files.keys, ['artwork']);
      expect(form.files['artwork']!.bytes, cover.readAsBytesSync());
    });

    test('a missing artwork file is left out rather than failing', () async {
      final id = await local('c1', imagePath: '${tmp.path}/gone.png');
      await serve();

      final outcome = await CollectionsService.pushToRomm(id, romm);

      expect(outcome, (pushed: 0, unlinked: 0));
      expect(MultipartBody.of(calls().single).files, isEmpty);
    });

    // Scenario: old server membership change — below 4.9.0 there is no
    // add/remove route, so the members go out as one PUT with rom_ids.
    test('below 4.9.0 the members are one PUT with rom_ids', () async {
      await link('zelda.smc', 42);
      final id = await local('c1', members: [zeldaPath]);
      await serve(version: '4.8.0');

      final outcome = await CollectionsService.pushToRomm(id, romm);

      expect(outcome, (pushed: 1, unlinked: 0));
      final sent = calls();
      expect(sent, hasLength(2));
      expect(sent[1].method, 'PUT');
      expect(sent[1].url.path, '/api/collections/77');
      expect(MultipartBody.of(sent[1]).fields['rom_ids'], '[42]');
      expect((await RommCollectionOutboxRepository.get(id))!.lastPushedRomIds, {
        42,
      });
    });

    test('an empty collection is created without a membership call', () async {
      final id = await local('c1');
      await serve();

      final outcome = await CollectionsService.pushToRomm(id, romm);

      expect(outcome, (pushed: 0, unlinked: 0));
      expect(calls(), hasLength(1));
      expect((await model(id)).isPushedToRomm, isTrue);
      final row = await RommCollectionOutboxRepository.get(id);
      expect(row!.lastPushedRomIds, isEmpty);
    });

    test('a collection that is already linked is not pushed', () async {
      final mirror = await linked('m1', origin: CollectionModel.originRomm);
      final pushed = await linked('p1', origin: CollectionModel.originLocal);
      await serve();

      expect(await CollectionsService.pushToRomm(mirror, romm), isNull);
      expect(await CollectionsService.pushToRomm(pushed, romm), isNull);
      expect(await CollectionsService.pushToRomm('nope', romm), isNull);
      expect(calls(), isEmpty);
      expect((await model(mirror)).rommOrigin, CollectionModel.originRomm);
    });

    test('a denied collections.write scope pushes nothing', () async {
      final id = await local('c1');
      await serve(scopes: const ['roms.read']);

      expect(await CollectionsService.pushToRomm(id, romm), isNull);
      expect(calls(), isEmpty);
      expect((await model(id)).isRommMirror, isFalse);
    });

    test('a duplicate name surfaces as alreadyExists, unlinked', () async {
      final id = await local('c1', name: 'RPGs');
      await serve(
        createStatus: 500,
        createBody: jsonEncode({'detail': 'Collection RPGs already exists'}),
      );

      await expectLater(
        CollectionsService.pushToRomm(id, romm),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.alreadyExists,
          ),
        ),
      );
      expect((await model(id)).isRommMirror, isFalse);
      expect(await RommCollectionOutboxRepository.get(id), isNull);
    });

    test(
      'a membership failure keeps the link and queues the members',
      () async {
        await link('zelda.smc', 42);
        final id = await local('c1', members: [zeldaPath]);
        await serve(collectionStatus: 503);

        await expectLater(
          CollectionsService.pushToRomm(id, romm),
          throwsA(
            isA<RommException>().having((e) => e.statusCode, 'status', 503),
          ),
        );

        // Created and linked: the next push would only answer "already
        // exists", so the members wait for the flush instead.
        expect((await model(id)).isPushedToRomm, isTrue);
        final row = await RommCollectionOutboxRepository.get(id);
        expect(row!.membersDirty, isTrue);
        expect(row.lastPushedRomIds, isNull);
        expect(flushes, 1);
      },
    );
  });

  group('edit hooks', () {
    Future<RommCollectionOutboxRow?> row(String id) =>
        RommCollectionOutboxRepository.get(id);

    test('a pushed collection queues each edit and asks for a flush', () async {
      final id = await linked(
        'p1',
        origin: CollectionModel.originLocal,
        members: [zeldaPath],
      );

      await CollectionsService.addGame(id, gameAt(marioPath));
      expect((await row(id))!.membersDirty, isTrue);
      expect(flushes, 1);

      await RommCollectionOutboxRepository.clearDirty(id, members: true);
      await CollectionsService.removeGame(id, gameAt(marioPath));
      expect((await row(id))!.membersDirty, isTrue);
      expect(flushes, 2);

      await RommCollectionOutboxRepository.clearDirty(id, members: true);
      expect(
        await CollectionsService.toggleGame(id, gameAt(metroidPath)),
        true,
      );
      expect((await row(id))!.membersDirty, isTrue);
      expect(flushes, 3);

      await CollectionsService.renameCollection(id, 'JRPGs');
      expect((await row(id))!.nameDirty, isTrue);
      expect((await model(id)).name, 'JRPGs');
      expect(flushes, 4);

      final picked = File('${tmp.path}/picked.png')
        ..writeAsBytesSync(const [1, 2, 3]);
      final target = await CollectionsService.setCollectionImage(
        id,
        picked.path,
      );
      expect(target, isNotNull);
      expect((await row(id))!.artworkDirty, isTrue);
      expect(flushes, 5);

      await RommCollectionOutboxRepository.clearDirty(id, artwork: true);
      await CollectionsService.clearCollectionImage(id);
      expect((await row(id))!.artworkDirty, isTrue);
      expect((await model(id)).imagePath, isNull);
      expect(flushes, 6);
    });

    test('a mirror and an ordinary collection queue nothing', () async {
      final mirror = await linked('m1', origin: CollectionModel.originRomm);
      final plain = await local('c1');

      for (final id in [mirror, plain]) {
        await CollectionsService.addGame(id, gameAt(zeldaPath));
        await CollectionsService.toggleGame(id, gameAt(marioPath));
        await CollectionsService.removeGame(id, gameAt(zeldaPath));
        await CollectionsService.renameCollection(id, 'Renamed');
        await CollectionsService.clearCollectionImage(id);
        expect(await row(id), isNull, reason: id);
      }
      // The local edits landed all the same.
      expect((await model(mirror)).name, 'Renamed');
      expect((await model(plain)).gameCount, 1);
      expect(flushes, 0);
    });

    test('a failing flush trigger never fails the edit', () async {
      final id = await linked('p1', origin: CollectionModel.originLocal);
      CollectionsService.onRommOutboxQueued = () => throw StateError('boom');
      await CollectionsService.addGame(id, gameAt(zeldaPath));
      expect((await model(id)).gameCount, 1);
      expect((await row(id))!.membersDirty, isTrue);
    });
  });

  group('deleteCollection', () {
    test(
      'deleting on RomM too queues the remote delete before the local row goes',
      () async {
        final id = await linked(
          'p1',
          origin: CollectionModel.originLocal,
          rommId: '30',
          members: [zeldaPath],
        );

        await CollectionsService.deleteCollection(id, deleteOnRomm: true);

        expect(await CollectionRepository.getCollectionById(id), isNull);
        final row = await RommCollectionOutboxRepository.get(id);
        expect(row, isNotNull);
        expect(row!.deleteRemote, isTrue);
        // The target survives the local delete on the row itself.
        expect(row.rommCollectionId, '30');
        expect(row.rommServerUrl, server);
        expect(flushes, 1);
      },
    );

    // Scenario: keep on server — the user declines: the local collection is
    // deleted and nothing is sent, not even what was queued before.
    test('declining deletes locally and sends nothing', () async {
      final id = await linked('p1', origin: CollectionModel.originLocal);
      await CollectionsService.renameCollection(id, 'Renamed');
      expect(await RommCollectionOutboxRepository.get(id), isNotNull);
      flushes = 0;

      await CollectionsService.deleteCollection(id);

      expect(await CollectionRepository.getCollectionById(id), isNull);
      expect(await RommCollectionOutboxRepository.get(id), isNull);
      expect(flushes, 0);
    });

    test('a mirror never deletes on RomM, whatever the flag says', () async {
      final id = await linked('m1', origin: CollectionModel.originRomm);

      await CollectionsService.deleteCollection(id, deleteOnRomm: true);

      expect(await CollectionRepository.getCollectionById(id), isNull);
      expect(await RommCollectionOutboxRepository.get(id), isNull);
      expect(flushes, 0);
    });

    test('an ordinary collection is just deleted', () async {
      final id = await local('c1');

      await CollectionsService.deleteCollection(id, deleteOnRomm: true);

      expect(await CollectionRepository.getCollectionById(id), isNull);
      expect(await RommCollectionOutboxRepository.get(id), isNull);
      expect(flushes, 0);
    });
  });

  group('unlinkFromRomm', () {
    // Scenario: unlink pushed — it becomes an ordinary local collection and
    // edits no longer queue.
    test('a pushed collection loses origin and its queue', () async {
      final id = await linked('p1', origin: CollectionModel.originLocal);
      await CollectionsService.renameCollection(id, 'Renamed');
      expect(await RommCollectionOutboxRepository.get(id), isNotNull);

      await CollectionsService.unlinkFromRomm(id);

      final unlinked = await model(id);
      expect(unlinked.isRommMirror, isFalse);
      expect(unlinked.isPushedToRomm, isFalse);
      expect(unlinked.rommOrigin, isNull);
      expect(unlinked.name, 'Renamed');
      expect(await RommCollectionOutboxRepository.get(id), isNull);

      flushes = 0;
      await CollectionsService.addGame(id, gameAt(zeldaPath));
      expect(await RommCollectionOutboxRepository.get(id), isNull);
      expect(flushes, 0);
    });

    test('a mirror loses its origin too', () async {
      final id = await linked('m1', origin: CollectionModel.originRomm);
      await CollectionsService.unlinkFromRomm(id);
      final unlinked = await model(id);
      expect(unlinked.isRommMirror, isFalse);
      expect(unlinked.rommOrigin, isNull);
    });
  });
}
