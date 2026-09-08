import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:neostation/constants/system_folder_names.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/library_scope.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/collections_provider.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/providers/sqlite_database_provider.dart';
import 'package:neostation/utils/system_sort.dart';
import 'package:provider/provider.dart';

/// The glyph a system card wears when the system exists only on the RomM
/// server — the same cloud family the remote game entries use.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only Systems"
const IconData kRommRemoteOnlyGlyph = Symbols.cloud_rounded;

/// Builds the systems carousel/grid model.
///
/// [collectionsProvider] is optional only so the existing call sites keep
/// compiling: when it is omitted the provider is resolved from [context]
/// without listening, which is what the carousel needs (it calls this from
/// event handlers, where a listening read throws). A host that wants the
/// Collections card's count to repaint the instant a collection is created
/// should watch [CollectionsProvider] itself and pass it in.
///
/// [rommProvider] follows the same rule. With "Show RomM library in my
/// systems" on, the systems the server has ROMs for but the device has no
/// folder for are slotted in among the detected ones, under the configured
/// system sort, marked with [kRommRemoteOnlyGlyph]. They are left out while
/// the library's opening scope is `downloaded` — the configured default, or
/// forced by an unreachable server — because that scope hides everything
/// that is not on the device.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only Systems"
List<SystemInfo> buildSystemsList({
  required BuildContext context,
  required SqliteConfigProvider configProvider,
  required SqliteDatabaseProvider dbProvider,
  required FileProvider fileProvider,
  CollectionsProvider? collectionsProvider,
  RommProvider? rommProvider,
}) {
  final collections =
      collectionsProvider ??
      Provider.of<CollectionsProvider>(context, listen: false);
  final collectionGames = collections.totalGameCount;
  const recentCount = 1;
  final hideRecent = configProvider.config.hideRecentCard;
  final recentDbGames = hideRecent
      ? dbProvider.getRecentlyPlayedGames(0)
      : dbProvider.getRecentlyPlayedGames(recentCount);

  final recentGames = recentDbGames
      .map((dbGame) => GameModel.fromDatabaseModel(dbGame))
      .map((game) => SystemInfo.fromGameModel(game, fileProvider))
      .toList();

  final hiddenFolders = configProvider.hiddenSystemFolders;
  final totalFavorites = dbProvider.totalFavorites;

  final visibleDetected = configProvider.detectedSystems
      .where((s) => !hiddenFolders.contains(s.folderName))
      .where(
        (s) =>
            !(s.folderName == SystemFolderNames.favorites &&
                totalFavorites == 0),
      )
      .toList();

  final remoteOnly = remoteOnlySystems(
    context: context,
    configProvider: configProvider,
    rommProvider: rommProvider,
    detected: visibleDetected,
  );

  // One ordered list of models, then the cards. The detected list already
  // carries the configured order; re-sorting the union with the same
  // comparator, tie-broken on input position, keeps it stable and slots the
  // remote-only systems in where the sort says they belong.
  final ordered = <SystemModel>[...visibleDetected, ...remoteOnly.keys];
  if (remoteOnly.isNotEmpty) {
    final sortBy = configProvider.config.systemSortBy;
    final ascending = configProvider.config.systemSortOrder == 'asc';
    final position = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};
    ordered.sort((a, b) {
      final c = compareSystemsForCarousel(
        a,
        b,
        sortBy: sortBy,
        ascending: ascending,
      );
      return c != 0 ? c : position[a]!.compareTo(position[b]!);
    });
  }

  final systems = ordered.map((system) {
    final info = SystemInfo.fromSystemMetadata(system);

    final remoteCount = remoteOnly[system];
    if (remoteCount != null) {
      return info.copyWith(
        numOfRoms: remoteCount,
        totalStorage: AppLocale.gamesCount
            .getString(context)
            .replaceFirst('{count}', remoteCount.toString()),
        badgeIcon: kRommRemoteOnlyGlyph,
        badgeLabel: AppLocale.rommRemoteOnlySystemLabel.getString(context),
      );
    }

    if (system.folderName == 'all') {
      return info.copyWith(
        numOfRoms: configProvider.totalGames,
        totalStorage: AppLocale.gamesCount
            .getString(context)
            .replaceFirst('{count}', configProvider.totalGames.toString()),
      );
    } else if (system.folderName == 'android') {
      return info.copyWith(
        totalStorage: AppLocale.appsCount
            .getString(context)
            .replaceFirst('{count}', system.romCount.toString()),
      );
    } else if (system.folderName == SystemFolderNames.favorites) {
      return info.copyWith(
        numOfRoms: totalFavorites,
        totalStorage: AppLocale.gamesCount
            .getString(context)
            .replaceFirst('{count}', totalFavorites.toString()),
      );
    } else if (system.folderName == SystemFolderNames.collections) {
      // The count is of the games the collections hold, not of the
      // collections themselves. The card sits in a row of system cards
      // that all answer "how many games are in here", and it is the only
      // one whose own contents are a level further down, so counting the
      // containers would make it the odd one out. It sums the
      // per-collection counts rather than counting distinct games, so it
      // agrees with the numbers the browser lists one level down — see
      // CollectionsProvider.totalGameCount, which carries the tradeoff.
      return info.copyWith(numOfRoms: collectionGames);
    }
    return info;
  });

  return [...recentGames, ...systems];
}

