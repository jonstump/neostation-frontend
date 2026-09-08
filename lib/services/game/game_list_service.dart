import 'package:path/path.dart' as path;
import 'package:neostation/services/logger_service.dart';
import '../../models/game_model.dart';
import '../../models/database_game_model.dart';
import '../../models/romm_catalog_row.dart';
import '../../models/system_model.dart';
import '../../repositories/config_repository.dart';
import '../../repositories/game_repository.dart';
import '../../repositories/collection_repository.dart';
import '../../repositories/romm_catalog_repository.dart';
import '../../repositories/romm_repository.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../../repositories/system_repository.dart';
import '../../constants/system_folder_names.dart';
import '../../utils/romm_local_matcher.dart';

/// The per-system naming preferences a list applies to every entry it shows,
/// local or remote, read once per system per load.
typedef _NameSettings = ({
  bool preferFileName,
  bool hideExtension,
  bool hideParentheses,
  bool hideBrackets,
  Set<String> validExtensions,
});

/// Loads game lists/details and resolves their display names.
///
/// Owns the read side of the game catalogue: pulling [DatabaseGameModel]s from
/// the repositories, applying per-system naming preferences (extension/tag
/// stripping, scraped-title coalescing) via [_resolveListDisplayName], and
/// mapping them to UI [GameModel]s. Also the small pure list utilities
/// ([groupGamesByGenre]/[getFavoriteGames]/[getRecentlyPlayedGames]). Extracted
/// verbatim from [GameService], which now delegates its list/detail methods
/// here. Stateless aside from the shared logger and the name-cleanup regexes.
class GameListService {
  GameListService._();

  static final _log = LoggerService.instance;

  static final RegExp _parenthesesRegex = RegExp(r'\([^)]*\)');
  static final RegExp _bracketsRegex = RegExp(r'\[[^\]]*\]');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  static bool _hasScreenscraperRealName(DatabaseGameModel dbGame) {
    final t = dbGame.screenscraperRealName?.trim();
    return t != null && t.isNotEmpty;
  }

  /// Sanitizes a filename for display in the UI based on user preferences.
  ///
  /// Optionally strips extensions, regional tags (parentheses), and technical
  /// tags (brackets).
  static String _formatListNameFromFilename(
    String filename,
    Set<String> validExtensionsSet, {
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
  }) {
    String name = filename;
    if (hideExtension) {
      final extWithDot = path.extension(name).toLowerCase();
      if (extWithDot.isNotEmpty) {
        final ext = extWithDot.substring(1);
        if (validExtensionsSet.contains(ext)) {
          name = name.substring(0, name.length - extWithDot.length);
        }
      }
    }
    if (hideParentheses) {
      name = name.replaceAll(_parenthesesRegex, '');
    }
    if (hideBrackets) {
      name = name.replaceAll(_bracketsRegex, '');
    }
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    if (!hideExtension) {
      name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    }
    return name;
  }

  static String _formatListNameFromScrapedTitle(String rawTitle) {
    String name = rawTitle.trim();
    name = name.replaceAll(_whitespaceRegex, ' ').trim();
    name = name.replaceAll(RegExp(r'\s+(?=\.[^.]+$)'), '');
    return name;
  }

  /// Resolves the optimal display name for a game considering scraped metadata
  /// and user-defined naming conventions.
  static ({String name, bool showRomFileNameSubtitle}) _resolveListDisplayName({
    required DatabaseGameModel dbGame,
    required bool preferFileName,
    required bool hideExtension,
    required bool hideParentheses,
    required bool hideBrackets,
    required Set<String> validExtensionsSet,
  }) {
    final filename = dbGame.filename;
    final scraped = _hasScreenscraperRealName(dbGame);
    final coalesced = dbGame.realName ?? dbGame.titleName ?? filename;

    if (preferFileName) {
      return (
        name: _formatListNameFromFilename(
          filename,
          validExtensionsSet,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
        ),
        showRomFileNameSubtitle: false,
      );
    }
    if (scraped) {
      return (
        name: _formatListNameFromScrapedTitle(coalesced),
        showRomFileNameSubtitle: true,
      );
    }
    if (coalesced != filename) {
      return (name: coalesced, showRomFileNameSubtitle: false);
    }
    return (
      name: _formatListNameFromFilename(
        filename,
        validExtensionsSet,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
      ),
      showRomFileNameSubtitle: false,
    );
  }

