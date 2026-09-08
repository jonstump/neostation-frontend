import '../../models/game_model.dart';
import '../../repositories/game_repository.dart';
import '../logger_service.dart';
import '../romm/romm_props_outbox_service.dart';

/// Game catalogue mutations and aggregate stats.
///
/// Owns the favourite toggle, the "recently played" record write, and the
/// per-list statistics computation ([getGameStats]) — the read/write of the
/// game catalogue that is independent of any active launch/session. Extracted
/// verbatim from [GameService], which now delegates these methods here.
/// Stateless.
class FavoritesService {
  FavoritesService._();

  static final _log = LoggerService.instance;

  /// Toggles the favorite status of a game in the persistent database.
  ///
  /// The local write comes first and is never delayed by what follows: once
  /// the row holds its new value, the change is queued for RomM when the
  /// push toggle is on and the game is linked — every favourite entry point
  /// (context menu, favourites reorder) funnels through here, so this is the
  /// one hook.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
  static Future<void> toggleFavorite(GameModel game) async {
    final romPath = game.romPath;
    if (romPath == null) return;
    final isFavorite = await GameRepository.toggleRomFavoriteByPath(romPath);
    if (isFavorite == null) return;
    final systemFolder = game.systemFolderName ?? '';
    if (systemFolder.isEmpty) return;
    try {
      await RommPropsOutboxService.queue(
        romname: game.romname,
        systemFolder: systemFolder,
        romPath: romPath,
        pushEnabled: await RommPropsOutboxService.pushEnabled(),
        favourite: isFavorite,
      );
    } catch (e) {
      _log.e('Failed to queue a RomM favourite push for ${game.romname}: $e');
    }
  }

  /// Records a new play instance for a game in the persistent database.
  static Future<void> recordGamePlayed(GameModel game) async {
    if (game.romPath == null) return;
    await GameRepository.recordRomPlayedByPath(game.romPath!);
  }

  /// Computes aggregate statistics for a list of games.
  static Map<String, dynamic> getGameStats(List<GameModel> games) {
    if (games.isEmpty) {
      return {
        'total': 0,
        'genres': 0,
        'developers': 0,
        'favorites': 0,
        'played': 0,
        'averageRating': 0.0,
      };
    }

    final genres = games.map((g) => g.genre).where((g) => g.isNotEmpty).toSet();
    final developers = games
        .map((g) => g.developer)
        .where((d) => d.isNotEmpty)
        .toSet();
    final favorites = games.where((g) => g.isFavorite == true).length;
    final played = games.where((g) => g.lastPlayed != null).length;

    final ratingsWithValue = games.map((g) => g.rating).where((r) => r > 0);
    double averageRating = 0.0;
    if (ratingsWithValue.isNotEmpty) {
      averageRating =
          ratingsWithValue.reduce((a, b) => a + b) / ratingsWithValue.length;
    }

    return {
      'total': games.length,
      'genres': genres.length,
      'developers': developers.length,
      'favorites': favorites,
      'played': played,
      'averageRating': averageRating,
    };
  }
}
