import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm/romm_cover_cache.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [RommProvider] warms [RommCoverCache] as soon as a connection exists —
/// restored from the database at startup, or made by [RommProvider.connect]
/// — so a card's `pathFor` finds a cover that is already on disk without a
/// request. The cache runs against a temp directory whose root function
/// counts its calls, which is how a test tells "the provider started the
/// scan" from "the test did"; the RomM is scripted and every fetch recorded.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const server = 'https://romm.local';
  final dbHelper = DatabaseTestHelper();
  late Directory temp;
  var rootCalls = 0;
  final fetched = <String>[];
  final requests = <http.Request>[];

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A RomM that answers only what an API-key connect needs.
  void serve() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/api/heartbeat':
            return json(200, {
              'SYSTEM': {'VERSION': '5.1.0'},
            });
          case '/api/users/me':
            return json(200, {'id': 1, 'username': 'jon'});
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  /// A cover an earlier run left on disk, laid out the way the cache does.
  Future<void> seedCover(int romId) async {
    final dir = Directory(p.join(temp.path, RommCoverCache.serverHash(server)));
    await dir.create(recursive: true);
    final jpeg = Uint8List(10)
      ..[0] = 0xFF
      ..[1] = 0xD8
      ..[2] = 0xFF;
    await File(p.join(dir.path, '$romId.jpg')).writeAsBytes(jpeg);
  }

  RommCoverCache cache() => RommCoverCache(
    root: () async {
      rootCalls++;
      return temp.path;
    },
    fetch: (url) async {
      fetched.add(url);
      return null;
    },
    coverUrls: (_) => const [],
    capMb: () async => 200,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation_romm_provider');
    rootCalls = 0;
    fetched.clear();
    requests.clear();
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    final db = await dbHelper.setUp();
    // The connect path drains the play-session outbox in the background.
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a restored session rebuilds the index without a request', () async {
    serve();
    await seedCover(42);
    await RommRepository.saveConfig(serverUrl: server, apiKey: 'test-key');
    final covers = cache();

    final provider = RommProvider(coverCache: covers);
    await provider.initialize();

    expect(provider.status, RommConnectionStatus.connected);
    expect(rootCalls, 1, reason: 'initialize() started the scan itself');
    // initialize() does not wait for the scan; joining it is what a card
    // would do, and joining must not start a second one.
    await covers.initialize();
    expect(rootCalls, 1);

    expect(covers.pathFor(server, 42), endsWith('42.jpg'));
    expect(fetched, isEmpty, reason: 'a rebuild is a directory listing');
    expect(requests, isEmpty, reason: 'and initialize() is offline');
  });

  test('a fresh connection warms the cache too', () async {
    serve();
    await seedCover(7);
    final covers = cache();

    final provider = RommProvider(coverCache: covers);
    expect(
      await provider.connect(serverUrl: server, apiKey: 'test-key'),
      isNull,
    );

    expect(rootCalls, 1, reason: 'connect() started the scan itself');
    await covers.initialize();
    expect(covers.pathFor(server, 7), endsWith('7.jpg'));
    expect(fetched, isEmpty);
  });

  test('without a saved connection there is nothing to warm', () async {
    final covers = cache();

    final provider = RommProvider(coverCache: covers);
    await provider.initialize();

    expect(provider.status, RommConnectionStatus.disconnected);
    expect(rootCalls, 0);
    expect(requests, isEmpty);
  });
}