  /// Retrieves a list of games for a specific system, applying metadata formatting.
  ///
  /// If the 'all' system is requested, it aggregates games across all supported
  /// emulation systems (excluding Android and Music).
  static Future<List<GameModel>> loadGamesForSystem(SystemModel system) async {
    try {
      final collectionId = SystemFolderNames.collectionIdOf(system.folderName);
      if (collectionId != null) {
        return await loadGamesForCollection(collectionId);
      }

      if (system.folderName == SystemFolderNames.favorites) {
        return await _loadFavoriteGames();
      }

      if (system.folderName == SystemFolderNames.all) {
        // Hidden games stay in [allGames]: a hidden local copy still hides
        // its catalog row, it is only the list that must not show it.
        final allGames = await GameRepository.getAllGames();
        final databaseGames = allGames
            .where(
              (dbGame) =>
                  !dbGame.isHidden &&
                  dbGame.systemFolderName != 'android' &&
                  dbGame.systemFolderName != 'music',
            )
            .toList();

        final games = await _mapAggregateGames(databaseGames);
        // The aggregate includes the catalog under the same rule as a single
        // system: one pass per system that has rows, hidden behind the local
        // games of that system.
        // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
        final serverUrl = await _remoteLibraryServer();
        if (serverUrl != null) {
          final remote = await _remoteEntriesForAllSystems(
            serverUrl: serverUrl,
            allGames: allGames,
          );
          if (remote.isNotEmpty) {
            games.addAll(remote);
            _sortLibrary(games);
          }
        }
        return games;
      }

      if (system.id == null) {
        return [];
      }

      final allSystemGames = await GameRepository.getGamesBySystem(system.id!);
      final databaseGames = allSystemGames
          .where((dbGame) => !dbGame.isHidden)
          .toList();
      final nameSettings = await _nameSettingsFor(system.id!);
      final preferFileName = nameSettings.preferFileName;
      final hideExtension = nameSettings.hideExtension;
      final hideParentheses = nameSettings.hideParentheses;
      final hideBrackets = nameSettings.hideBrackets;
      final validExtensionsSet = nameSettings.validExtensions;

      final games = databaseGames.map((dbGame) {
        final resolved = _resolveListDisplayName(
          dbGame: dbGame,
          preferFileName: preferFileName,
          hideExtension: hideExtension,
          hideParentheses: hideParentheses,
          hideBrackets: hideBrackets,
          validExtensionsSet: validExtensionsSet,
        );

        return GameModel(
          romname: dbGame.filename,
          realname: dbGame.realName ?? dbGame.filename,
          name: resolved.name,
          showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
          descriptions: dbGame.descriptions,
          year: dbGame.year ?? '',
          developer: dbGame.developer ?? '',
          publisher: dbGame.publisher ?? '',
          genre: dbGame.genre ?? '',
          players: dbGame.players ?? '',
          rating: dbGame.rating ?? 0.0,
          isFavorite: dbGame.isFavorite,
          lastPlayed: dbGame.lastPlayed,
          playTime: dbGame.playTime,
          romPath: dbGame.romPath,
          emulatorName: dbGame.emulatorName,
          coreName: dbGame.coreName,
          raHash: dbGame.raHash,
          idRa: dbGame.idRa,
          systemRaId: dbGame.systemRaId,
          raNumAchievements: dbGame.raNumAchievements,
          systemId: dbGame.appSystemId,
          systemFolderName: system.folderName,
          cloudSyncEnabled: dbGame.cloudSyncEnabled,
          titleId: dbGame.titleId,
          titleName: dbGame.titleName,
        );
      }).toList();

      // The unified library: every catalogued ROM of this system that no
      // local game accounts for, appended as a remote entry and sorted in
      // with the local rule. Off (or no server) leaves the list exactly as
      // it was — the catalog stays on disk either way.
      // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
      final serverUrl = await _remoteLibraryServer();
      if (serverUrl != null &&
          system.folderName != 'android' &&
          system.folderName != 'music') {
        final remote = await _remoteEntriesFor(
          system: system,
          serverUrl: serverUrl,
          localGames: allSystemGames,
          index: await RommSaveMapRepository.getRomIdIndex(),
          nameSettings: nameSettings,
        );
        if (remote.isNotEmpty) {
          games.addAll(remote);
          _sortLibrary(games);
        }
      }

      return games;
    } catch (e) {
      _log.e('Error loading games for ${system.realName}: $e');
      return [];
    }
  }