/// The systems the RomM catalog holds rows for that are not among
/// [detected], each with its catalogued ROM count — empty unless the unified
/// library is on, the server is connected, and the opening scope is `all`.
///
/// A catalog folder counts as detected when it is any detected system's
/// primary folder or one of its aliases, so a system the device has under an
/// ES-DE spelling is not offered twice. Hidden systems stay hidden. The
/// model comes from the provider's full systems list (every `app_systems`
/// row), with the catalog count in place of the local ROM count.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only Systems"
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope"
Map<SystemModel, int> remoteOnlySystems({
  required BuildContext context,
  required SqliteConfigProvider configProvider,
  required RommProvider? rommProvider,
  required List<SystemModel> detected,
}) {
  final config = configProvider.config;
  if (!config.rommShowLibrary) return const {};
  final romm =
      rommProvider ?? Provider.of<RommProvider>(context, listen: false);
  if (!romm.isConnected) return const {};
  final scope = LibraryScope.initial(
    configured: config.rommLibraryDefaultScope,
    offline: romm.reachability == RommReachability.offline,
  );
  if (scope != LibraryScope.all) return const {};

  final counts = romm.catalogSystemCounts;
  if (counts.isEmpty) return const {};

  final detectedFolders = <String>{
    for (final s in configProvider.detectedSystems) ...[
      s.folderName,
      ...s.folders,
    ],
  }.map((f) => f.toLowerCase()).toSet();
  final hidden = configProvider.hiddenSystemFolders
      .map((f) => f.toLowerCase())
      .toSet();

  final result = <SystemModel, int>{};
  for (final entry in counts.entries) {
    final folder = entry.key;
    if (entry.value <= 0) continue;
    if (detectedFolders.contains(folder.toLowerCase())) continue;
    final model = systemForFolder(configProvider, folder);
    if (model == null) continue;
    if (hidden.contains(model.folderName.toLowerCase())) continue;
    if (model.folderName == 'android' || model.folderName == 'music') continue;
    result[model.copyWith(romCount: entry.value)] = entry.value;
  }
  return result;
}

/// The [SystemModel] behind a system card's folder name.
///
/// Detected systems first — the list every card came from until the RomM
/// catalog added remote-only ones — then the provider's full systems list,
/// which is where a remote-only system lives. Matches the primary folder or
/// an alias, case-insensitively, the way the scanner files ROMs.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only Systems"
SystemModel? systemForFolder(
  SqliteConfigProvider configProvider,
  String? folderName,
) {
  if (folderName == null || folderName.isEmpty) return null;
  final wanted = folderName.toLowerCase();
  bool matches(SystemModel s) =>
      s.folderName.toLowerCase() == wanted ||
      s.folders.any((f) => f.toLowerCase() == wanted);
  for (final s in configProvider.detectedSystems) {
    if (matches(s)) return s;
  }
  for (final s in configProvider.availableSystems) {
    if (matches(s)) return s;
  }
  return null;
}
