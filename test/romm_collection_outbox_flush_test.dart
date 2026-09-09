import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/collection_repository.dart';
import 'package:neostation/repositories/romm_collection_outbox_repository.dart';
import 'package:neostation/repositories/romm_props_outbox_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/romm/romm_collection_outbox_service.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';
import 'multipart_test_helper.dart';

/// The collection outbox flush through a scripted RomM: one PUT per dirty
/// collection that always carries `rom_ids` (the scripted server answers
/// 422 without it, as RomM does on every version) — the resolved members
/// when they are dirty, the last pushed baseline otherwise — an add/remove
/// diff on 4.9.0+ for a members-only change with a baseline and a full
/// replace below it, artwork upload or removal, remote delete, the 404 that
/// unlinks, the failures that keep rows, the disconnect that stops the run
/// — and the provider running it after the play-state flush.
///
/// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Follow-Up
/// Pushes", REQ "Delete", REQ "Error Handling Standards"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  const server = 'https://romm.local';
  const zeldaPath = '/roms/snes/zelda.smc';
  const marioPath = '/roms/snes/mario.smc';
  const metroidPath = '/roms/nes/metroid.nes';

  final requests = <http.Request>[];
  late _FakeBrowse browse;
  late Directory tmp;

  /// The calls the flush itself made. An API-key connection verifies itself
  /// once (heartbeat plus `GET /api/users/me`) before its first
  /// authenticated call; those are not what these tests are about.
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

  /// A RomM that answers with [respond] for everything but the API-key
  /// verification, which runs right away — the provider only flushes on a
  /// connection it has already verified, so the version and scopes are
  /// known before the first row, as they are in production. With no
  /// [version] the heartbeat is a 404, so every capability is `unknown`
  /// (the flush then replaces membership in full); with one, 4.9.0+ answers
  /// the add/remove route. [scopes] is what `/api/users/me` reports the key
  /// holds; null leaves every group unknown.
  ///
  /// Whatever [respond] would say, a `PUT /api/collections/{id}` without
  /// `rom_ids` is a 422: RomM declares the field required on every
  /// version, so a rename or artwork push that leaves it out never lands.
  Future<void> serve(
    Future<http.Response> Function(http.Request) respond, {
    String? version,
    List<String>? scopes,
  }) async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return version == null
                ? http.Response('not found', 404)
                : json(200, {
                    'SYSTEM': {'VERSION': version},
                  });
          case '/api/users/me':
            return json(200, {
              'id': 1,
              'username': 'jon',
              'oauth_scopes': ?scopes,
            });
          default:
            if (request.method == 'PUT' &&
                RegExp(r'^/api/collections/\d+$').hasMatch(request.url.path) &&
                !MultipartBody.of(request).fields.containsKey('rom_ids')) {
              return json(422, {
                'detail': [
                  {
                    'loc': ['body', 'rom_ids'],
                    'msg': 'field required',
                    'type': 'value_error.missing',
                  },
                ],
              });
            }
            return await respond(request);
        }
      }),
    );
    await browse.service.authenticate();
  }

  /// A server that accepts every collection write.
  Future<http.Response> happyServer(http.Request request) async {
    final path = request.url.path;
    if (path.startsWith('/api/collections/')) return json(200, {'id': 30});
    if (path.startsWith('/api/roms/') && path.endsWith('/props')) {
      return json(200, {'hidden': true});
    }
    return http.Response('not found', 404);
  }

  Future<void> link(String romname, int romId, {String folder = 'snes'}) =>
      RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: folder,
        rommRomId: romId,
      );

  /// A pushed (`local`-origin) collection linked to RomM id [rommId].
  Future<void> pushed(
    String id, {
    String name = 'RPGs',
    String rommId = '30',
    String? imagePath,
    Iterable<String> members = const [],
  }) async {
    await CollectionRepository.insertCollection(
      id: id,
      name: name,
      imagePath: imagePath,
    );
    await CollectionRepository.setRommProvenance(
      id,
      serverUrl: server,
      collectionId: rommId,
      virtual: false,
      syncedAt: DateTime.utc(2026, 9, 8),
      origin: CollectionModel.originLocal,
    );
    for (final path in members) {
      await CollectionRepository.addRomToCollection(id, path);
    }
  }

  Future<CollectionModel> model(String id) async => CollectionModel.fromJson(
    (await CollectionRepository.getCollectionById(id))!,
  );

  Future<RommCollectionFlushSummary> flush() =>
      RommCollectionOutboxService.flush(
        browse.service,
        isConnected: () => browse.connected,
      );

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);
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
    ]) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id) '
        "VALUES ('$name', '$path', '$system')",
      );
    }

    requests.clear();
    tmp = Directory.systemTemp.createTempSync('neostation_flush_');
    final service = RommService()
      ..configure(serverUrl: server, apiKey: 'rmm_deadbeef');
    browse = _FakeBrowse(service);
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    browse.dispose();
    tmp.deleteSync(recursive: true);
    await helper.tearDown();
  });

  group('one PUT per collection, rom_ids on every one', () {
    // Scenario: offline edits — two games added and a rename while
    // disconnected — are one PUT carrying the name and the resolved
    // members, even on a server with the add/remove route.
    test('a rename and two added members are one PUT', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', name: 'JRPGs', members: [zeldaPath, marioPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', members: true);
      await RommCollectionOutboxService.queue('c1', members: true);
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer, version: '5.0.0');

      final summary = await flush();

      expect(summary, (pushed: 1, dropped: 0, kept: 0));
      final put = calls().single;
      expect(put.method, 'PUT');
      expect(put.url.path, '/api/collections/30');
      expect(MultipartBody.of(put).fields, {
        'name': 'JRPGs',
        'rom_ids': '[42,43]',
      });
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42, 43}, reason: 'the new baseline');
    });

    // Scenario: rename only — the PUT repeats what the server holds, not
    // what the library holds, so a RomM-side membership edit is not what
    // the rename overwrites (and the members are not re-resolved).
    test('a rename alone carries the last pushed baseline', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', name: 'JRPGs', members: [zeldaPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42, 43],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer, version: '5.0.0');

      final summary = await flush();

      expect(summary, (pushed: 1, dropped: 0, kept: 0));
      final put = calls().single;
      expect(put.method, 'PUT');
      expect(MultipartBody.of(put).fields, {
        'name': 'JRPGs',
        'rom_ids': '[42,43]',
      });
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42, 43}, reason: 'baseline unchanged');
    });

    test('an artwork change alone carries the last pushed baseline', () async {
      final image = File('${tmp.path}/c1.png')..writeAsBytesSync(const [7]);
      await link('zelda.smc', 42);
      await pushed('c1', imagePath: image.path, members: [zeldaPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42, 43],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', artwork: true);
      await serve(happyServer, version: '5.0.0');

      await flush();

      final put = calls().single;
      expect(put.method, 'PUT');
      final form = MultipartBody.of(put);
      expect(form.fields, {'rom_ids': '[42,43]'});
      expect(form.files.keys, ['artwork']);
      expect(form.files['artwork']!.bytes, [7]);
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
    });

    test('a rename with no baseline carries the resolved members', () async {
      await link('zelda.smc', 42);
      await pushed('c1', name: 'JRPGs', members: [zeldaPath, marioPath]);
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer, version: '5.0.0');

      await flush();

      expect(MultipartBody.of(calls().single).fields, {
        'name': 'JRPGs',
        'rom_ids': '[42]',
      });
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42}, reason: 'seeded by the PUT');
    });

    test('removed members go out as one DELETE against the baseline', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', members: [zeldaPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42, 43],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(happyServer, version: '5.0.0');

      await flush();

      final sent = calls();
      expect(sent, hasLength(1));
      expect(sent.single.method, 'DELETE');
      expect(sent.single.url.path, '/api/collections/30/roms');
      expect(jsonDecode(sent.single.body), {
        'rom_ids': [43],
      });
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42});
    });

    test('an add and a remove in one edit are two diff calls', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', members: [marioPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(happyServer, version: '5.0.0');

      await flush();

      expect(calls().map((r) => r.method), ['POST', 'DELETE']);
      expect(jsonDecode(calls()[0].body), {
        'rom_ids': [43],
      });
      expect(jsonDecode(calls()[1].body), {
        'rom_ids': [42],
      });
    });

    test('no baseline means one full rom_ids replace, even on 5.0.0', () async {
      await link('zelda.smc', 42);
      await pushed('c1', members: [zeldaPath]);
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(happyServer, version: '5.0.0');

      await flush();

      final put = calls().single;
      expect(put.method, 'PUT');
      expect(put.url.path, '/api/collections/30');
      expect(MultipartBody.of(put).fields, {'rom_ids': '[42]'});
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42});
    });

    test('a 4.8.0 server gets one full replace despite a baseline', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', members: [zeldaPath, marioPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(happyServer, version: '4.8.0');

      await flush();

      final put = calls().single;
      expect(put.method, 'PUT');
      expect(MultipartBody.of(put).fields, {'rom_ids': '[42,43]'});
      expect(calls().where((r) => r.url.path.endsWith('/roms')), isEmpty);
    });

    test('unlinked members are counted, not pushed', () async {
      await link('zelda.smc', 42);
      await pushed('c1', members: [zeldaPath, marioPath, metroidPath]);
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(happyServer);

      final resolved = await RommCollectionOutboxService.resolveMemberRomIds(
        'c1',
      );
      expect(resolved.romIds, {42});
      expect(resolved.unlinked, 2);

      await flush();

      expect(MultipartBody.of(calls().single).fields, {'rom_ids': '[42]'});
    });

    test('a changed artwork file is one PUT with the artwork part', () async {
      final image = File('${tmp.path}/c1.png')
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      await pushed('c1', imagePath: image.path);
      await RommCollectionOutboxService.queue('c1', artwork: true);
      await serve(happyServer);

      await flush();

      final put = calls().single;
      expect(put.method, 'PUT');
      expect(put.url.path, '/api/collections/30');
      expect(put.url.queryParameters, isEmpty);
      final form = MultipartBody.of(put);
      expect(form.fields, {'rom_ids': '[]'}, reason: 'no members, no baseline');
      expect(form.files['artwork']!.filename, 'c1.png');
      expect(form.files['artwork']!.bytes, [1, 2, 3, 4]);
    });

    test('a cleared artwork is one PUT with remove_cover', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', artwork: true);
      await serve(happyServer);

      await flush();

      final put = calls().single;
      expect(put.method, 'PUT');
      expect(put.url.queryParameters, {'remove_cover': 'true'});
      final form = MultipartBody.of(put);
      expect(form.fields, {'rom_ids': '[]'});
      expect(form.files, isEmpty);
    });

    test('everything dirty is one PUT carrying all of it', () async {
      final image = File('${tmp.path}/c1.png')..writeAsBytesSync(const [9]);
      await link('zelda.smc', 42);
      await pushed('c1', imagePath: image.path, members: [zeldaPath]);
      await RommCollectionOutboxService.queue(
        'c1',
        name: true,
        artwork: true,
        members: true,
      );
      await serve(happyServer);

      final summary = await flush();

      expect(summary.pushed, 1);
      final put = calls().single;
      expect(put.method, 'PUT');
      final form = MultipartBody.of(put);
      expect(form.fields, {'name': 'RPGs', 'rom_ids': '[42]'});
      expect(form.files.keys, ['artwork']);
      expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      final row = (await RommCollectionOutboxRepository.get('c1'))!;
      expect(row.lastPushedRomIds, {42});
    });

    test('an edit made during the push stays queued', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve((request) async {
        // The user renames again while the PUT is in flight.
        await Future<void>.delayed(const Duration(milliseconds: 2));
        await RommCollectionOutboxService.queue('c1', name: true);
        return json(200, {'id': 30});
      });

      await flush();

      expect(await RommCollectionOutboxRepository.pendingCount(), 1);
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.nameDirty, isTrue);
    });
  });

  group('delete', () {
    test('delete_remote sends one DELETE and drops the row', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', deleteRemote: true);
      await CollectionRepository.deleteCollection('c1');
      await serve(happyServer);

      final summary = await flush();

      expect(summary.pushed, 1);
      final sent = calls().single;
      expect(sent.method, 'DELETE');
      expect(sent.url.path, '/api/collections/30');
      expect(await RommCollectionOutboxRepository.get('c1'), isNull);
    });

    test('a delete for a collection still local unlinks it', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', deleteRemote: true);
      await serve(happyServer);

      await flush();

      final c = await model('c1');
      expect(c.rommCollectionId, isNull);
      expect(c.rommOrigin, isNull);
    });

    test('a delete the server already did counts as done', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', deleteRemote: true);
      await CollectionRepository.deleteCollection('c1');
      await serve((_) async => http.Response('gone', 404));

      final summary = await flush();

      expect(summary.pushed, 1);
      expect(await RommCollectionOutboxRepository.get('c1'), isNull);
    });
  });

  group('rows that cannot succeed', () {
    // Scenario: deleted on server — provenance and origin cleared, row
    // dropped.
    test('a 404 unlinks the collection and drops the row', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve((_) async => http.Response('gone', 404));

      final summary = await flush();

      expect(summary, (pushed: 0, dropped: 1, kept: 0));
      final c = await model('c1');
      expect(c.rommCollectionId, isNull);
      expect(c.rommServerUrl, isNull);
      expect(c.rommOrigin, isNull);
      expect(c.isPushedToRomm, isFalse);
      expect(c.name, 'RPGs', reason: 'the local collection survives');
      expect(await RommCollectionOutboxRepository.get('c1'), isNull);
    });

    test('a row for a collection that is gone is dropped, unsent', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await CollectionRepository.deleteCollection('c1');
      await serve(happyServer);

      final summary = await flush();

      expect(summary.dropped, 1);
      expect(calls(), isEmpty);
      expect(await RommCollectionOutboxRepository.get('c1'), isNull);
    });

    test(
      'a row for a collection unlinked meanwhile is dropped, unsent',
      () async {
        await pushed('c1');
        await RommCollectionOutboxService.queue('c1', name: true);
        await CollectionRepository.clearRommProvenance('c1');
        await serve(happyServer);

        final summary = await flush();

        expect(summary.dropped, 1);
        expect(calls(), isEmpty);
      },
    );

    // Scenario: romm-origin collections MUST NOT be pushed, even from a row
    // written before the mirror adopted the collection.
    test('a row whose collection became a mirror is dropped, unsent', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', members: true);
      await CollectionRepository.setRommOrigin(
        'c1',
        CollectionModel.originRomm,
      );
      await serve(happyServer);

      final summary = await flush();

      expect(summary.dropped, 1);
      expect(calls(), isEmpty);
    });

    test('a row for another server is kept untouched', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await db.execute(
        "UPDATE app_romm_collection_outbox SET romm_server_url = "
        "'https://other.local' WHERE collection_id = 'c1'",
      );
      await serve(happyServer);

      final summary = await flush();

      expect(summary.kept, 1);
      expect(calls(), isEmpty);
      expect(await RommCollectionOutboxRepository.pendingCount(), 1);
    });
  });

  group('failures keep rows', () {
    test('a server error keeps that row and moves on to the next', () async {
      await pushed('c1', rommId: '30');
      await pushed('c2', rommId: '31');
      await RommCollectionOutboxService.queue('c1', name: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await RommCollectionOutboxService.queue('c2', name: true);
      await serve(
        (request) async => request.url.path == '/api/collections/30'
            ? http.Response('boom', 500)
            : json(200, {'id': 31}),
      );

      final summary = await flush();

      expect(summary, (pushed: 1, dropped: 0, kept: 1));
      expect(calls().map((r) => r.url.path), [
        '/api/collections/30',
        '/api/collections/31',
      ]);
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.collectionId, 'c1');
      expect(row.nameDirty, isTrue);
    });

    test('a socket error keeps every row and stops the flush', () async {
      await pushed('c1', rommId: '30');
      await pushed('c2', rommId: '31');
      await RommCollectionOutboxService.queue('c1', name: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await RommCollectionOutboxService.queue('c2', name: true);
      await serve((_) async => throw const SocketException('down'));

      final summary = await flush();

      expect(summary, (pushed: 0, dropped: 0, kept: 2));
      expect(calls(), hasLength(1), reason: 'stopped after the first');
      expect(await RommCollectionOutboxRepository.pendingCount(), 2);
    });

    test('a denied scope keeps the row without a request', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer, scopes: ['roms.read']);

      final summary = await flush();

      expect(summary.kept, 1);
      expect(calls(), isEmpty);
      expect(await RommCollectionOutboxRepository.pendingCount(), 1);
    });

    test('a failed PUT keeps every aspect it carried', () async {
      await link('zelda.smc', 42);
      await pushed('c1', members: [zeldaPath]);
      await RommCollectionOutboxService.queue('c1', name: true, members: true);
      await serve((_) async => http.Response('boom', 500));

      final summary = await flush();

      expect(summary.kept, 1);
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.nameDirty, isTrue);
      expect(row.membersDirty, isTrue);
      expect(row.lastPushedRomIds, isNull, reason: 'nothing landed');
    });

    test('a diff whose remove fails keeps the members dirty', () async {
      await link('zelda.smc', 42);
      await link('mario.smc', 43);
      await pushed('c1', members: [marioPath]);
      await RommCollectionOutboxRepository.recordPushedRomIds(
        'c1',
        const [42],
        rommServerUrl: server,
        rommCollectionId: '30',
      );
      await RommCollectionOutboxService.queue('c1', members: true);
      await serve(
        (request) async => request.method == 'DELETE'
            ? http.Response('boom', 500)
            : json(200, {'id': 30}),
        version: '5.0.0',
      );

      final summary = await flush();

      expect(summary.kept, 1);
      expect(calls().map((r) => r.method), ['POST', 'DELETE']);
      final row = (await RommCollectionOutboxRepository.listDirty()).single;
      expect(row.membersDirty, isTrue);
      expect(row.lastPushedRomIds, {42}, reason: 'baseline until confirmed');
    });
  });

  group('connection', () {
    test('a disconnect between rows stops the flush', () async {
      await pushed('c1', rommId: '30');
      await pushed('c2', rommId: '31');
      await RommCollectionOutboxService.queue('c1', name: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await RommCollectionOutboxService.queue('c2', name: true);
      await serve((request) async {
        browse.connected = false;
        return json(200, {'id': 30});
      });

      final summary = await flush();

      expect(summary, (pushed: 1, dropped: 0, kept: 1));
      expect(calls(), hasLength(1));
    });

    test('nothing is sent while disconnected', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer);
      browse.connected = false;

      final summary = await browse.flushCollectionOutbox();

      expect(summary, (pushed: 0, dropped: 0, kept: 0));
      expect(calls(), isEmpty);
      expect(await RommCollectionOutboxRepository.pendingCount(), 1);
    });

    test('nothing pending sends nothing', () async {
      await serve(happyServer);
      expect(await flush(), (pushed: 0, dropped: 0, kept: 0));
      expect(calls(), isEmpty);
    });
  });

  group('RommProvider', () {
    test('overlapping flushes share one run', () async {
      await pushed('c1');
      await RommCollectionOutboxService.queue('c1', name: true);
      await serve(happyServer);

      final results = await Future.wait([
        browse.flushCollectionOutbox(),
        browse.flushCollectionOutbox(),
      ]);

      expect(results[0], results[1]);
      expect(calls(), hasLength(1), reason: 'one PUT, not two');
    });

    // The provider's outbox order: play state before collections.
    test(
      'flushOutboxes runs the collection flush after the props flush',
      () async {
        await link('zelda.smc', 42);
        await RommPropsOutboxRepository.upsert(
          romPath: zeldaPath,
          hidden: true,
        );
        await pushed('c1');
        await RommCollectionOutboxService.queue('c1', name: true);
        await serve(happyServer);

        await browse.flushOutboxes();

        final paths = calls().map((r) => r.url.path).toList();
        expect(paths, ['/api/roms/42/props', '/api/collections/30']);
        expect(await RommPropsOutboxRepository.pendingCount(), 0);
        expect(await RommCollectionOutboxRepository.pendingCount(), 0);
      },
    );
  });
}

/// A provider whose connection state and service the test controls.
class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}