  /// The server whose catalog the lists merge, or null when the feature is
  /// off or no RomM server is configured. Two repository reads, once per
  /// load; the toggle is read live so turning it off hides remote entries on
  /// the very next load without deleting anything.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Settings And Actions"
  static Future<String?> _remoteLibraryServer() async {
    if (!await ConfigRepository.getRommShowLibrary()) return null;
    final serverUrl = await RommRepository.getServerUrl();
    return serverUrl.isEmpty ? null : serverUrl;
  }

  /// Reads one system's naming preferences and valid extensions.
  static Future<_NameSettings> _nameSettingsFor(String systemId) async {
    final settings = await SystemRepository.getSystemSettings(systemId);
    final extensions = await SystemRepository.getExtensionsForSystem(systemId);
    return (
      preferFileName: (settings['prefer_file_name'] ?? 0) == 1,
      hideExtension: (settings['hide_extension'] ?? 1) == 1,
      hideParentheses: (settings['hide_parentheses'] ?? 1) == 1,
      hideBrackets: (settings['hide_brackets'] ?? 1) == 1,
      validExtensions: extensions.map((e) => e.toLowerCase()).toSet(),
    );
  }

  /// The catalog rows of [system] that no local game accounts for, as remote
  /// entries.
  ///
  /// A row is hidden behind a local game when the link map points any local
  /// game of the system at its rom id (a download, a manual pick, or the
  /// connect-time pass wrote the row), or when a local filename equals one
  /// of the names a download of the row would land under (the filename
  /// equivalence rule, SPEC-0001). [localGames] is every game of the system
  /// *including* hidden ones: hiding a game from the lists must not resurface
  /// the same game as a downloadable copy.
  ///
  /// One catalog read per folder the system answers to, then a synchronous
  /// merge over the in-memory sets — the rule SPEC-0019 "Concurrency Safety"
  /// asks for. Rows are read under the primary folder and every alias so a
  /// catalog written when the system's primary folder was spelt differently
  /// still shows.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Filename Equivalence Rule"
  static Future<List<GameModel>> _remoteEntriesFor({
    required SystemModel system,
    required String serverUrl,
    required List<DatabaseGameModel> localGames,
    required RommRomIdIndex index,
    required _NameSettings nameSettings,
  }) async {
    final folders = <String>{
      system.folderName,
      ...system.folders,
    }.where((f) => f.isNotEmpty).toList();

    final rowsById = <int, RommCatalogRow>{};
    for (final folder in folders) {
      final rows = await RommCatalogRepository.rowsForSystem(
        serverUrl: serverUrl,
        systemFolder: folder,
      );
      for (final row in rows) {
        rowsById.putIfAbsent(row.rommRomId, () => row);
      }
    }
    if (rowsById.isEmpty) return const [];

    final linkedIds = <int>{};
    final localNames = <String>{};
    for (final game in localGames) {
      localNames.add(RommLocalMatcher.normalizeName(game.filename));
      final ownFolder = game.systemFolderName;
      for (final folder in {
        ...folders,
        if (ownFolder != null && ownFolder.isNotEmpty) ownFolder,
      }) {
        final id = index.lookup(game.filename, folder);
        if (id != null) linkedIds.add(id);
      }
    }

    final remote = <GameModel>[];
    for (final row in rowsById.values) {
      if (linkedIds.contains(row.rommRomId)) continue;
      final onDisk = row.localCandidateNames.any(
        (name) => localNames.contains(RommLocalMatcher.normalizeName(name)),
      );
      if (onDisk) continue;
      final resolved = _resolveRemoteDisplayName(row, nameSettings);
      remote.add(
        GameModel.fromCatalogRow(
          row,
          system,
          displayName: resolved.name,
          showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        ),
      );
    }
    return remote;
  }

  /// Remote entries for every system the catalog holds rows for — the
  /// aggregate's share of the merge. Systems are visited once each by id, so
  /// a system catalogued under two of its folder spellings is not appended
  /// twice, and the per-system naming settings are read once per system.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
  static Future<List<GameModel>> _remoteEntriesForAllSystems({
    required String serverUrl,
    required List<DatabaseGameModel> allGames,
  }) async {
    final folders = await RommCatalogRepository.systemsWithRows(serverUrl);
    if (folders.isEmpty) return const [];

    final index = await RommSaveMapRepository.getRomIdIndex();
    final visited = <String>{};
    final remote = <GameModel>[];
    for (final folder in folders) {
      final system = await SystemRepository.getSystemByFolderName(folder);
      final systemId = system?.id;
      if (system == null || systemId == null) continue;
      if (system.folderName == 'android' || system.folderName == 'music') {
        continue;
      }
      if (!visited.add(systemId)) continue;

      remote.addAll(
        await _remoteEntriesFor(
          system: system,
          serverUrl: serverUrl,
          localGames: allGames
              .where((g) => g.appSystemId == systemId)
              .toList(growable: false),
          index: index,
          nameSettings: await _nameSettingsFor(systemId),
        ),
      );
    }
    return remote;
  }

