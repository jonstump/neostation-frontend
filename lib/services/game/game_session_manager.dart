import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../repositories/game_repository.dart';
import '../../repositories/system_repository.dart';
import '../../sync/i_sync_provider.dart';
import '../../sync/sync_manager.dart';
import '../game_session_persistence.dart';
import '../retroachievements_hash_service.dart';
import '../romm_playtime_service.dart';

/// Owns the game-session lifecycle and its mutable tracking state.
///
/// Single owner of the launch/session flags, the current-game metadata, the
/// return/exit callbacks, and the playtime timer. Registers a session on
/// launch, persists playtime incrementally, and finalizes it on teardown, plus
/// recovery of a session interrupted by an OS kill. Extracted verbatim from
/// [GameService], which now delegates its session API here and calls
/// [registerGameLaunch]/[endGameSession] from its launch methods.
class GameSessionManager {
  GameSessionManager._();

  static final _log = LoggerService.instance;

  /// Whether a game process is currently active.
  static bool _isGameLaunched = false;
  static bool get isGameLaunched => _isGameLaunched;

  /// True from the moment a launch is initiated (Now Playing pushed) until the
  /// launch resolves — i.e. [registerGameLaunch] flips [_isGameLaunched], or
  /// the launch fails. Covers the ~2s dialog+handoff window during which
  /// [_isGameLaunched] is still false, so a transient resume in that window
  /// can't clear the Now Playing state we just pushed.
  static bool _launchPending = false;

  /// Whether a game is running OR a launch is in progress. Callers reacting to
  /// an app resume should use this (not [isGameLaunched]) before clearing
  /// secondary-display in-game state, to avoid a launch-window race.
  static bool get isGameLaunchInProgress => _isGameLaunched || _launchPending;

  /// Opens the launch-pending window. Call when a launch is initiated, before
  /// the emulator handoff. Cleared by [registerGameLaunch] on success or
  /// [clearLaunchPending] on failure.
  static void beginLaunchPending() {
    _launchPending = true;
    _pauseBackgroundHashing();
  }

  /// Stops a library-wide RetroAchievements pass for the duration of a game.
  ///
  /// Hashing reads whole ROMs off storage; on a handheld, doing that while an
  /// emulator is running is a worse trade than finishing the pass later. The
  /// pass is resumable by construction, so nothing is lost: whoever started it
  /// picks it up from where it stopped. A no-op when no pass is running.
  static void _pauseBackgroundHashing() {
    if (!RetroAchievementsHashService.isRematchRunning) return;
    _log.i('Pausing RA match pass for the duration of the game session');
    RetroAchievementsHashService.requestRematchPause();
  }

  /// Closes the launch-pending window (e.g. on launch failure).
  static void clearLaunchPending() => _launchPending = false;

  /// Timestamp when the current game session was initiated.
  static DateTime? _gameLaunchTime;
  static DateTime? get gameLaunchTime => _gameLaunchTime;

  /// Filename of the standalone emulator executable currently running.
  static String? _launchedEmulatorExe;
  static String? get launchedEmulatorExe => _launchedEmulatorExe;

  /// Metadata for the system associated with the current game.
  static SystemModel? _currentGameSystem;

  /// Metadata for the currently active game.
  static GameModel? _currentGame;

  /// Callback triggered when a game session terminates on Android.
  static Function(int)? _onGameReturnedCallback;
  static Function(int)? get onGameReturnedCallback => _onGameReturnedCallback;

  /// Callback triggered when the game process exits on desktop platforms.
  static Function()? _onProcessExitCallback;

  /// Periodic timer for persisting playtime statistics to the database.
  static Timer? _playtimeTimer;

  /// Timestamp of the last successful playtime persistence operation.
  static DateTime? _lastPlaytimeSave;

  static void setOnGameReturnedCallback(Function(int) callback) {
    _onGameReturnedCallback = callback;
  }

  static void clearOnGameReturnedCallback() {
    _onGameReturnedCallback = null;
  }

  static void setOnProcessExitCallback(Function() callback) {
    _onProcessExitCallback = callback;
  }

  static void clearOnProcessExitCallback() {
    _onProcessExitCallback = null;
  }

