import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_catalog_repository.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm/romm_cover_cache.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [RommProvider]'s catalog summary — the per-system counts and the "as of"
/// stamp the carousel and the RomM settings read — and the two events that
/// must drop the catalog: a disconnect and "Clear cached RomM library".
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only
/// Systems", REQ "Settings And Actions"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const server = 'https://romm.local';
  final dbHelper = DatabaseTestHelper();
  late Directory temp;

  http.Response json(int status, Object body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  void serve() {
    RommService.debugUseHttpClient(
      MockClient((request) async {
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

  RommCoverCache cache() => RommCoverCache(
    root: () async => temp.path,
    fetch: (_) async => null,
    coverUrls: (_) => const [],
    capMb: () async => 200,
  );

  Future<void> seedCatalog() async {
    await RommCatalogRepository.upsertRows([
      for (final (id, folder) in [(1, 'gba'), (2, 'gba'), (3, 'pcengine')])
        RommCatalogRow(
          serverUrl: server,
          rommRomId: id,
          platformId: folder == 'gba' ? 1 : 2,
          systemFolder: folder,
          name: 'Game $id',
          fsName: 'Game $id.bin',
          seenAt: DateTime.utc(2026, 9, 8),
        ),
    ]);
    await RommCatalogRepository.recordPlatform(
      serverUrl: server,
      platformId: 1,
      systemFolder: 'gba',
      name: 'GBA',
      romCount: 2,
      refreshedAt: DateTime.utc(2026, 9, 8, 12),
    );
  }

  Future<RommProvider> restoredProvider() async {
    serve();
    await RommRepository.saveConfig(serverUrl: server, apiKey: 'test-key');
    final provider = RommProvider(coverCache: cache());
    await provider.initialize();
    // initialize() kicks the summary read off without waiting for it.
    await provider.reloadCatalogSystems();
    return provider;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation_romm_catalog');
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    final db = await dbHelper.setUp();
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogIndexSql);
    await db.execute(SqliteMigrations.createAppRommCatalogPlatformsTableSql);
    await seedCatalog();
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a restored connection summarises the catalog per system', () async {
    final provider = await restoredProvider();

    expect(provider.isConnected, isTrue);
    expect(provider.catalogSystemCounts, {'gba': 2, 'pcengine': 1});
    expect(provider.catalogAsOf, DateTime.utc(2026, 9, 8, 12));
  });

  test('the revision moves once per change and notifies once', () async {
    final provider = await restoredProvider();
    final revision = provider.catalogRevision;
    var notified = 0;
    provider.addListener(() => notified++);

    await provider.reloadCatalogSystems();
    expect(provider.catalogRevision, revision, reason: 'nothing changed');
    expect(notified, 0);

    await RommCatalogRepository.clear(server);
    await provider.reloadCatalogSystems();
    expect(provider.catalogRevision, revision + 1);
    expect(notified, 1);
    expect(provider.catalogSystemCounts, isEmpty);
  });

  test('disconnect clears the catalog for the server', () async {
    final provider = await restoredProvider();

    await provider.disconnect();
    // The delete is fire-and-forget beside the cover clear; let it land.
    await Future<void>.delayed(Duration.zero);

    expect(provider.isConnected, isFalse);
    expect(await RommCatalogRepository.countsBySystem(server), isEmpty);
    expect(await RommCatalogRepository.newestRefreshedAt(server), isNull);
    expect(provider.catalogSystemCounts, isEmpty);
    expect(provider.catalogAsOf, isNull);
  });

  test('clearCatalog drops the rows and empties the summary', () async {
    final provider = await restoredProvider();
    var notified = 0;
    provider.addListener(() => notified++);

    await provider.clearCatalog();

    expect(await RommCatalogRepository.countsBySystem(server), isEmpty);
    expect(provider.catalogSystemCounts, isEmpty);
    expect(provider.catalogAsOf, isNull);
    expect(notified, 1);
    // Still connected: only the cache went, not the server.
    expect(provider.isConnected, isTrue);
  });

  test('without a connection the summary is empty', () async {
    final provider = RommProvider(coverCache: cache());
    await provider.initialize();
    await provider.reloadCatalogSystems();

    expect(provider.isConnected, isFalse);
    expect(provider.catalogSystemCounts, isEmpty);
    // The rows themselves are untouched: nothing was connected to clear.
    expect(await RommCatalogRepository.countsBySystem(server), {
      'gba': 2,
      'pcengine': 1,
    });
  });
}