  /// The display name for a catalog row, under the same preferences a local
  /// game of the system gets: the filename (formatted) when the user prefers
  /// filenames, otherwise the server's display name — which stands in for a
  /// scraped title, and like one shows the filename underneath — falling
  /// back to the formatted filename when the server has no better name.
  static ({String name, bool showRomFileNameSubtitle})
  _resolveRemoteDisplayName(RommCatalogRow row, _NameSettings settings) {
    String fromFilename() => _formatListNameFromFilename(
      row.fsName,
      settings.validExtensions,
      hideExtension: settings.hideExtension,
      hideParentheses: settings.hideParentheses,
      hideBrackets: settings.hideBrackets,
    );
    if (settings.preferFileName) {
      return (name: fromFilename(), showRomFileNameSubtitle: false);
    }
    final serverName = row.name.trim();
    if (serverName.isNotEmpty && serverName != row.fsName) {
      return (
        name: _formatListNameFromScrapedTitle(serverName),
        showRomFileNameSubtitle: true,
      );
    }
    return (name: fromFilename(), showRomFileNameSubtitle: false);
  }

  /// Orders a merged list the way the repository orders a local one:
  /// favourites first, then by the name the row sorts under (the scraped
  /// name when there is one, else the filename), case-insensitively.
  ///
  /// Only called once remote entries have been appended — a list with none
  /// keeps the repository's order untouched.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
  static void _sortLibrary(List<GameModel> games) {
    games.sort((a, b) {
      final favA = a.isFavorite == true ? 0 : 1;
      final favB = b.isFavorite == true ? 0 : 1;
      if (favA != favB) return favA.compareTo(favB);
      final byName = a.realname.toLowerCase().compareTo(
        b.realname.toLowerCase(),
      );
      if (byName != 0) return byName;
      return a.romname.toLowerCase().compareTo(b.romname.toLowerCase());
    });
  }

  static Future<List<GameModel>> _loadFavoriteGames() async {
    final databaseGames = (await GameRepository.getFavoriteGames())
        .where((dbGame) => !dbGame.isHidden)
        .toList();

    return _mapAggregateGames(databaseGames);
  }

  /// Loads the games of one collection, in the same display-ready shape as the
  /// favourites list.
  ///
  /// The repository query already joins `app_systems`, so every game carries
  /// its `systemFolderName`/`systemRealName` — the aggregate-view code path
  /// (launch, details card, secondary display) branches on those being present.
  /// Hidden ROMs are filtered here rather than in SQL, exactly as
  /// [_loadFavoriteGames] does.
  static Future<List<GameModel>> loadGamesForCollection(
    String collectionId,
  ) async {
    try {
      final databaseGames = (await CollectionRepository.getGamesInCollection(
        collectionId,
      )).where((dbGame) => !dbGame.isHidden).toList();

      return await _mapAggregateGames(databaseGames);
    } catch (e) {
      _log.e('Error loading games for collection $collectionId: $e');
      return [];
    }
  }