  /// Listeners notified once a session has been finalized.
  ///
  /// Separate from [_onProcessExitCallback] and [_onGameReturnedCallback],
  /// which are single-slot and owned by whichever screen launched the game.
  /// This is a broadcast for state that is not tied to a launch site — anything
  /// cached about the player's progress is stale the moment they stop playing,
  /// whichever screen started the game and whichever platform ended it. Every
  /// launcher funnels its exit through [endGameSession], so registering here
  /// covers them all.
  static final List<VoidCallback> _sessionEndListeners = <VoidCallback>[];

  static void addSessionEndListener(VoidCallback listener) {
    if (!_sessionEndListeners.contains(listener)) {
      _sessionEndListeners.add(listener);
    }
  }

  static void removeSessionEndListener(VoidCallback listener) {
    _sessionEndListeners.remove(listener);
  }

  /// Fires every session-end listener, isolating them from each other: this
  /// runs on the game-exit path, which already has UI waiting on it, so one
  /// listener throwing must not skip the rest or fail the teardown.
  static void _notifySessionEnded() {
    for (final listener in List<VoidCallback>.from(_sessionEndListeners)) {
      try {
        listener();
      } catch (e) {
        _log.e('Session-end listener failed: $e');
      }
    }
  }

  /// Reconciles a previously interrupted game session.
  ///
  /// Handles cases where the application was terminated by the OS (Android)
  /// while a game was running: the elapsed time is credited, the session is
  /// queued for RomM, and the same post-close hooks a clean exit fires are run
  /// detached (see [_runRecoveredSessionHooks]). Recording the playtime and
  /// dropping the saves and screenshots was the earlier behaviour, and it was
  /// silent — a save the user made in the minutes before the kill never went
  /// up, and the captures from that session fell outside every later session's
  /// collection window, so nothing ever picked them up.
  static Future<void> checkPendingGameSession() async {
    try {
      final session = await GameSessionPersistence.getActiveGameSession();

      if (session == null) {
        return;
      }

      final systemFolderName = session['systemFolderName'].toString();
      final filename = session['filename'].toString();
      final startTimestamp =
          int.tryParse(session['startTimestamp']?.toString() ?? '0') ?? 0;

      final currentTimestamp = DateTime.now().millisecondsSinceEpoch;
      final elapsedSeconds = ((currentTimestamp - startTimestamp) / 1000)
          .round();

      // Only process sessions that lasted at least 5 seconds to filter out launch failures
      if (elapsedSeconds >= 5) {
        final system = await SystemRepository.getSystemByFolderName(
          systemFolderName,
        );
        if (system == null) return;
        final game = await GameRepository.getSingleGame(system.id!, filename);

        if (game != null && game.romPath.isNotEmpty) {
          await GameRepository.updatePlayTime(game.romPath, elapsedSeconds);
          await _recordRommPlaySession(
            romname: filename,
            systemFolder: game.systemFolderName ?? systemFolderName,
            romPath: game.romPath,
            start: DateTime.fromMillisecondsSinceEpoch(startTimestamp),
            end: DateTime.fromMillisecondsSinceEpoch(currentTimestamp),
          );

          // A killed session is still a finished session: give it the same
          // post-close treatment [endGameSession] gives a clean exit. Behind
          // the same gates as the playtime write above — the >= 5s floor that
          // filters launch failures, and a ROM path the hooks can key on — and
          // detached, because startup must not wait on it.
          unawaited(
            _runRecoveredSessionHooks(
              GameModel.fromDatabaseModel(game),
              DateTime.fromMillisecondsSinceEpoch(startTimestamp),
            ),
          );
        }
      }

      await GameSessionPersistence.clearGameSession();
    } catch (e) {
      // No colon after "session": the log redactor treats that as a session
      // token and blanks the token that follows it — which on this line is the
      // exception type, the one thing that makes a crash-recovery failure
      // diagnosable. Verified against `redactSecrets` directly.
      _log.e('Error checking the pending game session, error=$e');
    }
  }

