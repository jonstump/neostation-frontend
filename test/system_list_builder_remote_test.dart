import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/repositories/romm_catalog_repository.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/screens/systems_screen/my_systems_section/system_list_builder.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm/romm_cover_cache.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/system_sort.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [buildSystemsList] with the RomM catalog: systems the server has ROMs for
/// but the device has no folder for appear among the detected ones, in the
/// configured order, wearing the cloud glyph — unless the toggle is off, the
/// opening scope is `downloaded`, or the server is unreachable.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only
/// Systems", REQ "Library Scope"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const server = 'https://romm.local';
  final dbHelper = DatabaseTestHelper();
  late Directory temp;
  late dynamic db;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

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

  Future<void> system(String id, String name, {String? launchDate}) =>
      db.execute(
        'INSERT INTO app_systems (id, real_name, folder_name, launch_date) '
        'VALUES (?, ?, ?, ?)',
        [id, name, id, launchDate],
      );

  Future<void> detect(String id) => db.execute(
    'INSERT INTO user_detected_systems (app_system_id, actual_folder_name) '
    'VALUES (?, ?)',
    [id, id],
  );

  Future<void> catalog(String folder, int count) =>
      RommCatalogRepository.upsertRows([
        for (var i = 0; i < count; i++)
          RommCatalogRow(
            serverUrl: server,
            rommRomId: folder.hashCode.abs() % 100000 + i,
            platformId: folder.hashCode.abs() % 1000,
            systemFolder: folder,
            name: '$folder $i',
            fsName: '$folder-$i.bin',
            seenAt: DateTime.utc(2026, 9, 8),
          ),
      ]);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation_builder');
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    db = await dbHelper.setUp();
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogIndexSql);
    await db.execute(SqliteMigrations.createAppRommCatalogPlatformsTableSql);
    await db.execute('INSERT INTO user_config (id) VALUES (1)');
    await system('gba', 'Game Boy Advance', launchDate: '2001');
    await system('snes', 'Super Nintendo', launchDate: '1990');
    await system('pcengine', 'PC Engine', launchDate: '1987');
    await system('nes', 'Nintendo Entertainment System', launchDate: '1983');
    await detect('gba');
    await detect('snes');
    await catalog('gba', 4);
    await catalog('pcengine', 3);
    await catalog('nes', 5);
  });

  tearDown(() async {
    RommService.debugUseHttpClient(null);
    CredentialStore.debugReset();
    await dbHelper.tearDown();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// The providers as the app would hold them after startup: config and
  /// systems from the database, a restored RomM connection with its summary.
  Future<({SqliteConfigProvider config, RommProvider romm, bool connected})>
  providers({required bool showLibrary, String scope = 'all'}) async {
    final config = SqliteConfigProvider();
    await config.reloadSystemDefinitions();
    await config.refreshDetectedSystems();
    // The provider's own startup path is the whole app's; the mutators set
    // the in-memory config the builder reads, which is all this needs.
    await config.updateRommShowLibrary(showLibrary);
    await config.updateRommLibraryDefaultScope(scope);

    serve();
    await RommRepository.saveConfig(serverUrl: server, apiKey: 'test-key');
    final romm = RommProvider(
      coverCache: RommCoverCache(
        root: () async => temp.path,
        fetch: (_) async => null,
        coverUrls: (_) => const [],
        capMb: () async => 200,
      ),
    );
    await romm.initialize();
    await romm.reloadCatalogSystems();
    return (config: config, romm: romm, connected: romm.isConnected);
  }

  Future<List<SystemInfo>> build(
    WidgetTester tester, {
    required SqliteConfigProvider config,
    required RommProvider romm,
  }) async {
    List<SystemInfo>? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates:
            FlutterLocalization.instance.localizationsDelegates,
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        home: Builder(
          builder: (context) {
            result = buildSystemsList(
              context: context,
              configProvider: config,
              dbProvider: SqliteDatabaseProvider(),
              fileProvider: FileProvider(),
              collectionsProvider: CollectionsProvider(),
              rommProvider: romm,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // The app builds `home` only once its localization delegates have
    // loaded, which is a frame later than the first pump.
    await tester.pumpAndSettle();
    expect(result, isNotNull, reason: 'the builder never ran');
    return result!;
  }

  List<String?> folders(List<SystemInfo> systems) =>
      systems.where((s) => !s.isGame).map((s) => s.folderName).toList();

  testWidgets('remote-only systems join the detected ones, in sort order', (
    tester,
  ) async {
    final p = await providers(showLibrary: true);
    expect(p.connected, isTrue);
    expect(p.romm.catalogSystemCounts, {'gba': 4, 'pcengine': 3, 'nes': 5});

    final systems = await build(tester, config: p.config, romm: p.romm);

    // Alphabetical by real name is the default sort: Game Boy Advance,
    // Nintendo Entertainment System, PC Engine, Super Nintendo.
    expect(folders(systems), ['gba', 'nes', 'pcengine', 'snes']);

    final pcEngine = systems.singleWhere((s) => s.folderName == 'pcengine');
    expect(pcEngine.badgeIcon, kRommRemoteOnlyGlyph);
    expect(
      pcEngine.badgeLabel,
      AppLocale.en[AppLocale.rommRemoteOnlySystemLabel],
    );
    expect(pcEngine.numOfRoms, 3);

    // A detected system with catalog rows is not a remote-only one.
    final gba = systems.singleWhere((s) => s.folderName == 'gba');
    expect(gba.badgeIcon, isNull);
  });

  testWidgets('the configured sort orders the union', (tester) async {
    final p = await providers(showLibrary: true);
    await p.config.updateSystemSortBy('year');
    await p.config.refreshDetectedSystems();

    final systems = await build(tester, config: p.config, romm: p.romm);

    expect(folders(systems), ['nes', 'pcengine', 'snes', 'gba']);
  });

  testWidgets('toggle off: detected systems only', (tester) async {
    final p = await providers(showLibrary: false);

    final systems = await build(tester, config: p.config, romm: p.romm);

    expect(folders(systems), ['gba', 'snes']);
  });

  testWidgets('a downloaded default scope hides remote-only systems', (
    tester,
  ) async {
    final p = await providers(showLibrary: true, scope: 'downloaded');

    final systems = await build(tester, config: p.config, romm: p.romm);

    expect(folders(systems), ['gba', 'snes']);
  });

  testWidgets('a hidden system stays hidden even with catalog rows', (
    tester,
  ) async {
    final p = await providers(showLibrary: true);
    await p.config.toggleSystemHidden('pcengine');

    final systems = await build(tester, config: p.config, romm: p.romm);

    expect(folders(systems), ['gba', 'nes', 'snes']);
  });

  test('systemForFolder falls through to the full systems list', () async {
    final p = await providers(showLibrary: true);

    expect(systemForFolder(p.config, 'gba')?.id, 'gba');
    expect(systemForFolder(p.config, 'pcengine')?.id, 'pcengine');
    expect(systemForFolder(p.config, 'PCENGINE')?.id, 'pcengine');
    expect(systemForFolder(p.config, 'atari2600'), isNull);
  });

  group('compareSystemsForCarousel', () {
    SystemModel sys(
      String folder,
      String name, {
      String? date,
      String? maker,
    }) => SystemModel(
      id: folder,
      folderName: folder,
      realName: name,
      iconImage: '',
      color: '#000000',
      launchDate: date,
      manufacturer: maker,
    );

    test('virtual entries float to the top in a fixed order', () {
      final list = [
        sys('snes', 'Super Nintendo'),
        sys('favorites', 'Favorites'),
        sys('all', 'All'),
      ];
      list.sort(
        (a, b) => compareSystemsForCarousel(
          a,
          b,
          sortBy: 'alphabetical',
          ascending: false,
        ),
      );
      expect(list.map((s) => s.folderName), ['all', 'favorites', 'snes']);
    });

    test('year sorts undated systems last and honours direction', () {
      final list = [
        sys('a', 'A'),
        sys('b', 'B', date: '1990'),
        sys('c', 'C', date: '1983'),
      ];
      list.sort(
        (x, y) =>
            compareSystemsForCarousel(x, y, sortBy: 'year', ascending: true),
      );
      expect(list.map((s) => s.folderName), ['c', 'b', 'a']);
      list.sort(
        (x, y) =>
            compareSystemsForCarousel(x, y, sortBy: 'year', ascending: false),
      );
      expect(list.map((s) => s.folderName), ['a', 'b', 'c']);
    });
  });
}