  /// Maps games drawn from several systems at once into display-ready
  /// [GameModel]s.
  ///
  /// Shared by the `all` view, favourites and collections: each of those pulls
  /// rows spanning many systems, so the per-system naming settings and valid
  /// extensions are prefetched once per distinct system rather than once per
  /// game. Callers filter hidden ROMs before handing the list over.
  static Future<List<GameModel>> _mapAggregateGames(
    List<DatabaseGameModel> databaseGames,
  ) async {
    final systemIds = databaseGames
        .map((g) => g.appSystemId)
        .whereType<String>()
        .toSet();

    final settingsBySystem = <String, Map<String, dynamic>>{};
    final extensionsBySystem = <String, Set<String>>{};
    for (final sid in systemIds) {
      settingsBySystem[sid] = await SystemRepository.getSystemSettings(sid);
      final exts = await SystemRepository.getExtensionsForSystem(sid);
      extensionsBySystem[sid] = exts.map((e) => e.toLowerCase()).toSet();
    }

    return databaseGames.map((dbGame) {
      final sid = dbGame.appSystemId ?? '';
      final settings = settingsBySystem[sid] ?? {};
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final extSet = extensionsBySystem[sid] ?? {};

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: extSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
        year: dbGame.year ?? '',
        developer: dbGame.developer ?? '',
        publisher: dbGame.publisher ?? '',
        genre: dbGame.genre ?? '',
        players: dbGame.players ?? '',
        rating: dbGame.rating ?? 0.0,
        isFavorite: dbGame.isFavorite,
        lastPlayed: dbGame.lastPlayed,
        playTime: dbGame.playTime,
        romPath: dbGame.romPath,
        emulatorName: dbGame.emulatorName,
        coreName: dbGame.coreName,
        raHash: dbGame.raHash,
        idRa: dbGame.idRa,
        systemRaId: dbGame.systemRaId,
        raNumAchievements: dbGame.raNumAchievements,
        systemId: dbGame.appSystemId,
        systemFolderName: dbGame.systemFolderName,
        systemRealName: dbGame.systemRealName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
    }).toList();
  }

  /// Fetches detailed metadata for a specific game instance.
  static Future<GameModel?> getGameDetails(
    SystemModel system,
    String romName,
  ) async {
    try {
      if (system.id == null) return null;

      final dbGame = await GameRepository.getSingleGame(system.id!, romName);
      if (dbGame == null) return null;

      final settings = await SystemRepository.getSystemSettings(system.id!);
      final preferFileName = (settings['prefer_file_name'] ?? 0) == 1;
      final hideExtension = (settings['hide_extension'] ?? 1) == 1;
      final hideParentheses = (settings['hide_parentheses'] ?? 1) == 1;
      final hideBrackets = (settings['hide_brackets'] ?? 1) == 1;
      final validExtensions = await SystemRepository.getExtensionsForSystem(
        system.id!,
      );
      final validExtensionsSet = validExtensions
          .map((e) => e.toLowerCase())
          .toSet();

      final resolved = _resolveListDisplayName(
        dbGame: dbGame,
        preferFileName: preferFileName,
        hideExtension: hideExtension,
        hideParentheses: hideParentheses,
        hideBrackets: hideBrackets,
        validExtensionsSet: validExtensionsSet,
      );

      return GameModel(
        romname: dbGame.filename,
        realname: dbGame.realName ?? dbGame.filename,
        name: resolved.name,
        showRomFileNameSubtitle: resolved.showRomFileNameSubtitle,
        descriptions: dbGame.descriptions,
        year: dbGame.year ?? '',
        developer: dbGame.developer ?? '',
        publisher: dbGame.publisher ?? '',
        genre: dbGame.genre ?? '',
        players: dbGame.players ?? '',
        rating: dbGame.rating ?? 0.0,
        isFavorite: dbGame.isFavorite,
        lastPlayed: dbGame.lastPlayed,
        playTime: dbGame.playTime,
        romPath: dbGame.romPath,
        emulatorName: dbGame.emulatorName,
        coreName: dbGame.coreName,
        raHash: dbGame.raHash,
        idRa: dbGame.idRa,
        systemRaId: dbGame.systemRaId,
        raNumAchievements: dbGame.raNumAchievements,
        systemId: dbGame.appSystemId,
        systemFolderName: system.folderName,
        cloudSyncEnabled: dbGame.cloudSyncEnabled,
        titleId: dbGame.titleId,
        titleName: dbGame.titleName,
      );
    } catch (e) {
      _log.e('Error loading game details for $romName: $e');
      return null;
    }
  }

  /// Groups a list of games by their genre metadata.
  static Map<String, List<GameModel>> groupGamesByGenre(List<GameModel> games) {
    Map<String, List<GameModel>> grouped = {};

    for (var game in games) {
      final genre = game.genre.isEmpty ? 'Unknown' : game.genre;
      if (!grouped.containsKey(genre)) {
        grouped[genre] = [];
      }
      grouped[genre]!.add(game);
    }

    return grouped;
  }

  /// Filters a list of games to return only those marked as favorites.
  static List<GameModel> getFavoriteGames(List<GameModel> games) {
    return games.where((game) => game.isFavorite ?? false).toList();
  }

  /// Filters and sorts a list of games to return the 10 most recently played instances.
  static List<GameModel> getRecentlyPlayedGames(List<GameModel> games) {
    final playedGames = games.where((game) => game.lastPlayed != null).toList();
    playedGames.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return playedGames.take(10).toList();
  }
}
