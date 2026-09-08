import '../../repositories/config_repository.dart';
import '../../repositories/romm_props_outbox_repository.dart';
import '../../repositories/romm_save_map_repository.dart';
import '../logger_service.dart';
import '../romm_service.dart';

/// What one [RommPropsOutboxService.flush] did, for the caller's log line.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Flush"
typedef RommPropsFlushSummary = ({
  /// Rows the server confirmed and that were deleted.
  int pushed,

  /// Rows dropped without a push: the ROM is gone from the server (404), the
  /// game is gone from the library, or the feature is gated on this server.
  int dropped,

  /// Rows left in place for the next flush.
  int kept,
});

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

  static final _log = LoggerService.instance;

  /// The "Push play state to RomM" toggle, read from the database so the
  /// hooks — which run off the game-exit path and from the context menu,
  /// outside any provider — see the value the moment it is flipped.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Push Toggle"
  static Future<bool> pushEnabled() => ConfigRepository.getRommPushPlayState();

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

  /// Pushes every queued row to RomM through [service], oldest change first.
  ///
  /// Per row: one props call ([RommService.updateRomProps]) when `hidden` or
  /// `touch_last_played` is set, and one favourites call
  /// ([RommService.addFavourite] / [RommService.removeFavourite]) when
  /// `favourite` is set. The row is deleted once every call it needed has
  /// been confirmed, and kept — with one warning — when any of them failed,
  /// so the next flush retries it. Both calls are idempotent on the server,
  /// so a retry after a partial success costs a duplicate request and nothing
  /// else.
  ///
  /// Rows that can never succeed are dropped rather than retried forever:
  /// a 404 (RomM no longer has the ROM), a path the library no longer holds or
  /// that lost its link row, and a feature the service gates on this
  /// connection (server below 4.9.0, or a scope the account does not hold —
  /// ADR-0013 says such changes are not pushed at all).
  ///
  /// Stops early — leaving the remaining rows for next time — when
  /// [isConnected] turns false between rows, and when a call fails without a
  /// status (the server is unreachable, so every later row would fail the
  /// same way).
  ///
  /// [favouritesCollectionName] is the localized "Favourites" the collection
  /// is created with on first use; resolved by the caller because this layer
  /// has no `BuildContext`.
  ///
  /// Never throws; a failure reading the outbox reads as "nothing pending",
  /// and a failure resolving a row's link keeps that row for next time (it is
  /// a lookup that failed, not a link that is gone).
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Flush", REQ "Error Handling Standards"
  static Future<RommPropsFlushSummary> flush(
    RommService service, {
    required bool Function() isConnected,
    required String favouritesCollectionName,
  }) async {
    var pushed = 0;
    var dropped = 0;
    var kept = 0;

    final rows = await RommPropsOutboxRepository.list();
    if (rows.isEmpty) return (pushed: 0, dropped: 0, kept: 0);

    var index = 0;
    for (; index < rows.length; index++) {
      final row = rows[index];
      if (!isConnected()) {
        _log.i(
          'RomM play-state flush stopped: reason=disconnected '
          'remaining=${rows.length - index}',
        );
        break;
      }

      final int? romId;
      try {
        romId = await RommSaveMapRepository.getRommRomIdForRomPath(row.romPath);
      } catch (e) {
        _log.w(
          'RomM play-state link lookup failed (kept queued): '
          'rom_path=${row.romPath} error=$e',
        );
        kept++;
        continue;
      }
      if (romId == null) {
        _log.i(
          'RomM play-state row dropped: rom_path=${row.romPath} '
          'reason=unlinked',
        );
        await RommPropsOutboxRepository.delete(row.romPath);
        dropped++;
        continue;
      }

      try {
        var confirmed = false;
        var gated = false;
        if (row.hidden != null || row.touchLastPlayed) {
          final ok = await service.updateRomProps(
            romId,
            hidden: row.hidden,
            updateLastPlayed: row.touchLastPlayed,
          );
          if (ok) {
            confirmed = true;
          } else {
            gated = true;
          }
        }
        if (row.favourite != null) {
          final ok = row.favourite!
              ? await service.addFavourite(
                  romId,
                  collectionName: favouritesCollectionName,
                )
              : await service.removeFavourite(
                  romId,
                  collectionName: favouritesCollectionName,
                );
          if (ok) {
            confirmed = true;
          } else {
            gated = true;
          }
        }

        await RommPropsOutboxRepository.delete(row.romPath);
        if (confirmed) {
          pushed++;
        } else {
          dropped++;
        }
        if (gated) {
          // The service already logged why, once per gate per connection.
          _log.i(
            'RomM play-state row dropped: rom=$romId reason=gated '
            'confirmed=$confirmed',
          );
        }
      } on RommException catch (e) {
        if (e.statusCode == 404) {
          _log.i('RomM play-state row dropped: rom=$romId status=404');
          await RommPropsOutboxRepository.delete(row.romPath);
          dropped++;
          continue;
        }
        if (e.kind == RommErrorKind.scopeDenied) {
          _log.i('RomM play-state row dropped: rom=$romId reason=scope_denied');
          await RommPropsOutboxRepository.delete(row.romPath);
          dropped++;
          continue;
        }
        _log.w(
          'RomM play-state push failed (kept queued): rom=$romId '
          'status=${e.statusCode} error=${e.message}',
        );
        kept++;
        if (e.statusCode == null) {
          // No status means no server: the connection is gone or timed out,
          // and every row behind this one would fail the same way.
          index++;
          break;
        }
      } catch (e) {
        _log.w(
          'RomM play-state push failed (kept queued): rom=$romId error=$e',
        );
        kept++;
      }
    }
    kept += rows.length - index;

    if (pushed > 0 || dropped > 0 || kept > 0) {
      _log.i(
        'RomM play-state flush: pushed=$pushed dropped=$dropped kept=$kept',
      );
    }
    return (pushed: pushed, dropped: dropped, kept: kept);
  }
}
