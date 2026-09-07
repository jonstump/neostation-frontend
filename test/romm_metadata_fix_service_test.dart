import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_search_result.dart';
import 'package:neostation/services/romm_service.dart';

/// The four calls behind "Fix match on RomM" and "Change cover": exact query
/// parameters, exact multipart fields, the `romsWrite` gate that must produce
/// no request at all, and the 500 that means the *server* has no metadata
/// provider rather than that the request was wrong.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Metadata Search And Apply", REQ "Error Handling Standards"
void main() {
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// The multipart fields of a recorded request. MockClient hands the handler
  /// a plain [http.Request] whose body is the encoded multipart document, so
  /// the field names and values are read back out of it.
  Map<String, String> multipartFields(http.Request request) {
    final pattern = RegExp(r'name="([^"]+)"\r\n\r\n(.*?)\r\n--', dotAll: true);
    return {
      for (final match in pattern.allMatches(request.body))
        match.group(1)!: match.group(2)!,
    };
  }

  /// A RomM whose search endpoints answer [searchStatus] with [searchBody] and
  /// whose `PUT /api/roms/{id}` answers [updateStatus].
  void serve({
    Map<String, dynamic>? metadataSources,
    Set<String> deniedScopes = const {},
    Object searchBody = const [],
    int searchStatus = 200,
    Object coverBody = const [],
    int coverStatus = 200,
    int updateStatus = 200,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return json(200, {
              'SYSTEM': {'VERSION': '5.1.0'},
              'METADATA_SOURCES': ?metadataSources,
            });
          case '/api/token':
            final scope = request.bodyFields['scope'] ?? '';
            return deniedScopes.any(scope.contains)
                ? http.Response('forbidden', 403)
                : json(200, {'access_token': 'tok', 'expires': 3600});
          case '/api/users/me':
            return json(200, {'id': 1, 'username': 'jon'});
          case '/api/search/roms':
            return json(searchStatus, searchBody);
          case '/api/search/cover':
            return json(coverStatus, coverBody);
          case '/api/roms/42':
            return json(updateStatus, {
              'id': 42,
              'name': 'Chrono Trigger',
              'platform_id': 6,
              'platform_slug': 'snes',
              'fs_name': 'ct.sfc',
              'url_cover': 'https://cdn/ct.png',
            });
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  Future<RommService> connected({
    Map<String, dynamic>? metadataSources,
    Set<String> deniedScopes = const {},
    Object searchBody = const [],
    int searchStatus = 200,
    Object coverBody = const [],
    int coverStatus = 200,
    int updateStatus = 200,
  }) async {
    serve(
      metadataSources: metadataSources,
      deniedScopes: deniedScopes,
      searchBody: searchBody,
      searchStatus: searchStatus,
      coverBody: coverBody,
      coverStatus: coverStatus,
      updateStatus: updateStatus,
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

  const candidate = {
    'igdb_id': 123,
    'moby_id': 456,
    'rom_id': 42,
    'platform_id': 6,
    'name': 'Chrono Trigger',
    'summary': 'A time-travelling RPG.',
    'igdb_url_cover': 'https://images.igdb/ct.png',
  };

  setUp(requests.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('searchRomMetadata', () {
    test('sends rom_id and search_term and parses the candidate', () async {
      final service = await connected(searchBody: [candidate]);

      final found = await service.searchRomMetadata(42, '  Chrono Trigger  ');

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/search/roms');
      expect(request.url.queryParameters, {
        'rom_id': '42',
        'search_term': 'Chrono Trigger',
      });

      expect(found, hasLength(1));
      final result = found.single;
      expect(result.name, 'Chrono Trigger');
      expect(result.summary, 'A time-travelling RPG.');
      expect(result.platformId, 6);
      expect(result.coverUrl, 'https://images.igdb/ct.png');
      // rom_id and platform_id travel in the same object but are not
      // provider ids, so they must not be posted back as one.
      expect(result.providerIds, {'igdb_id': 123, 'moby_id': 456});
    });

    test('drops a candidate that names no provider', () async {
      final service = await connected(
        searchBody: [
          candidate,
          {'name': 'Nothing to match on'},
        ],
      );

      final found = await service.searchRomMetadata(42, 'ct');

      expect(found.map((r) => r.name), ['Chrono Trigger']);
    });

    test('maps a 500 to noMetadataSource with the status', () async {
      final service = await connected(searchStatus: 500, searchBody: {});

      await expectLater(
        service.searchRomMetadata(42, 'ct'),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.noMetadataSource)
              .having((e) => e.statusCode, 'statusCode', 500)
              .having(
                (e) => e.message,
                'message',
                contains('/api/search/roms'),
              ),
        ),
      );
    });

    test('leaves any other failure as a plain error', () async {
      final service = await connected(searchStatus: 502, searchBody: {});

      await expectLater(
        service.searchRomMetadata(42, 'ct'),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.other)
              .having((e) => e.statusCode, 'statusCode', 502),
        ),
      );
    });
  });

  group('searchCovers', () {
    test('flattens the grouped resources into one entry per image', () async {
      final service = await connected(
        coverBody: [
          {
            'name': 'Chrono Trigger',
            'resources': [
              {'thumb': 'https://sgdb/t1.png', 'url': 'https://sgdb/1.png'},
              {'url': 'https://sgdb/2.png'},
            ],
          },
        ],
      );

      final covers = await service.searchCovers('Chrono Trigger');

      expect(requests.single.url.path, '/api/search/cover');
      expect(requests.single.url.queryParameters, {
        'search_term': 'Chrono Trigger',
      });
      expect(covers.map((c) => c.url), [
        'https://sgdb/1.png',
        'https://sgdb/2.png',
      ]);
      expect(covers.first.previewUrl, 'https://sgdb/t1.png');
      // No thumbnail: the full cover is what the list paints.
      expect(covers.last.previewUrl, 'https://sgdb/2.png');
    });

    test('maps a 500 to noMetadataSource', () async {
      final service = await connected(coverStatus: 500, coverBody: {});

      await expectLater(
        service.searchCovers('ct'),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.noMetadataSource,
          ),
        ),
      );
    });
  });

  group('applyRomMatch', () {
    test(
      'PUTs the provider ids, the name and the cover as multipart',
      () async {
        final service = await connected();
        final result = RommSearchResult.fromJson(Map.of(candidate));

        final updated = await service.applyRomMatch(42, result);

        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/roms/42');
        expect(
          request.headers['content-type'],
          contains('multipart/form-data'),
        );
        expect(multipartFields(request), {
          'igdb_id': '123',
          'moby_id': '456',
          'name': 'Chrono Trigger',
          'url_cover': 'https://images.igdb/ct.png',
        });

        expect(updated, isNotNull);
        expect(updated!.id, 42);
        expect(updated.name, 'Chrono Trigger');
      },
    );

    test('sends nothing when the romsWrite group is denied', () async {
      final service = await connected(deniedScopes: {'roms.write'});
      expect(service.hasScope(RommScopeGroup.romsWrite), RommScopeState.denied);

      final updated = await service.applyRomMatch(
        42,
        RommSearchResult.fromJson(Map.of(candidate)),
      );

      expect(updated, isNull);
      expect(requests, isEmpty);
    });

    test(
      'a candidate with no name omits the field rather than blanking it',
      () async {
        // A blank `name` is not "leave it alone" to RomM: the field is present
        // in the form, so it would erase the entry's title for every client of
        // the server. Same hazard `applyRomCover` refuses an empty URL for.
        // Governing: ADR-0019, SPEC-0018 REQ "Metadata Search And Apply"
        final service = await connected();
        final nameless = Map.of(candidate)..['name'] = '   ';

        final updated = await service.applyRomMatch(
          42,
          RommSearchResult.fromJson(nameless),
        );

        // The write still happens: the provider ids are what RomM re-matches
        // on, and the name it already holds survives untouched.
        expect(updated, isNotNull);
        expect(requests, hasLength(1));
        final fields = multipartFields(requests.single);
        expect(fields.containsKey('name'), isFalse);
        expect(fields['igdb_id'], '123');
      },
    );

    test('a 403 records the denial and carries scopeDenied', () async {
      final service = await connected(updateStatus: 403);

      await expectLater(
        service.applyRomMatch(42, RommSearchResult.fromJson(Map.of(candidate))),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.scopeDenied,
          ),
        ),
      );
      expect(service.hasScope(RommScopeGroup.romsWrite), RommScopeState.denied);
    });
  });

  group('applyRomCover', () {
    test('PUTs url_cover alone', () async {
      final service = await connected();

      final updated = await service.applyRomCover(42, ' https://sgdb/1.png ');

      expect(multipartFields(requests.single), {
        'url_cover': 'https://sgdb/1.png',
      });
      expect(updated?.id, 42);
    });

    test(
      'refuses an empty URL locally rather than clearing the cover',
      () async {
        final service = await connected();

        expect(await service.applyRomCover(42, '   '), isNull);
        expect(requests, isEmpty);
      },
    );

    test('sends nothing when the romsWrite group is denied', () async {
      final service = await connected(deniedScopes: {'roms.write'});

      expect(await service.applyRomCover(42, 'https://sgdb/1.png'), isNull);
      expect(requests, isEmpty);
    });
  });

  group('hasMetadataSource', () {
    test('false only when the server says every provider is off', () async {
      final service = await connected(
        metadataSources: const {
          'IGDB_API_ENABLED': false,
          'MOBY_API_ENABLED': false,
          'SS_API_ENABLED': false,
          'SS_DEV_CREDENTIALS_SET': true,
        },
      );

      expect(service.hasMetadataSource, isFalse);
    });

    test('true when one provider is enabled', () async {
      final service = await connected(
        metadataSources: const {
          'IGDB_API_ENABLED': false,
          'MOBY_API_ENABLED': true,
        },
      );

      expect(service.hasMetadataSource, isTrue);
    });

    test("ANY_SOURCE_ENABLED wins over the per-provider flags", () async {
      final service = await connected(
        metadataSources: const {
          'ANY_SOURCE_ENABLED': true,
          'IGDB_API_ENABLED': false,
        },
      );

      expect(service.hasMetadataSource, isTrue);
    });

    test('unknown never gates: no METADATA_SOURCES section at all', () async {
      final service = await connected();

      expect(service.hasMetadataSource, isTrue);
    });
  });
}
