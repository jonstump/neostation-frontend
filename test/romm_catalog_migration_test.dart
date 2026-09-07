import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/repositories/romm_catalog_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Migration v165 — the two catalog tables, their read index and the three
/// unified-library config columns — and the repository that reads and writes
/// them.
///
/// Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019
/// REQ "Catalog Tables", REQ "Database Operation Standards"
void main() {
  group('migration v165', () {
    late Database db;

    /// The "old device" case: `user_config` as it stood before this feature.
    const v163UserConfig = '''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_scan TEXT,
        subfolder_view_all INTEGER DEFAULT 0
      )
    ''';

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() {
      db.close();
    });

    Future<void> runV165() => SqliteMigrations.migrateToVersion(db, 165);

    List<String> columnsOf(String table) => db
        .select('PRAGMA table_info($table)')
        .map((c) => c['name'].toString())
        .toList();

    bool tableExists(String name) => db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [name],
    ).isNotEmpty;

    test('creates the catalog with its composite primary key', () async {
      db.execute(v163UserConfig);
      await runV165();

      expect(tableExists('app_romm_catalog'), isTrue);
      expect(columnsOf('app_romm_catalog'), [
        'server_url',
        'romm_rom_id',
        'platform_id',
        'system_folder',
        'name',
        'fs_name',
        'fs_extension',
        'fs_size_bytes',
        'has_multiple_files',
        'path_cover_small',
        'path_cover_large',
        'url_cover',
        'ra_id',
        'genres',
        'release_year',
        'server_updated_at',
        'seen_at',
      ]);

      final key = db
          .select('PRAGMA table_info(app_romm_catalog)')
          .where((c) => (c['pk'] as int) > 0)
          .map((c) => c['name'].toString());
      expect(key, ['server_url', 'romm_rom_id']);
    });

    test('creates the platform ledger and the per-system index', () async {
      db.execute(v163UserConfig);
      await runV165();

      expect(tableExists('app_romm_catalog_platforms'), isTrue);
      expect(columnsOf('app_romm_catalog_platforms'), [
        'server_url',
        'platform_id',
        'system_folder',
        'name',
        'rom_count',
        'refreshed_at',
      ]);

      final index = db.select(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND name='idx_romm_catalog_system'",
      );
      expect(index, hasLength(1));
    });

    test('adds the three config columns with their defaults', () async {
      db.execute(v163UserConfig);
      expect(columnsOf('user_config'), isNot(contains('romm_show_library')));

      await runV165();

      expect(
        columnsOf('user_config'),
        containsAll(SqliteMigrations.rommLibraryConfigColumns.keys),
      );
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      final row = db
          .select(
            'SELECT romm_show_library, romm_library_default_scope, '
            'romm_cover_cache_mb FROM user_config WHERE id = 1',
          )
          .first;
      expect(row['romm_show_library'], 0, reason: 'the feature is opt-in');
      expect(row['romm_library_default_scope'], 'all');
      expect(row['romm_cover_cache_mb'], 200);
    });

    // Governing: SPEC-0019 REQ "Catalog Tables" — scenario "Migration"
    test('running twice leaves the tables and index exactly once', () async {
      db.execute(v163UserConfig);

      await runV165();
      await runV165();

      for (final table in ['app_romm_catalog', 'app_romm_catalog_platforms']) {
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
            [table],
          ),
          hasLength(1),
          reason: '$table exists once',
        );
      }
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND name='idx_romm_catalog_system'",
        ),
        hasLength(1),
      );
      for (final column in SqliteMigrations.rommLibraryConfigColumns.keys) {
        expect(
          columnsOf('user_config').where((c) => c == column),
          hasLength(1),
          reason: '$column exists once',
        );
      }
    });

    test('a database without user_config is left alone, not failed', () async {
      await runV165();

      expect(tableExists('app_romm_catalog'), isTrue);
      expect(tableExists('user_config'), isFalse);
    });

    test('a fresh database gets everything from the CREATE statements', () {
      db.execute(SqliteMigrations.createAppRommCatalogTableSql);
      db.execute(SqliteMigrations.createAppRommCatalogPlatformsTableSql);
      db.execute(SqliteMigrations.createAppRommCatalogIndexSql);

      expect(tableExists('app_romm_catalog'), isTrue);
      expect(tableExists('app_romm_catalog_platforms'), isTrue);
    });
  });

  group('RommCatalogRepository', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    const server = 'https://romm.example';
    final seen = DateTime.utc(2026, 9, 6, 12);

    RommCatalogRow row(
      int id, {
      String name = 'Chrono Trigger',
      String system = 'snes',
      int platform = 1,
      DateTime? seenAt,
    }) => RommCatalogRow(
      serverUrl: server,
      rommRomId: id,
      platformId: platform,
      systemFolder: system,
      name: name,
      fsName: '$name.sfc',
      fsExtension: 'sfc',
      fsSizeBytes: 4194304,
      raId: 1234,
      genres: 'RPG, Adventure',
      releaseYear: '1995',
      seenAt: seenAt ?? seen,
    );

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute(SqliteMigrations.createAppRommCatalogTableSql);
      await adapter.execute(
        SqliteMigrations.createAppRommCatalogPlatformsTableSql,
      );
      await adapter.execute(SqliteMigrations.createAppRommCatalogIndexSql);
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('writes rows and reads them back per system', () async {
      expect(
        await RommCatalogRepository.upsertRows([
          row(10),
          row(11, name: 'Secret of Mana'),
          row(20, name: 'Super Mario Land', system: 'gb', platform: 2),
        ]),
        3,
      );

      final snes = await RommCatalogRepository.rowsForSystem(
        serverUrl: server,
        systemFolder: 'snes',
      );
      expect(snes.map((r) => r.rommRomId), [10, 11]);
      expect(snes.first.name, 'Chrono Trigger');
      expect(snes.first.raId, 1234);
      expect(snes.first.primaryGenre, 'RPG');
      expect(snes.first.fsSizeBytes, 4194304);
      expect(snes.first.seenAt, seen);

      expect(
        await RommCatalogRepository.countForSystem(
          serverUrl: server,
          systemFolder: 'snes',
        ),
        2,
      );
      expect(await RommCatalogRepository.systemsWithRows(server), [
        'gb',
        'snes',
      ]);
    });

    // Governing: SPEC-0019 REQ "Catalog Tables" — scenario "Upsert keeps identity"
    test('an upsert with a new name keeps the row and its key', () async {
      await RommCatalogRepository.upsertRows([row(10)]);
      final later = seen.add(const Duration(hours: 2));

      await RommCatalogRepository.upsertRows([
        row(10, name: 'Chrono Trigger (USA)', seenAt: later),
      ]);

      final rows = await RommCatalogRepository.rowsForSystem(
        serverUrl: server,
        systemFolder: 'snes',
      );
      expect(rows, hasLength(1), reason: 'one row, not two');
      expect(rows.single.name, 'Chrono Trigger (USA)');
      expect(rows.single.seenAt, later);
    });

    // Governing: SPEC-0019 REQ "Catalog Refresh Shares The Walk" — "Deleted on server"
    test('deleteUnseen removes only the rows this run did not stamp', () async {
      await RommCatalogRepository.upsertRows([
        row(10),
        row(11, name: 'Secret of Mana'),
        row(20, name: 'Super Mario Land', system: 'gb', platform: 2),
      ]);
      final nextRun = seen.add(const Duration(days: 1));
      // Only rom 10 is still on the server this time.
      await RommCatalogRepository.upsertRows([row(10, seenAt: nextRun)]);

      final removed = await RommCatalogRepository.deleteUnseen(
        serverUrl: server,
        platformId: 1,
        before: nextRun,
      );

      expect(removed, 1, reason: 'rom 11 is gone from the server');
      expect(
        (await RommCatalogRepository.rowsForSystem(
          serverUrl: server,
          systemFolder: 'snes',
        )).map((r) => r.rommRomId),
        [10],
      );
      expect(
        await RommCatalogRepository.countForSystem(
          serverUrl: server,
          systemFolder: 'gb',
        ),
        1,
        reason: 'another platform is untouched',
      );
    });

    test('rows of another server are never read or deleted', () async {
      await RommCatalogRepository.upsertRows([row(10)]);
      await RommCatalogRepository.upsertRows([
        RommCatalogRow(
          serverUrl: 'https://other.example',
          rommRomId: 10,
          platformId: 1,
          systemFolder: 'snes',
          name: 'Another Server Game',
          fsName: 'Another Server Game.sfc',
          seenAt: seen,
        ),
      ]);

      expect(
        (await RommCatalogRepository.rowsForSystem(
          serverUrl: server,
          systemFolder: 'snes',
        )).single.name,
        'Chrono Trigger',
      );

      await RommCatalogRepository.clear(server);

      expect(
        await RommCatalogRepository.countForSystem(
          serverUrl: 'https://other.example',
          systemFolder: 'snes',
        ),
        1,
        reason: 'clearing one server leaves the other alone',
      );
    });

    // Governing: SPEC-0019 REQ "Database Operation Standards" — "Large upsert"
    test('a large batch is written in chunks and lands whole', () async {
      final many = [
        for (var i = 0; i < 1200; i++) row(1000 + i, name: 'Game $i'),
      ];

      expect(await RommCatalogRepository.upsertRows(many), 1200);
      expect(RommCatalogRepository.upsertChunkSize, 500);
      expect(
        await RommCatalogRepository.countForSystem(
          serverUrl: server,
          systemFolder: 'snes',
        ),
        1200,
      );
    });

    test('records a platform and reads its stamps back', () async {
      final stamp = DateTime.utc(2026, 9, 6, 13);
      await RommCatalogRepository.recordPlatform(
        serverUrl: server,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Super Nintendo',
        romCount: 2,
        refreshedAt: stamp,
      );
      await RommCatalogRepository.recordPlatform(
        serverUrl: server,
        platformId: 2,
        systemFolder: 'gb',
        name: 'Game Boy',
        romCount: 1,
        refreshedAt: stamp.subtract(const Duration(hours: 5)),
      );

      expect(
        await RommCatalogRepository.platformRefreshedAt(
          serverUrl: server,
          platformId: 1,
        ),
        stamp,
      );
      expect(await RommCatalogRepository.newestRefreshedAt(server), stamp);

      final platforms = await RommCatalogRepository.platformsFor(server);
      expect(platforms.map((p) => p.systemFolder), ['gb', 'snes']);
      expect(platforms.last.romCount, 2);
    });

    test('a platform write without a stamp keeps the old one', () async {
      final stamp = DateTime.utc(2026, 9, 6, 13);
      await RommCatalogRepository.recordPlatform(
        serverUrl: server,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Super Nintendo',
        romCount: 2,
        refreshedAt: stamp,
      );

      await RommCatalogRepository.recordPlatform(
        serverUrl: server,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Super Nintendo',
        romCount: 2,
      );

      expect(
        await RommCatalogRepository.platformRefreshedAt(
          serverUrl: server,
          platformId: 1,
        ),
        stamp,
      );
    });

    test('clear empties both tables for the server', () async {
      await RommCatalogRepository.upsertRows([row(10)]);
      await RommCatalogRepository.recordPlatform(
        serverUrl: server,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Super Nintendo',
        romCount: 1,
        refreshedAt: seen,
      );

      expect(await RommCatalogRepository.clear(server), 1);

      expect(await RommCatalogRepository.systemsWithRows(server), isEmpty);
      expect(await RommCatalogRepository.newestRefreshedAt(server), isNull);
    });
  });

  group('the unified-library config columns', () {
    final helper = DatabaseTestHelper();

    setUp(() async {
      await helper.setUp();
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('read as their defaults on a database with no row', () async {
      expect(await ConfigRepository.getRommShowLibrary(), isFalse);
      expect(await ConfigRepository.getRommLibraryDefaultScope(), 'all');
      expect(await ConfigRepository.getRommCoverCacheMb(), 200);
    });

    test('round-trip through the config service', () async {
      await SqliteService.saveUserConfig(
        rommShowLibrary: 1,
        rommLibraryDefaultScope: 'downloaded',
        rommCoverCacheMb: 512,
      );

      expect(await ConfigRepository.getRommShowLibrary(), isTrue);
      expect(await ConfigRepository.getRommLibraryDefaultScope(), 'downloaded');
      expect(await ConfigRepository.getRommCoverCacheMb(), 512);
    });
  });
}