  /// The post-close hooks for a session recovered by
  /// [checkPendingGameSession], run once the provider that will do the work
  /// can act on it.
  ///
  /// Same hooks as the clean-exit path in [endGameSession]: the screenshot
  /// pass and the save sync (which delays itself further). The recovered
  /// session's *original* start is what is passed on, so the collector's
  /// session window covers the captures the killed session left behind — the
  /// window RetroArch stamped them in, not the window of the launch that
  /// recovered them.
  ///
  /// The wait exists because of when this runs. `main()` calls
  /// [checkPendingGameSession] during startup, before it builds and registers
  /// the sync providers, so firing the hooks inline would offer the session to
  /// an empty registry and drop it — silently, which is the whole defect.
  /// Waiting here rather than moving the call keeps the recovery's database
  /// work (playtime, and the flag that suppresses the startup scan) where the
  /// rest of startup expects it.
  ///
  /// The two hooks wait **separately**, each on the provider that will
  /// actually serve it: screenshots go to whoever declares
  /// [ISessionScreenshotSync], saves go to [SyncManager.active], and those are
  /// routinely different providers that become ready at different moments.
  /// Waiting on "any authenticated provider" let a NeoSync session — restored
  /// and authenticated before either registration — satisfy a wait that RomM
  /// was still milliseconds short of, after which the screenshot pass hit
  /// RomM's silent `!isConnected` bail and returned 0 under a line saying the
  /// provider was ready. Running them concurrently rather than in sequence is
  /// deliberate too: neither hook should spend the other's timeout, and the
  /// ordering constraint they inherit from [endGameSession] is only that the
  /// playtime write comes first, which it already has here.
  ///
  /// Never throws: it is detached, and an unhandled async error on this path
  /// reaches no error handler.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger" (a crash-recovered session is a session end; defer rather than offer to an empty registry; a deferral that times out still attempts the upload), SPEC-0016 REQ "Concurrency Safety" (detached, after the playtime hooks)
  static Future<void> _runRecoveredSessionHooks(
    GameModel game,
    DateTime sessionStart,
  ) async {
    try {
      await Future.wait(<Future<void>>[
        _uploadRecoveredScreenshots(game, sessionStart),
        _syncRecoveredSaves(game),
      ]);
    } catch (e) {
      _log.e('Recovered session post-close hooks failed: $e');
    }
  }

  /// How long a recovered session's hooks wait for the provider that will
  /// serve them to finish restoring its saved connection, and how often they
  /// look.
  ///
  /// Polled rather than listened for: [SyncManager] only re-broadcasts what a
  /// provider notifies, registration itself notifies nothing, and a provider
  /// restoring a saved connection does not notify through it either. The poll
  /// costs one getter read per tick, runs at most once per launch, and only
  /// when a session was actually recovered.
  static const Duration _recoveredSyncWait = Duration(seconds: 20);
  static const Duration _recoveredSyncPoll = Duration(milliseconds: 250);

  /// Test overrides for the poll bounds above. Production reads the constants;
  /// a test that has to exercise the expiry path cannot spend twenty seconds
  /// doing it.
  @visibleForTesting
  static Duration? debugRecoveredSyncWait;
  @visibleForTesting
  static Duration? debugRecoveredSyncPoll;

  /// Clears both overrides. Call from `tearDown` — they are static, so a test
  /// that leaves one set changes every later test in the run.
  @visibleForTesting
  static void debugResetRecoveredSyncTiming() {
    debugRecoveredSyncWait = null;
    debugRecoveredSyncPoll = null;
  }

  /// Polls [isReady] until it holds, or until the deadline. Returns whether it
  /// ever held; callers run the work either way, because on this path the work
  /// is offered exactly once and dropping it loses the session's captures for
  /// good.
  static Future<bool> _awaitProvider(bool Function() isReady) async {
    final wait = debugRecoveredSyncWait ?? _recoveredSyncWait;
    final poll = debugRecoveredSyncPoll ?? _recoveredSyncPoll;
    final deadline = DateTime.now().add(wait);
    while (!isReady()) {
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(poll);
    }
    return true;
  }

  /// [provider.isAuthenticated] without letting a provider that throws from
  /// its own getter take down the recovery path.
  static bool _isProviderReady(ISyncProvider provider) {
    try {
      return provider.isAuthenticated;
    } catch (e) {
      _log.w('Sync provider readiness check failed: $e');
      return false;
    }
  }

