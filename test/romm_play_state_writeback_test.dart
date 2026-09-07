import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/services/romm_service.dart';

/// The two write calls behind ADR-0013: the props update and the favourites
/// collection. Exact bodies, exact query flags, and the version/scope gates
/// that must produce no request at all.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Update
/// Call", REQ "Favourites Collection"
void main() {
  // MockClient hands the handler a plain http.Request even for a multipart
  // send, so the recorded shape is the same for every call here.
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM on [version] where the props call and the collection calls answer
  /// [propsStatus] / [collectionStatus], and `/api/collections` lists
  /// [collections].
  void serve({
    String version = '5.0.0',
    List<Map<String, dynamic>> collections = const [],
    int propsStatus = 200,
    int collectionStatus = 200,
    int createStatus = 201,
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
        if (path == '/api/collections') {
          if (request.method == 'GET') return json(200, collections);
          return json(createStatus, {'id': 77, 'name': 'Favorites'});
        }
        if (path.endsWith('/props')) {
          return http.Response('', propsStatus);
        }
        if (path.startsWith('/api/collections/') && path.endsWith('/roms')) {
          return http.Response('', collectionStatus);
        }
        return http.Response('not found', 404);
      }),
    );
  }

  Future<RommService> connected({
    String version = '5.0.0',
    List<Map<String, dynamic>> collections = const [],
    int propsStatus = 200,
    int collectionStatus = 200,
    int createStatus = 201,
  }) async {
    serve(
      version: version,
      collections: collections,
      propsStatus: propsStatus,
      collectionStatus: collectionStatus,
      createStatus: createStatus,
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

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('updateRomProps', () {
    test('hidden alone sends a bare body and no query flag', () async {
      final service = await connected();

      expect(await service.updateRomProps(42, hidden: true), isTrue);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/api/roms/42/props');
      expect(request.url.queryParameters, isEmpty);
      expect(jsonDecode(request.body), {'hidden': true});
    });

    test('a finished session sends the query flag and an empty body', () async {
      final service = await connected();

      expect(await service.updateRomProps(42, updateLastPlayed: true), isTrue);

      final request = requests.single;
      expect(request.url.queryParameters, {'update_last_played': 'true'});
      expect(jsonDecode(request.body), isEmpty);
    });

    test('both at once are one request', () async {
      final service = await connected();

      await service.updateRomProps(7, hidden: false, updateLastPlayed: true);

      expect(requests, hasLength(1));
      expect(jsonDecode(requests.single.body), {'hidden': false});
      expect(requests.single.url.queryParameters, {
        'update_last_played': 'true',
      });
    });

    test('a server below 4.9.0 is never asked', () async {
      final service = await connected(version: '4.8.0');

      expect(await service.updateRomProps(42, hidden: true), isFalse);
      expect(requests, isEmpty);
    });

    test('a denied playtime scope stops it without a request', () async {
      // Deny the playtime scopes at login so the group settles as denied.
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/heartbeat') {
            return json(200, {
              'SYSTEM': {'VERSION': '5.0.0'},
            });
          }
          if (request.url.path == '/api/token') {
            return request.bodyFields['scope']!.contains('roms.user.')
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

      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.denied);
      expect(await service.updateRomProps(42, hidden: true), isFalse);
      expect(requests, isEmpty);
    });

    test('nothing to say means no request', () async {
      final service = await connected();
      expect(await service.updateRomProps(42), isFalse);
      expect(requests, isEmpty);
    });

    test('a 404 throws with the rom id and status', () async {
      final service = await connected(propsStatus: 404);

      await expectLater(
        service.updateRomProps(42, hidden: true),
        throwsA(
          isA<RommException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('rom=42')),
        ),
      );
    });

    test('a 403 settles the playtime group as denied', () async {
      final service = await connected(propsStatus: 403);

      await expectLater(
        service.updateRomProps(42, hidden: true),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.scopeDenied,
          ),
        ),
      );
      expect(service.hasScope(RommScopeGroup.playtime), RommScopeState.denied);

      requests.clear();
      expect(await service.updateRomProps(42, hidden: true), isFalse);
      expect(requests, isEmpty);
    });
  });

  group('ensureFavouritesCollection', () {
    test('reuses the existing is_favorite collection', () async {
      final service = await connected(
        collections: [
          {'id': 3, 'name': 'Shmups', 'is_favorite': false},
          {'id': 9, 'name': 'Liked', 'is_favorite': true},
        ],
      );

      expect(await service.ensureFavouritesCollection(), 9);
      expect(requests.map((r) => r.method), ['GET']);
    });

    test('creates one when the server has none, once per connection', () async {
      final service = await connected();

      expect(await service.ensureFavouritesCollection(name: 'Favoriten'), 77);

      final create = requests.last;
      expect(create.method, 'POST');
      expect(create.url.path, '/api/collections');
      expect(create.url.queryParameters, {'is_favorite': 'true'});
      expect(create.headers['content-type'], contains('multipart/form-data'));
      expect(create.body, contains('name="name"'));
      expect(create.body, contains('Favoriten'));

      requests.clear();
      expect(await service.ensureFavouritesCollection(), 77);
      expect(requests, isEmpty, reason: 'the id is cached per connection');
    });

    test('a server below 4.9.0 is never asked', () async {
      final service = await connected(version: '4.8.0');

      expect(await service.ensureFavouritesCollection(), isNull);
      expect(requests, isEmpty);
    });
  });

  group('addFavourite / removeFavourite', () {
    test(
      'the first favourite creates the collection and adds the rom',
      () async {
        final service = await connected();

        expect(await service.addFavourite(42), isTrue);

        expect(requests.map((r) => '${r.method} ${r.url.path}'), [
          'GET /api/collections',
          'POST /api/collections',
          'POST /api/collections/77/roms',
        ]);
        expect(jsonDecode(requests.last.body), {
          'rom_ids': [42],
        });
      },
    );

    test('removing uses DELETE with the same body', () async {
      final service = await connected(
        collections: [
          {'id': 9, 'is_favorite': true},
        ],
      );

      expect(await service.removeFavourite(42), isTrue);

      final edit = requests.last;
      expect(edit.method, 'DELETE');
      expect(edit.url.path, '/api/collections/9/roms');
      expect(jsonDecode(edit.body), {
        'rom_ids': [42],
      });
    });

    test('a failure carries the rom and collection in the message', () async {
      final service = await connected(
        collections: [
          {'id': 9, 'is_favorite': true},
        ],
        collectionStatus: 500,
      );

      await expectLater(
        service.addFavourite(42),
        throwsA(
          isA<RommException>().having(
            (e) => e.message,
            'message',
            allOf(contains('rom=42'), contains('collection=9')),
          ),
        ),
      );
    });

    test('a 403 on the edit settles collectionsWrite as denied', () async {
      final service = await connected(
        collections: [
          {'id': 9, 'is_favorite': true},
        ],
        collectionStatus: 403,
      );

      await expectLater(
        service.addFavourite(42),
        throwsA(isA<RommException>()),
      );
      expect(
        service.hasScope(RommScopeGroup.collectionsWrite),
        RommScopeState.denied,
      );

      requests.clear();
      expect(await service.removeFavourite(42), isFalse);
      expect(requests, isEmpty);
    });
  });
}
