import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/repositories/romm_catalog_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/game/game_list_service.dart';

import 'database_test_helper.dart';

/// The merge in [GameListService.loadGamesForSystem]: catalog rows appended
/// as remote entries, hidden behind local games by the link map or by
/// filename, sorted with the local rule, present in the `all` aggregate and
/// absent from favourites and collections — against the real repositories
/// on an in-memory database.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In
/// The Game Model", REQ "Settings And Actions"
void main() {
  const server = 'https://romm.local';
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  const gba = SystemModel(
    id: 'gba',
    folderName: 'gba',
    realName: 'Game Boy Advance',
    iconImage: '/images/icons/gba.png',
    color: '#000000',
    folders: ['gba', 'gameboyadvance'],
  );
  const all = SystemModel(
    folderName: SystemFolderNames.all,
    realName: 'All Games',
    iconImage: '/images/icons/all.png',
    color: '#000000',
  );
  const favorites = SystemModel(
    folderName: SystemFolderNames.favorites,
    realName: 'Favorites',
    iconImage: '/images/icons/favorites.png',
    color: '#000000',
  );

  Future<void> seedCatalog(List<int> ids, {String folder = 'gba'}) =>
      RommCatalogRepository.upsertRows([
        for (final id in ids)
          RommCatalogRow(
            serverUrl: server,
            rommRomId: id,
            platformId: 1,
            systemFolder: folder,
            name: 'Game $id',
            fsName: 'Game $id (USA).gba',
            fsSizeBytes: id * 1000,
            seenAt: DateTime.utc(2026, 9, 8),
          ),
      ]);

  Future<void> addLocal(
    String filename, {
    String system = 'gba',
    bool favorite = false,
    bool hidden = false,
  }) => db.execute(
    'INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite, '
    'is_hidden) VALUES (?, ?, ?, ?, ?)',
    [
      filename,
      '/roms/$system/$filename',
      system,
      favorite ? 1 : 0,
      hidden ? 1 : 0,
    ],
  );

  Future<void> link(String filename, int romId, {String folder = 'gba'}) =>
      RommSaveMapRepository.putMappingsIfAbsent([
        (
          romname: filename,
          systemFolder: folder,
          rommRomId: romId,
          fsName: null,
          source: RommLinkSource.auto,
        ),
      ]);

  Future<void> setShowLibrary(bool on) =>
      SqliteService.saveUserConfig(rommShowLibrary: on ? 1 : 0);

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(SqliteMigrations.createUserRommConfigTableSql);
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogTableSql);
    await db.execute(SqliteMigrations.createAppRommCatalogIndexSql);
    await db.execute(SqliteMigrations.createAppRommCatalogPlatformsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsTableSql);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('gba', 'Game Boy Advance', 'gba')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('pcengine', 'PC Engine', 'pcengine')",
    );
    await db.execute(
      "INSERT INTO app_system_extensions (system_id, extension) VALUES ('gba', 'gba')",
    );
    await db.execute('INSERT INTO user_config (id) VALUES (1)');
    await db.execute(
      'INSERT INTO user_romm_config (id, server_url) VALUES (1, ?)',
      [server],
    );
    await setShowLibrary(true);
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('loadGamesForSystem', () {
    test('ten on the server, two local: ten entries, eight remote', () async {
      await seedCatalog(List.generate(10, (i) => i + 1));
      await addLocal('Game 1 (USA).gba');
      await addLocal('Game 2 (USA).gba');
      await link('Game 1 (USA).gba', 1);
      await link('Game 2 (USA).gba', 2);

      final games = await GameListService.loadGamesForSystem(gba);

      expect(games.length, 10);
      expect(games.where((g) => g.isRemote).length, 8);
      expect(games.where((g) => !g.isRemote).length, 2);
      final remoteIds = games.where((g) => g.isRemote).map((g) => g.rommRomId);
      expect(remoteIds, isNot(contains(1)));
      expect(remoteIds, isNot(contains(2)));
    });

    test('a link map entry hides the row even when names differ', () async {
      await seedCatalog([5]);
      // Renamed on disk after the download; the link map still knows.
      await addLocal('my-renamed-copy.gba');
      await link('my-renamed-copy.gba', 5);

      final games = await GameListService.loadGamesForSystem(gba);

      expect(games.map((g) => g.romname), ['my-renamed-copy.gba']);
      expect(games.single.isRemote, isFalse);
    });

    test('a local file with the same name hides the row without a link map '
        'entry', () async {
      await seedCatalog([3]);
      // Different case: the equivalence rule is case-insensitive.
      await addLocal('game 3 (usa).GBA');

      final games = await GameListService.loadGamesForSystem(gba);

      expect(games.length, 1);
      expect(games.single.isRemote, isFalse);
      expect(games.single.romname, 'game 3 (usa).GBA');
    });

    test('a hidden local copy still hides its row', () async {
      await seedCatalog([4]);
      await addLocal('Game 4 (USA).gba', hidden: true);

      final games = await GameListService.loadGamesForSystem(gba);

      // The hidden game is out of the list, and the catalog row it hides
      // does not take its place as a downloadable copy.
      expect(games, isEmpty);
    });

    test('deleted locally: the row reappears as a remote entry', () async {
      await seedCatalog([6]);
      await addLocal('Game 6 (USA).gba');
      await link('Game 6 (USA).gba', 6);
      expect(
        (await GameListService.loadGamesForSystem(gba)).single.isRemote,
        isFalse,
      );

      await db.execute(
        "DELETE FROM user_roms WHERE filename = 'Game 6 (USA).gba'",
      );
      await RommSaveMapRepository.removeMapping('Game 6 (USA).gba', 'gba');

      final games = await GameListService.loadGamesForSystem(gba);
      expect(games.single.isRemote, isTrue);
      expect(games.single.rommRomId, 6);
    });

    test('remote entries carry the catalog fields and the system', () async {
      await RommCatalogRepository.upsertRows([
        RommCatalogRow(
          serverUrl: server,
          rommRomId: 42,
          platformId: 1,
          systemFolder: 'gba',
          name: 'Metroid Fusion',
          fsName: 'Metroid Fusion (USA).gba',
          fsSizeBytes: 8 * 1024 * 1024,
          raId: 3017,
          genres: 'Action, Adventure',
          releaseYear: '2002',
          seenAt: DateTime.utc(2026, 9, 8),
        ),
      ]);

      final game = (await GameListService.loadGamesForSystem(gba)).single;

      expect(game.isRemote, isTrue);
      expect(game.name, 'Metroid Fusion');
      expect(game.showRomFileNameSubtitle, isTrue);
      expect(game.romname, 'Metroid Fusion (USA).gba');
      expect(game.systemId, 'gba');
      expect(game.systemFolderName, 'gba');
      expect(game.idRa, 3017);
      expect(game.genre, 'Action');
      expect(game.year, '2002');
      expect(game.remoteSizeBytes, 8 * 1024 * 1024);
    });

    test('the system name settings apply to remote entries', () async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, prefer_file_name, "
        "hide_extension, hide_parentheses) VALUES ('gba', 1, 1, 1)",
      );
      await seedCatalog([8]);

      final game = (await GameListService.loadGamesForSystem(gba)).single;

      expect(game.name, 'Game 8');
      expect(game.showRomFileNameSubtitle, isFalse);
    });

    test(
      'sorts favourites first, then by name across local and remote',
      () async {
        await seedCatalog([1, 2]); // "Game 1", "Game 2"
        await addLocal('Zelda.gba', favorite: true);
        await addLocal('Aria.gba');

        final games = await GameListService.loadGamesForSystem(gba);

        expect(games.map((g) => g.romname), [
          'Zelda.gba', // favourite first
          'Aria.gba',
          'Game 1 (USA).gba',
          'Game 2 (USA).gba',
        ]);
      },
    );

    test('rows filed under a folder alias are read too', () async {
      await seedCatalog([11], folder: 'gameboyadvance');

      final games = await GameListService.loadGamesForSystem(gba);

      expect(games.single.rommRomId, 11);
    });

    test(
      'toggle off: no remote entries, and the catalog rows remain',
      () async {
        await seedCatalog([1, 2, 3]);
        await addLocal('Local.gba');
        await setShowLibrary(false);

        final games = await GameListService.loadGamesForSystem(gba);

        expect(games.map((g) => g.romname), ['Local.gba']);
        expect(
          await RommCatalogRepository.countForSystem(
            serverUrl: server,
            systemFolder: 'gba',
          ),
          3,
        );
      },
    );

    test('no configured server: no remote entries', () async {
      await seedCatalog([1]);
      await db.execute('DELETE FROM user_romm_config');

      expect(await GameListService.loadGamesForSystem(gba), isEmpty);
    });
  });

  group('the all aggregate', () {
    test('includes remote entries under the same rule', () async {
      await seedCatalog([1, 2, 3]);
      await seedCatalog([20], folder: 'pcengine');
      await addLocal('Game 1 (USA).gba');
      await link('Game 1 (USA).gba', 1);

      final games = await GameListService.loadGamesForSystem(all);

      expect(games.length, 4);
      expect(games.where((g) => g.isRemote).map((g) => g.rommRomId).toSet(), {
        2,
        3,
        20,
      });
      // A remote-only system's entries carry that system, not the aggregate.
      expect(
        games.singleWhere((g) => g.rommRomId == 20).systemFolderName,
        'pcengine',
      );
    });

    test('is unchanged with the toggle off', () async {
      await seedCatalog([1, 2, 3]);
      await addLocal('Local.gba');
      await setShowLibrary(false);

      final games = await GameListService.loadGamesForSystem(all);

      expect(games.map((g) => g.romname), ['Local.gba']);
    });
  });

  group('never in favourites or collections', () {
    setUp(() async {
      await seedCatalog([1, 2, 3]);
      await addLocal('Fav.gba', favorite: true);
    });

    test('favourites list holds local games only', () async {
      final games = await GameListService.loadGamesForSystem(favorites);

      expect(games.map((g) => g.romname), ['Fav.gba']);
      expect(games.any((g) => g.isRemote), isFalse);
    });

    test('a collection holds local games only', () async {
      await db.execute(
        "INSERT INTO user_collections (id, name) VALUES ('c1', 'Picks')",
      );
      await db.execute(
        "INSERT INTO user_collection_items (collection_id, rom_path) "
        "VALUES ('c1', '/roms/gba/Fav.gba')",
      );

      final games = await GameListService.loadGamesForCollection('c1');

      expect(games.map((g) => g.romname), ['Fav.gba']);
      expect(games.any((g) => g.isRemote), isFalse);
    });
  });

  group('config round-trip', () {
    test('the three unified-library settings persist and read back', () async {
      await SqliteService.saveUserConfig(
        rommShowLibrary: 1,
        rommLibraryDefaultScope: 'downloaded',
        rommCoverCacheMb: 500,
      );

      expect(await ConfigRepository.getRommShowLibrary(), isTrue);
      expect(await ConfigRepository.getRommLibraryDefaultScope(), 'downloaded');
      expect(await ConfigRepository.getRommCoverCacheMb(), 500);

      await SqliteService.saveUserConfig(rommShowLibrary: 0);
      expect(await ConfigRepository.getRommShowLibrary(), isFalse);
    });
  });
}
