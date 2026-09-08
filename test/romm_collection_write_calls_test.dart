import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm_service.dart';

import 'multipart_test_helper.dart';

/// The five collection write calls behind ADR-0015: exact multipart and JSON
/// shapes, the below-4.9.0 full-replace fallback, the scope gate that must
/// produce no request at all, and the duplicate-name 500.
///
/// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Collection Write
/// Calls", REQ "Error Handling Standards"
void main() {
  // MockClient hands the handler a plain http.Request even for a multipart
  // send, so the recorded shape is the same for every call here.
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM on [version] whose collection routes answer [collectionStatus]
  /// (create answers [createStatus]) and whose `GET /api/collections/{id}`
  /// reports [currentRomIds] as members.
  void serve({
    String version = '5.0.0',
    int collectionStatus = 200,
    int createStatus = 201,
    List<int> currentRomIds = const [],
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/api/heartbeat') {
          return json(200, {
            'SYSTEM': {'VERSION': version},
          });
        }
        if (path == '/api/token') {
          return json(200, {'access_token': 'tok', 'expires': 3600});
        }
        if (path == '/api/users/me') return json(200, {'username': 'jon'});
        if (path == '/api/collections' && request.method == 'POST') {
          return json(createStatus, {
            'id': 77,
            'name': 'RPGs',
            'rom_count': 0,
            'rom_ids': <int>[],
          });
        }
        if (path.startsWith('/api/collections/')) {
          if (request.method == 'GET' && !path.endsWith('/roms')) {
            return json(200, {
              'id': 77,
              'name': 'RPGs',
              'rom_ids': currentRomIds,
            });
          }
          return http.Response('', collectionStatus);
        }
        return http.Response('not found', 404);
      }),
    );
  }

  Future<RommService> connected({
    String version = '5.0.0',
    int collectionStatus = 200,
    int createStatus = 201,
    List<int> currentRomIds = const [],
  }) async {
    serve(
      version: version,
      collectionStatus: collectionStatus,
      createStatus: createStatus,
      currentRomIds: currentRomIds,
    );
    final service = RommService()
      ..configure(
        serverUrl: 'https://romm.local',
        username: 'jon',
        password: 's3cret',
      );
    await service.authenticate();
    requests.clear();
    return service;
  }

  /// A service whose login was refused the `collections.write` group, so it
  /// settles as denied before any call is made.
  Future<RommService> deniedCollectionsWrite() async {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/heartbeat') {
          return json(200, {
            'SYSTEM': {'VERSION': '5.0.0'},
          });
        }
        if (request.url.path == '/api/token') {
          return request.bodyFields['scope']!.contains('collections.write')
              ? http.Response('forbidden', 403)
              : json(200, {'access_token': 'tok', 'expires': 3600});
        }
        return http.Response('not found', 404);
      }),
    );
    final service = RommService()
      ..configure(
        serverUrl: 'https://romm.local',
        username: 'jon',
        password: 's3cret',
      );
    await service.authenticate();
    requests.clear();
    expect(
      service.hasScope(RommScopeGroup.collectionsWrite),
      RommScopeState.denied,
    );
    return service;
  }

  late Directory tmp;
  late File artwork;

  setUp(() {
    requests.clear();
    tmp = Directory.systemTemp.createTempSync('neostation_collection_');
    artwork = File('${tmp.path}/cover.png')
      ..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
  });

  tearDown(() {
    RommService.debugUseHttpClient(null);
    tmp.deleteSync(recursive: true);
  });

  group('createCollection', () {
    test('sends a multipart POST with the name and returns the id', () async {
      final service = await connected();

      final created = await service.createCollection('  RPGs ');

      expect(created?.id, '77');
      expect(created?.name, 'RPGs');
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/collections');
      expect(request.url.queryParameters, isEmpty);
      final form = MultipartBody.of(request);
      expect(form.fields, {'name': 'RPGs'});
      expect(form.files, isEmpty);
    });

    test('attaches the artwork file under the artwork field', () async {
      final service = await connected();

      await service.createCollection('RPGs', artworkPath: artwork.path);

      final form = MultipartBody.of(requests.single);
      expect(form.fields, {'name': 'RPGs'});
      expect(form.files.keys, ['artwork']);
      expect(form.files['artwork']!.filename, 'cover.png');
      expect(form.files['artwork']!.bytes, artwork.readAsBytesSync());
    });

    test('a missing artwork file is refused before any request', () async {
      final service = await connected();
      await expectLater(
        service.createCollection('RPGs', artworkPath: '${tmp.path}/none.png'),
        throwsArgumentError,
      );
      expect(requests, isEmpty);
    });

    test('a blank name is refused before any request', () async {
      final service = await connected();
      await expectLater(service.createCollection('   '), throwsArgumentError);
      expect(requests, isEmpty);
    });

    test('a 500 is the duplicate-name kind, with the name in it', () async {
      final service = await connected(createStatus: 500);

      await expectLater(
        service.createCollection('RPGs'),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.alreadyExists)
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('name="RPGs"')),
        ),
      );
    });

    test('a denied scope stops it without a request', () async {
      final service = await deniedCollectionsWrite();

      expect(await service.createCollection('RPGs'), isNull);
      expect(requests, isEmpty);
    });

    test('a 403 settles the scope group as denied', () async {
      final service = await connected(createStatus: 403);

      await expectLater(
        service.createCollection('RPGs'),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.scopeDenied,
          ),
        ),
      );
      expect(
        service.hasScope(RommScopeGroup.collectionsWrite),
        RommScopeState.denied,
      );
      // The re-auth retry sends the create twice (403 → authenticate → retry).
      requests.clear();
      expect(await service.createCollection('Again'), isNull);
      expect(requests, isEmpty, reason: 'gated from now on');
    });
  });

  group('updateCollection', () {
    test('a rename is one multipart PUT carrying only the name', () async {
      final service = await connected();

      expect(await service.updateCollection(77, name: 'JRPGs'), isTrue);

      final request = requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/api/collections/77');
      expect(request.url.queryParameters, isEmpty);
      final form = MultipartBody.of(request);
      expect(form.fields, {'name': 'JRPGs'});
      expect(form.files, isEmpty);
    });

    test('rom_ids goes out as a sorted JSON array string', () async {
      final service = await connected();

      await service.updateCollection(77, romIds: [30, 10, 20, 10]);

      final form = MultipartBody.of(requests.single);
      expect(form.fields, {'rom_ids': '[10,20,30]'});
    });

    test('an empty set replaces the membership with nothing', () async {
      final service = await connected();

      await service.updateCollection(77, romIds: const <int>[]);

      expect(MultipartBody.of(requests.single).fields, {'rom_ids': '[]'});
    });

    test('artwork is the file part, nothing else', () async {
      final service = await connected();

      await service.updateCollection(77, artworkPath: artwork.path);

      final form = MultipartBody.of(requests.single);
      expect(form.fields, isEmpty);
      expect(form.files.keys, ['artwork']);
      expect(form.files['artwork']!.bytes, artwork.readAsBytesSync());
    });

    test('removeArtwork is the remove_cover query flag', () async {
      final service = await connected();

      await service.updateCollection(77, removeArtwork: true);

      final request = requests.single;
      expect(request.method, 'PUT');
      expect(request.url.queryParameters, {'remove_cover': 'true'});
      expect(MultipartBody.of(request).fields, isEmpty);
    });

    test('nothing to send means no request', () async {
      final service = await connected();
      expect(await service.updateCollection(77), isFalse);
      expect(requests, isEmpty);
    });

    test('a denied scope stops it without a request', () async {
      final service = await deniedCollectionsWrite();
      expect(await service.updateCollection(77, name: 'x'), isFalse);
      expect(requests, isEmpty);
    });

    test('a 404 throws with the collection id and status', () async {
      final service = await connected(collectionStatus: 404);
      await expectLater(
        service.updateCollection(77, name: 'x'),
        throwsA(
          isA<RommException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('collection=77')),
        ),
      );
    });
  });

  group('addCollectionRoms / removeCollectionRoms', () {
    test('add is a JSON POST to /roms', () async {
      final service = await connected();

      expect(await service.addCollectionRoms(77, [5, 3, 5]), isTrue);

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/collections/77/roms');
      expect(request.headers['Content-Type'], 'application/json');
      expect(jsonDecode(request.body), {
        'rom_ids': [3, 5],
      });
    });

    test('remove is a JSON DELETE to /roms', () async {
      final service = await connected();

      expect(await service.removeCollectionRoms(77, [9]), isTrue);

      final request = requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/collections/77/roms');
      expect(jsonDecode(request.body), {
        'rom_ids': [9],
      });
    });

    test('an empty set is confirmed without a request', () async {
      final service = await connected();
      expect(await service.addCollectionRoms(77, const []), isTrue);
      expect(await service.removeCollectionRoms(77, const []), isTrue);
      expect(requests, isEmpty);
    });

    // Scenario: old server membership change.
    test('a 4.8.0 server gets one PUT with the full rom_ids on add', () async {
      final service = await connected(version: '4.8.0', currentRomIds: [1, 2]);
      expect(
        service.supports(RommFeature.collectionRomsAddRemove),
        RommFeatureSupport.unsupported,
      );

      expect(await service.addCollectionRoms(77, [3]), isTrue);

      final read = requests.first;
      expect(read.method, 'GET');
      expect(read.url.path, '/api/collections/77');
      final puts = requests.where((r) => r.method == 'PUT').toList();
      expect(puts, hasLength(1));
      expect(puts.single.url.path, '/api/collections/77');
      expect(MultipartBody.of(puts.single).fields, {'rom_ids': '[1,2,3]'});
      expect(requests.where((r) => r.url.path.endsWith('/roms')), isEmpty);
    });

    test('a 4.8.0 server gets one PUT with the difference on remove', () async {
      final service = await connected(
        version: '4.8.0',
        currentRomIds: [1, 2, 3],
      );

      expect(await service.removeCollectionRoms(77, [2]), isTrue);

      final puts = requests.where((r) => r.method == 'PUT').toList();
      expect(puts, hasLength(1));
      expect(MultipartBody.of(puts.single).fields, {'rom_ids': '[1,3]'});
    });

    test('a denied scope stops both without a request', () async {
      final service = await deniedCollectionsWrite();
      expect(await service.addCollectionRoms(77, [1]), isFalse);
      expect(await service.removeCollectionRoms(77, [1]), isFalse);
      expect(requests, isEmpty);
    });

    test('a failure names the collection, the count and the status', () async {
      final service = await connected(collectionStatus: 500);
      await expectLater(
        service.addCollectionRoms(77, [1, 2]),
        throwsA(
          isA<RommException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('collection=77'))
              .having((e) => e.message, 'message', contains('roms=2')),
        ),
      );
    });
  });

  group('deleteCollection', () {
    test('is a DELETE on the collection', () async {
      final service = await connected();

      expect(await service.deleteCollection(77), isTrue);

      final request = requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/collections/77');
    });

    test('an already-gone collection counts as deleted', () async {
      final service = await connected(collectionStatus: 404);
      expect(await service.deleteCollection(77), isTrue);
    });

    test('a denied scope stops it without a request', () async {
      final service = await deniedCollectionsWrite();
      expect(await service.deleteCollection(77), isFalse);
      expect(requests, isEmpty);
    });

    test('a server error throws with the id and status', () async {
      final service = await connected(collectionStatus: 500);
      await expectLater(
        service.deleteCollection(77),
        throwsA(
          isA<RommException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('collection=77')),
        ),
      );
    });
  });

  group('getCollection', () {
    test('reads the rom_ids back', () async {
      final service = await connected(currentRomIds: [4, 5]);
      final collection = await service.getCollection(77);
      expect(collection.id, '77');
      expect(collection.romIds, [4, 5]);
    });
  });
}
