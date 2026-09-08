import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_rom_filters.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/services/romm_service.dart';

/// The three service calls behind ADR-0019's browse stories: the boolean list
/// filters on `getRomsPage`, the random pick, and the maintenance task run.
///
/// What is pinned is the wire shape — which query parameters are sent and
/// which are *not* — and the two gates that must produce no request at all: a
/// server too old for `/api/roms/random`, and a connection without `tasks.run`.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Filter Parameters", REQ "Surprise Me", REQ "Maintenance Tasks"
void main() {
  final requests = <http.Request>[];

  http.Response json(int status, Object? body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  Map<String, dynamic> romJson(int id, String name) => {
    'id': id,
    'name': name,
    'fs_name': '$name.zip',
    'platform_id': 7,
    'platform_slug': 'snes',
  };

  /// A RomM on [version] whose ROM list answers [roms], whose random pick
  /// answers [randomBody] with [randomStatus], and whose task run answers
  /// [taskStatus] with [taskBody].
  void serve({
    String version = '5.2.0',
    List<Map<String, dynamic>> roms = const [],
    Object? randomBody,
    int randomStatus = 200,
    int taskStatus = 200,
    Object? taskBody = const {'task_id': 'job-42', 'status': 'queued'},
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
        if (path == '/api/roms/random') {
          return randomStatus == 200
              ? json(200, randomBody)
              : http.Response('nope', randomStatus);
        }
        if (path == '/api/roms') {
          return json(200, {'items': roms, 'total': roms.length});
        }
        if (path.startsWith('/api/tasks/run/')) {
          // A String [taskBody] is sent verbatim rather than JSON-encoded, so
          // a test can serve the bodies a real failure produces and JSON
          // cannot express: nothing at all, or a proxy's HTML error page.
          return taskBody is String
              ? http.Response(taskBody, taskStatus)
              : json(taskStatus, taskBody);
        }
        return http.Response('not found', 404);
      }),
    );
  }

  Future<RommService> connected({
    String version = '5.2.0',
    List<Map<String, dynamic>> roms = const [],
    Object? randomBody,
    int randomStatus = 200,
    int taskStatus = 200,
    Object? taskBody = const {'task_id': 'job-42', 'status': 'queued'},
  }) async {
    serve(
      version: version,
      roms: roms,
      randomBody: randomBody,
      randomStatus: randomStatus,
      taskStatus: taskStatus,
      taskBody: taskBody,
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

  // ── Filters ───────────────────────────────────────────────────────────────

  group('getRomsPage filters', () {
    test('sends only the filters that are set', () async {
      final service = await connected();
      await service.getRomsPage(
        platformIds: const [7],
        filters: const RommRomFilters(hasSaves: true, playable: true),
      );
      final query = requests.single.url.queryParameters;
      expect(query['has_saves'], 'true');
      expect(query['playable'], 'true');
      for (final absent in [
        'favorite',
        'has_states',
        'has_ra',
        'duplicate',
        'missing',
      ]) {
        expect(query.containsKey(absent), isFalse, reason: absent);
      }
      // The pre-existing query is untouched.
      expect(query['platform_ids'], '7');
      expect(query['order_by'], 'name');
    });

    test('an unset filter set sends nothing new at all', () async {
      final service = await connected();
      await service.getRomsPage(platformIds: const [7]);
      final query = requests.single.url.queryParameters;
      expect(query.keys.toSet(), {
        'limit',
        'offset',
        'order_by',
        'platform_ids',
      });
    });

    test('a filter set to false is sent as false, not omitted', () async {
      final service = await connected();
      await service.getRomsPage(filters: const RommRomFilters(favorite: false));
      expect(requests.single.url.queryParameters['favorite'], 'false');
    });

    test('the model reports its active filters in enum order', () {
      const filters = RommRomFilters(missing: true, favorite: true);
      expect(filters.active, [RommRomFilter.favorite, RommRomFilter.missing]);
      expect(filters.isNotEmpty, isTrue);
      expect(RommRomFilters.none.isEmpty, isTrue);
    });

    test('toggling flips between on and unset, never to false', () {
      const filters = RommRomFilters.none;
      final on = filters.toggled(RommRomFilter.hasSaves);
      expect(on.hasSaves, isTrue);
      final off = on.toggled(RommRomFilter.hasSaves);
      expect(off.hasSaves, isNull);
      expect(off, RommRomFilters.none);
    });
  });

  // ── Random pick ───────────────────────────────────────────────────────────

  group('getRandomRom', () {
    test('scopes the request to the platform and parses the ROM', () async {
      final service = await connected(randomBody: romJson(9, 'Chrono Trigger'));
      final rom = await service.getRandomRom(platformIds: const [7]);
      expect(rom?.id, 9);
      expect(requests.single.url.path, '/api/roms/random');
      expect(requests.single.url.queryParameters['platform_ids'], '7');
    });

    test('a virtual collection is scoped by its string id', () async {
      final service = await connected(randomBody: romJson(1, 'Ico'));
      await service.getRandomRom(virtualCollectionId: 'genre:rpg');
      expect(
        requests.single.url.queryParameters['virtual_collection_id'],
        'genre:rpg',
      );
    });

    test('a null body is an empty scope, not a failure', () async {
      final service = await connected(randomBody: null);
      expect(await service.getRandomRom(platformIds: const [7]), isNull);
    });

    test('a server below 5.2.0 is not asked at all', () async {
      final service = await connected(version: '5.1.0');
      expect(
        service.supports(RommFeature.randomRom),
        RommFeatureSupport.unsupported,
      );
      expect(await service.getRandomRom(platformIds: const [7]), isNull);
      expect(requests, isEmpty);
    });

    test('a server of unknown version is still asked', () async {
      // No SYSTEM.VERSION in the heartbeat: ADR-0010 says unknown never gates.
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path == '/api/heartbeat') return json(200, const {});
          if (path == '/api/token') {
            return json(200, {'access_token': 'tok', 'expires': 3600});
          }
          if (path == '/api/users/me') return json(200, {'username': 'jon'});
          if (path == '/api/roms/random') return json(200, romJson(3, 'Ys'));
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
        service.supports(RommFeature.randomRom),
        RommFeatureSupport.unknown,
      );
      expect((await service.getRandomRom())?.id, 3);
      expect(requests.single.url.path, '/api/roms/random');
    });

    test(
      'a 404 from a server that claims to be new degrades to null',
      () async {
        final service = await connected(randomStatus: 404);
        expect(await service.getRandomRom(platformIds: const [7]), isNull);
        expect(requests.single.url.path, '/api/roms/random');
      },
    );
  });

  // ── Maintenance tasks ─────────────────────────────────────────────────────

  group('runTask', () {
    test('posts to the named task and returns the queued id', () async {
      final service = await connected();
      expect(await service.runTask('scan_library'), 'job-42');
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/tasks/run/scan_library');
    });

    test('exactly one request per call', () async {
      final service = await connected();
      await service.runTask('cleanup_missing_roms');
      expect(requests.length, 1);
    });

    // Issue #170: the mapping used to read `400 || saysAlreadyRunning(body)`,
    // and `||` short-circuits, so the body never got a say on a 400 and every
    // refusal RomM could not phrase as a 422 reached the user as "That task is
    // already running". RomM 5.1.0's OpenAPI documents only 200 and 422 on
    // this route, so the status carries no such meaning at all — these four
    // pin that the body alone decides.
    test(
      'a 400 that does not say so is an ordinary failure, not busy',
      () async {
        final service = await connected(
          taskStatus: 400,
          taskBody: const {'detail': "Task 'scan_library' cannot be run"},
        );
        await expectLater(
          service.runTask('scan_library'),
          throwsA(
            isA<RommException>()
                .having((e) => e.kind, 'kind', RommErrorKind.other)
                .having((e) => e.statusCode, 'statusCode', 400),
          ),
        );
      },
    );

    test('a 400 with no body at all is an ordinary failure', () async {
      final service = await connected(taskStatus: 400, taskBody: '');
      // A bare status and nothing to read: the case the old mapping turned
      // into "already running" on the strength of the 400 alone.
      await expectLater(
        service.runTask('scan_library'),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.other,
          ),
        ),
      );
    });

    test('a 400 that does say the task is running is still busy', () async {
      final service = await connected(
        taskStatus: 400,
        taskBody: const {'detail': "Task 'scan_library' is already running"},
      );
      await expectLater(
        service.runTask('scan_library'),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.taskBusy,
          ),
        ),
      );
    });

    test(
      'an "already running" answer maps to taskBusy whatever the code',
      () async {
        final service = await connected(
          taskStatus: 409,
          taskBody: const {'detail': 'Task is already running'},
        );
        await expectLater(
          service.runTask('sync_folder_scan'),
          throwsA(
            isA<RommException>().having(
              (e) => e.kind,
              'kind',
              RommErrorKind.taskBusy,
            ),
          ),
        );
      },
    );

    test('a 404 is an ordinary failure, not busy', () async {
      final service = await connected(
        taskStatus: 404,
        taskBody: const {'detail': 'Task not found'},
      );
      await expectLater(
        service.runTask('no_such_task'),
        throwsA(
          isA<RommException>().having(
            (e) => e.kind,
            'kind',
            RommErrorKind.other,
          ),
        ),
      );
    });

    test('an answer without a task id still counts as queued', () async {
      final service = await connected(taskBody: const {'status': 'queued'});
      expect(await service.runTask('scan_library'), 'scan_library');
    });
  });
}
