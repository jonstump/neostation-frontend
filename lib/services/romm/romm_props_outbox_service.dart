import '../../repositories/romm_props_outbox_repository.dart';
import '../../repositories/romm_save_map_repository.dart';

/// The queue side of RomM play-state write-back: the one place local actions
/// (hide, unhide-all, favourite, session end) turn into an outbox row.
///
/// Purely local — no network, no provider — so the hooks can call it from the
/// game-exit path and from the context menu regardless of connectivity or of
/// which sync provider is active. The flush that drains the outbox lives with
/// the play-session flush.
///
/// Layering: this is a service, so it reads and writes through repositories
/// only ([RommPropsOutboxRepository], [RommSaveMapRepository]) and never
/// touches a datasource.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
class RommPropsOutboxService {
  const RommPropsOutboxService._();

  /// Queues a pending play-state change for one game.
  ///
  /// Two things have to be true before anything is written, and both are
  /// checked here rather than at each of the four call sites:
  ///
  /// * [pushEnabled] — the "Push play state to RomM" toggle. When it is off,
  ///   nothing is queued, so turning it on later does not suddenly replay
  ///   changes the user made while it was off.
  /// * the game has a RomM link row. An unlinked game has no ROM id to push
  ///   to, and per ADR-0013 linking it later makes no historical push, so the
  ///   row would only ever be dead weight.
  ///
  /// A null [hidden] or [favourite] means "no change to that field"; the
  /// repository folds the given fields into any row already queued.
  ///
  /// Returns true when a row was written or updated.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Outbox"
  static Future<bool> queue({
    required String romname,
    required String systemFolder,
    required String romPath,
    required bool pushEnabled,
    bool? hidden,
    bool? favourite,
    bool touchLastPlayed = false,
  }) async {
    if (!pushEnabled) return false;
    if (romname.isEmpty || systemFolder.isEmpty || romPath.isEmpty) {
      return false;
    }
    if (hidden == null && favourite == null && !touchLastPlayed) return false;

    final romId = await RommSaveMapRepository.getRommRomId(
      romname,
      systemFolder,
    );
    if (romId == null) return false; // not linked to a RomM ROM

    return RommPropsOutboxRepository.upsert(
      romPath: romPath,
      hidden: hidden,
      favourite: favourite,
      touchLastPlayed: touchLastPlayed,
    );
  }

  /// Queues the same change for several games at once — the shape
  /// "unhide all (for system)" needs, where one action touches every hidden
  /// game in a folder.
  ///
  /// Returns how many games were actually queued; unlinked ones are skipped
  /// silently, exactly as [queue] skips them one at a time.
  // Governing: ADR-0013, SPEC-0013 REQ "Props Outbox"
  static Future<int> queueMany(
    Iterable<({String romname, String systemFolder, String romPath})> games, {
    required bool pushEnabled,
    bool? hidden,
    bool? favourite,
    bool touchLastPlayed = false,
  }) async {
    if (!pushEnabled) return 0;
    var queued = 0;
    for (final game in games) {
      final ok = await queue(
        romname: game.romname,
        systemFolder: game.systemFolder,
        romPath: game.romPath,
        pushEnabled: true,
        hidden: hidden,
        favourite: favourite,
        touchLastPlayed: touchLastPlayed,
      );
      if (ok) queued++;
    }
    return queued;
  }

  /// Drops everything queued — what the push toggle calls when it is turned
  /// off, so pending rows do not outlive the consent that produced them.
  // Governing: ADR-0013, SPEC-0013 REQ "Push Toggle"
  static Future<int> discardAll() => RommPropsOutboxRepository.clear();
}
