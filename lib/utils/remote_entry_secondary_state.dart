import '../models/game_model.dart';

/// What the secondary display is told about a selected remote entry.
///
/// The second screen runs its own engine and shares nothing in memory, so
/// everything it draws is pushed as plain values: the cover file the RomM
/// cache holds (or nothing, for its placeholder), an id that keys its
/// content switcher, and the flag it renders the localized "not downloaded"
/// line from. Built without touching the game's own media paths — a remote
/// entry has none on this device, and probing them would only cost stat
/// calls to learn that.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
class RemoteEntrySecondaryState {
  /// The cached cover to draw as the screenshot slot, or null.
  final String? coverPath;

  /// The id the secondary engine keys the game content on: `romm:<rom id>`
  /// rather than a rom path, since the entry has none.
  final String gameId;

  const RemoteEntrySecondaryState({
    required this.coverPath,
    required this.gameId,
  });

  @override
  bool operator ==(Object other) =>
      other is RemoteEntrySecondaryState &&
      other.coverPath == coverPath &&
      other.gameId == gameId;

  @override
  int get hashCode => Object.hash(coverPath, gameId);
}

/// The push for [game], or null when it is a local game (which takes the
/// media path). [cachedCoverPath] is what the cover cache has for its rom
/// id; [exists] says whether that file is really there, since the cache's
/// index can outlive an evicted file by a frame.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
RemoteEntrySecondaryState? remoteEntrySecondaryStateFor(
  GameModel game, {
  required String? cachedCoverPath,
  required bool Function(String path) exists,
}) {
  if (!game.isRemote) return null;
  final cover = cachedCoverPath != null && cachedCoverPath.isNotEmpty
      ? (exists(cachedCoverPath) ? cachedCoverPath : null)
      : null;
  return RemoteEntrySecondaryState(
    coverPath: cover,
    gameId: 'romm:${game.rommRomId}',
  );
}
