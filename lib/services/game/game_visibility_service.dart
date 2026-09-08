import '../../repositories/game_repository.dart';
import '../../repositories/system_repository.dart';
import '../logger_service.dart';
import '../romm/romm_props_outbox_service.dart';

/// Hiding and restoring games, with the RomM write-back hook in one place.
///
/// The manage tab's "Hide game", the system dialog's per-game "Unhide" and
/// its "Unhide all" used to call [GameRepository] straight from the widget,
/// which left nowhere for a side effect to live. This service is that
/// place: it performs the local write first — the user's action never waits
/// on anything else — and then queues the change for RomM when the push
/// toggle is on and the game is linked. Stateless.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
class GameVisibilityService {
  GameVisibilityService._();

  static final _log = LoggerService.instance;

  /// Hides or restores one game.
  ///
  /// [romPath] is what the outbox is keyed by; callers that already hold the
  /// game's row pass it, and the fallback resolves it from the system folder
  /// and filename so a caller with only those two still queues the push. A
  /// game that cannot be resolved is hidden locally all the same — the local
  /// write is the user's action, the push is a courtesy.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
  static Future<void> setHidden({
    required String systemFolder,
    required String romname,
    required bool hidden,
    String? romPath,
  }) async {
    await GameRepository.setGameHidden(systemFolder, romname, hidden);
    try {
      final path = romPath ?? await _resolveRomPath(systemFolder, romname);
      if (path == null || path.isEmpty) return;
      await RommPropsOutboxService.queue(
        romname: romname,
        systemFolder: systemFolder,
        romPath: path,
        pushEnabled: await RommPropsOutboxService.pushEnabled(),
        hidden: hidden,
      );
    } catch (e) {
      _log.e('Failed to queue a RomM hidden push for $romname: $e');
    }
  }

  /// Restores every hidden game of [systemId], or of the whole library when
  /// [systemId] is null, and queues `hidden = false` for each one that is
  /// linked to RomM.
  ///
  /// The hidden set is read *before* the bulk update — afterwards nothing
  /// is hidden and there would be nothing to queue. Returns how many games
  /// were restored locally.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
  static Future<int> unhideAll({String? systemId}) async {
    final hiddenGames = await GameRepository.getHiddenGames(systemId: systemId);
    if (systemId == null) {
      await GameRepository.unhideAllGames();
    } else {
      await GameRepository.unhideAllGamesForSystem(systemId);
    }
    try {
      await RommPropsOutboxService.queueMany(
        [
          for (final game in hiddenGames)
            if (game.romPath.isNotEmpty &&
                (game.systemFolderName ?? '').isNotEmpty)
              (
                romname: game.filename,
                systemFolder: game.systemFolderName!,
                romPath: game.romPath,
              ),
        ],
        pushEnabled: await RommPropsOutboxService.pushEnabled(),
        hidden: false,
      );
    } catch (e) {
      _log.e('Failed to queue RomM hidden pushes after unhide all: $e');
    }
    return hiddenGames.length;
  }

  static Future<String?> _resolveRomPath(
    String systemFolder,
    String romname,
  ) async {
    final system = await SystemRepository.getSystemByFolderName(systemFolder);
    final systemId = system?.id;
    if (systemId == null) return null;
    final game = await GameRepository.getSingleGame(systemId, romname);
    return game?.romPath;
  }
}