  /// Registered providers that declare [ISessionScreenshotSync] — the only
  /// ones a screenshot pass can ever reach, and therefore the only ones whose
  /// readiness says anything about whether the pass will do something.
  static List<ISyncProvider> _screenshotProviders() => <ISyncProvider>[
    for (final p in SyncManager.instance.providers)
      if (p is ISessionScreenshotSync) p,
  ];

  /// The screenshot half of the recovered-session hooks.
  ///
  /// Waits for a provider that declares the capability to report ready, then
  /// runs the pass. A provider that cannot take screenshots at all (NeoSync)
  /// never satisfies this wait, however authenticated it is.
  ///
  /// Every outcome that can lose the captures is a warning, because this is
  /// the one path where losing them is permanent: `ScreenshotCollector.collect`
  /// bounds its window at the session start it is handed, so a killed
  /// session's captures fall outside every later session's window and are
  /// never offered again. RomM's own bail logs nothing, so these lines are the
  /// only trace.
  // Governing: SPEC-0016 REQ "Upload And Ledger" (a deferral that times out MUST still attempt the upload rather than drop it)
  static Future<void> _uploadRecoveredScreenshots(
    GameModel game,
    DateTime sessionStart,
  ) async {
    final ready = await _awaitProvider(
      () => _screenshotProviders().any(_isProviderReady),
    );

    // Re-read after the wait: the registry is what changed while we polled.
    final providers = _screenshotProviders();
    if (providers.isEmpty) {
      _log.w(
        'Recovered session screenshots dropped game="${game.romname}" '
        'reason=no_capable_provider',
      );
      return;
    }

    final unready = providers.where((p) => !_isProviderReady(p)).toList();
    if (!ready || unready.isNotEmpty) {
      // Attempt anyway (the spec requires it) but say so: this is exactly the
      // combination that used to be logged as a success.
      _log.w(
        'Recovered session screenshot pass running against '
        '${unready.length} of ${providers.length} unconnected providers '
        'game="${game.romname}" waited=$ready '
        'unconnected=${unready.map((p) => p.providerId).join(",")} '
        '— captures from a killed session are offered once and never again',
      );
    }

    final uploaded = await _runScreenshotPass(providers, game, sessionStart);
    _log.i(
      'Recovered session screenshot pass done game="${game.romname}" '
      'uploaded=$uploaded capable=${providers.length}',
    );
  }

  /// The save half of the recovered-session hooks.
  ///
  /// Saves are a delegation, not a broadcast: [_syncSavesAfterClose] hands
  /// them to [SyncManager.active], so that is the provider to wait on.
  static Future<void> _syncRecoveredSaves(GameModel game) async {
    final ready = await _awaitProvider(() {
      final active = SyncManager.instance.active;
      return active != null && _isProviderReady(active);
    });
    if (!ready) {
      _log.w(
        'Recovered session save sync running without a connected active '
        'provider game="${game.romname}" '
        'active=${SyncManager.instance.activeProviderId}',
      );
    }
    _syncSavesAfterClose(game);
  }

  /// Registers the initiation of a game session and initializes tracking state.
  static void registerGameLaunch(
    SystemModel system,
    GameModel game, [
    String? emulatorExeName,
  ]) {
    _isGameLaunched = true;
    _launchPending = false;
    // Also here, not only in beginLaunchPending: a launch path that never
    // opened the pending window would otherwise leave the pass running.
    _pauseBackgroundHashing();
    _gameLaunchTime = DateTime.now();
    _lastPlaytimeSave = _gameLaunchTime;
    _launchedEmulatorExe = emulatorExeName;
    _currentGameSystem = system;
    _currentGame = game;

    if (Platform.isAndroid) {
      GameSessionPersistence.saveGameSession(
        systemFolderName: system.folderName,
        filename: game.romname,
        startTimestamp: _gameLaunchTime!.millisecondsSinceEpoch,
      );
    }

    _startPlaytimeTimer();
  }

  /// Starts the periodic timer for incremental playtime persistence.
  static void _startPlaytimeTimer() {
    _playtimeTimer?.cancel();

    _playtimeTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_isGameLaunched &&
          _gameLaunchTime != null &&
          _lastPlaytimeSave != null &&
          _currentGameSystem != null &&
          _currentGame != null) {
        final now = DateTime.now();
        final elapsedSinceLastSave = now
            .difference(_lastPlaytimeSave!)
            .inSeconds;

        if (elapsedSinceLastSave > 0) {
          _savePlayTime(
            _currentGameSystem!,
            _currentGame!,
            elapsedSinceLastSave,
          );
          _lastPlaytimeSave = now;
        }
      }
    });
  }

  static void _stopPlaytimeTimer() {
    _playtimeTimer?.cancel();
    _playtimeTimer = null;
  }

  /// Whether a teardown is already in flight. See [endGameSession].
  static bool _isEndingSession = false;

  /// Gracefully terminates the active game session and finalizes playtime tracking.
  ///
  /// Re-entrant by nature, and guarded accordingly: on desktop the exit
  /// callback below is dispatched from the middle of this method and drives the
  /// launch dialog's close synchronously, which calls straight back in here.
  /// The nested call used to find `_isGameLaunched` still set — it is cleared at
  /// the bottom — so it re-ran the whole teardown, recording the playtime and
  /// the RomM session twice, and then read `_currentGame!` after its first
  /// await, by which point the outer call had finished and nulled it. The
  /// resulting null-check error surfaced nowhere (an unhandled async error does
  /// not reach `FlutterError.onError`), so the launch dialog never received
  /// `completeClose()` and sat on "Closing game" until the user dismissed it by
  /// hand.
  ///
  /// The session state is therefore read once, up front, and every later step
  /// works from those locals rather than from fields another call may clear.
  static Future<void> endGameSession() async {
    if (!_isGameLaunched || _isEndingSession) return;
    _isEndingSession = true;

    try {
      final system = _currentGameSystem;
      final game = _currentGame;
      final launchTime = _gameLaunchTime;
      final lastPlaytimeSave = _lastPlaytimeSave;

      if (launchTime != null &&
          lastPlaytimeSave != null &&
          system != null &&
          game != null) {
        final now = DateTime.now();
        final elapsedSinceLastSave = now.difference(lastPlaytimeSave).inSeconds;
        if (elapsedSinceLastSave > 0) {
          await _savePlayTime(system, game, elapsedSinceLastSave);
        }

        // Report the session as a whole (not just the un-persisted tail) to the
        // RomM outbox: RomM stores playtime as sessions, and the incremental
        // 10s writes above are a local persistence detail.
        if (game.romPath != null) {
          await _recordRommPlaySession(
            romname: game.romname,
            systemFolder: game.systemFolderName ?? system.folderName,
            romPath: game.romPath!,
            start: launchTime,
            end: now,
          );

          // Strictly after the playtime hooks, and detached: collecting and
          // uploading captures is filesystem plus network work, while this
          // path still has the launch dialog waiting on it.
          _uploadScreenshotsAfterClose(game, launchTime);
        }
        _syncSavesAfterClose(game);
      }

      _stopPlaytimeTimer();

      if (Platform.isAndroid) {
        const platform = MethodChannel('com.neogamelab.neostation/game');
        await platform.invokeMethod('setGamepadBlock', {'block': false});
        GameSessionPersistence.clearGameSession();
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        if (_onProcessExitCallback != null) {
          _onProcessExitCallback!();
        }
      }

      _isGameLaunched = false;
      _gameLaunchTime = null;
      _lastPlaytimeSave = null;
      _launchedEmulatorExe = null;
      _currentGameSystem = null;
      _currentGame = null;

      _notifySessionEnded();
    } finally {
      _isEndingSession = false;
    }
  }

  static Future<void> _savePlayTime(
    SystemModel system,
    GameModel game,
    int elapsedSeconds,
  ) async {
    try {
      await GameRepository.updatePlayTime(game.romPath!, elapsedSeconds);
    } catch (e) {
      _log.e('Error saving game time: $e');
    }
  }

  /// Uploads the save files the just-closed game left behind.
  ///
  /// This belongs here rather than in a screen because every launcher — the
  /// games list, the recently-played carousel, the systems grid, search —
  /// funnels its exit through [endGameSession]. It used to live in the games
  /// list alone, so a game started from anywhere else uploaded nothing on
  /// exit; the save only went up later, when browsing the list happened to
  /// re-detect it.
  ///
  /// Deliberately not awaited, and deliberately delayed: the emulator has just
  /// died and may still be flushing its save to disk, while the exit path
  /// itself has UI waiting on it. Failures are logged and dropped — the next
  /// detect pass will pick the save up.
  static void _syncSavesAfterClose(GameModel game) {
    final provider = SyncManager.instance.active;
    if (provider == null) {
      _log.w('Post-game save sync skipped: no active sync provider');
      return;
    }
    _log.i(
      'Post-game save sync queued for ${game.romname} (${provider.providerId})',
    );
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        await provider.syncGameSavesAfterClose(game);
      } catch (e) {
        _log.e('Post-game save sync failed: $e');
      }
    });
  }

  /// Pushes the RetroArch captures the just-closed game left behind to RomM.
  ///
  /// Deliberately not awaited: it lists a directory and makes one request per
  /// new capture, and the exit path has UI waiting on it. One pass per session
  /// end, and the provider itself decides whether there is anything to do —
  /// it checks the connection, the user's toggle and the game's RomM link, and
  /// stops mid-pass if the connection drops. Failures are logged there and
  /// dropped here: an unrecorded capture simply goes up after the next
  /// session.
  ///
  /// Offered to every registered provider that declares
  /// [ISessionScreenshotSync], rather than to [SyncManager.active], because a
  /// screenshot is content, not a save — it is worth pushing whether or not
  /// the provider that wants it is the one doing the saves. Probing the
  /// capability keeps this service inside the provider-agnostic sync layer:
  /// it used to reach for the RomM adapter by id and downcast to it, which
  /// inverts the dependency direction and makes one provider a hard-coded
  /// dependency of the session lifecycle.
  ///
  /// Runs immediately after [_recordRommPlaySession] on the same session-end
  /// path, so it inherits that hook's ordering contract: the local play-state
  /// write comes first and this never delays it.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), ADR-0013 (push play state to RomM), SPEC-0016 REQ "Concurrency Safety"
  static void _uploadScreenshotsAfterClose(
    GameModel game,
    DateTime sessionStart,
  ) {
    final providers = _screenshotProviders();
    if (providers.isEmpty) return;
    unawaited(_runScreenshotPass(providers, game, sessionStart));
  }

  /// Offers [game]'s session to each of [providers] in turn and returns how
  /// many captures reached a remote.
  ///
  /// Shared by the clean-exit and crash-recovery paths so the two cannot drift
  /// in how they treat a provider that throws. Every entry in [providers] is
  /// an [ISessionScreenshotSync]; the list is typed [ISyncProvider] so callers
  /// can also read the provider's identity and readiness for the logs.
  static Future<int> _runScreenshotPass(
    List<ISyncProvider> providers,
    GameModel game,
    DateTime sessionStart,
  ) async {
    var uploaded = 0;
    for (final provider in providers) {
      try {
        uploaded += await (provider as ISessionScreenshotSync)
            .uploadSessionScreenshots(game, sessionStart);
      } catch (e) {
        _log.e('Session screenshot upload failed after close: $e');
      }
    }
    return uploaded;
  }

  /// Queues a finished session for RomM playtime sync. A local DB write only —
  /// no network — so it costs nothing on the game-exit path and survives being
  /// offline; the upload happens on the next RomM sync. No-ops for games that
  /// didn't come from RomM.
  static Future<void> _recordRommPlaySession({
    required String romname,
    required String systemFolder,
    required String romPath,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      await RommPlaytimeService.recordCompletedSession(
        romname: romname,
        systemFolder: systemFolder,
        romPath: romPath,
        startTime: start,
        endTime: end,
      );
    } catch (e) {
      // Also colon-free after "session" — see [checkPendingGameSession].
      _log.e('Failed to queue a RomM play session, error=$e');
    }
  }
}
