import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/game_session_persistence.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';
import 'package:neostation/utils/log_redaction.dart';

import 'database_test_helper.dart';

/// A session the OS killed mid-game must get the same post-close treatment a
/// clean exit gets.
///
/// The recovery path used to record the playtime and stop there: the save the
/// user made in the minutes before the kill was never uploaded, and the
/// captures from that session fell outside every later session's collection
/// window (the collector filters on the session start it is handed), so
/// nothing ever picked them up. Nothing logged a skip, because nothing knew
/// one had happened.
///
/// The hooks then have to wait, because `main()` recovers the session before
/// it registers the sync providers — and the wait has to be on the provider
/// that will actually serve the hook, not on the set (issue #179).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  final registered = <String>[];

  void registerProvider(ISyncProvider provider) {
    SyncManager.instance.register(provider);
    registered.add(provider.providerId);
  }

  Future<void> makeActive(ISyncProvider provider) => SyncManager.instance
      .setActive(provider.providerId, persist: (_) async {});

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    await db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, "
      "cloud_sync_enabled) "
      "VALUES ('zelda.smc', '/roms/snes/zelda.smc', 'snes', 1)",
    );
  });

  tearDown(() async {
    // The manager and the timing overrides are static: an un-torn-down
    // registration or a left-behind override leaks into every later test.
    for (final id in registered) {
      SyncManager.instance.unregister(id);
    }
    registered.clear();
    GameSessionManager.debugResetRecoveredSyncTiming();
    await GameSessionPersistence.clearGameSession();
    await dbHelper.tearDown();
  });

  /// Waits for the detached hooks, which the recovery path deliberately does
  /// not await ([_syncSavesAfterClose] delays itself by two seconds on top).
  Future<void> settle(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<DateTime> persistKilledSession({required Duration ago}) async {
    final start = DateTime.now().subtract(ago);
    await GameSessionPersistence.saveGameSession(
      systemFolderName: 'snes',
      filename: 'zelda.smc',
      startTimestamp: start.millisecondsSinceEpoch,
    );
    return start;
  }

  test('a recovered session syncs its saves and uploads its screenshots '
      'like a clean exit', () async {
    final provider = _RecordingProvider();
    registerProvider(provider);
    await makeActive(provider);

    final start = await persistKilledSession(ago: const Duration(minutes: 12));

    await GameSessionManager.checkPendingGameSession();

    await settle(
      () => provider.savedGames.isNotEmpty && provider.shotGames.isNotEmpty,
    );

    // `romname` is the extension-stripped spelling everywhere in the app —
    // the same value the clean-exit path hands these hooks.
    expect(provider.savedGames.map((g) => g.romname), [
      'zelda',
    ], reason: 'the save the killed session left behind must still go up');
    // The hooks key on the ROM path; a recovered game that reached them
    // without one would be a no-op on the provider side.
    expect(provider.savedGames.single.romPath, '/roms/snes/zelda.smc');

    expect(provider.shotGames.map((g) => g.romname), ['zelda']);
    // The *original* session start, not the launch that recovered it:
    // the collector's window is what decides whether the captures from the
    // killed session are seen at all.
    expect(
      provider.shotStarts.single.millisecondsSinceEpoch,
      start.millisecondsSinceEpoch,
    );
  });

  test('a session too short to have run gets no post-close work', () async {
    final provider = _RecordingProvider();
    registerProvider(provider);
    await makeActive(provider);

    // Under the five-second floor the recovery path treats the session as a
    // failed launch. Playtime is not credited for one, and nothing should be
    // pushed for one either.
    await persistKilledSession(ago: const Duration(seconds: 2));

    await GameSessionManager.checkPendingGameSession();
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(provider.savedGames, isEmpty);
    expect(provider.shotGames, isEmpty);
  });

  test('an authenticated provider that cannot take screenshots does not '
      'satisfy the wait for the one that can', () async {
    // The shape of the defect: a NeoSync-signed-in user. The adapter is
    // registered first and reports authenticated from its very first tick
    // (AuthService.initialize() is awaited before either registration), while
    // RomM is still restoring its saved connection a beat later.
    final saveOnly = _SaveOnlyProvider();
    final shots = _LateScreenshotProvider();
    registerProvider(saveOnly);
    registerProvider(shots);
    await makeActive(saveOnly);

    // The real window is one SQLite read wide. Widened here so the test
    // asserts the ordering rule rather than racing it — and left longer than
    // one poll tick so a wait that resolves on `saveOnly` is caught.
    Timer(const Duration(milliseconds: 300), () => shots.connected = true);

    await persistKilledSession(ago: const Duration(minutes: 12));
    await GameSessionManager.checkPendingGameSession();

    await settle(() => shots.shotGames.isNotEmpty);

    expect(
      shots.shotGames,
      isNotEmpty,
      reason: 'the capable provider must still be offered the session',
    );
    expect(
      shots.connectedWhenCalled,
      [true],
      reason:
          'the pass ran while the only provider that could serve it was still '
          'disconnected — it would have returned 0 and the captures would be '
          'gone, under a log line saying a provider was ready',
    );
  });

  test(
    'a deferral that times out still attempts the upload, and warns',
    () async {
      // Governing: SPEC-0016 REQ "Upload And Ledger" — a deferral that times out
      // MUST still attempt the upload rather than drop it.
      final shots = _LateScreenshotProvider(); // never connects
      registerProvider(shots);

      GameSessionManager.debugRecoveredSyncPoll = const Duration(
        milliseconds: 20,
      );
      GameSessionManager.debugRecoveredSyncWait = const Duration(
        milliseconds: 300,
      );

      LoggerService.instance.startCapture();
      await persistKilledSession(ago: const Duration(minutes: 12));
      await GameSessionManager.checkPendingGameSession();
      await settle(() => shots.shotGames.isNotEmpty);
      final lines = LoggerService.instance.takeCapture();

      expect(
        shots.shotGames,
        isNotEmpty,
        reason: 'the expiry bounds the wait, not the work',
      );
      expect(shots.connectedWhenCalled, [false]);

      // This is the single outcome where a killed session's captures are
      // unrecoverable — the collector never offers them again — and RomM's own
      // bail logs nothing, so this line is the only trace of it.
      expect(
        lines.where(
          (l) =>
              l.startsWith('w|') &&
              l.contains('Recovered session screenshot pass running against'),
        ),
        isNotEmpty,
        reason: 'the permanent-loss branch must log at warning level',
      );
    },
  );

  group('crash-recovery log lines survive redaction', () {
    // `session` is a sensitive field name, so a colon straight after the word
    // makes the redactor eat the token that follows — which on these lines is
    // the exception type, the one part that makes an unreproducible
    // crash-recovery failure diagnosable.
    const detail = 'SocketException: Connection refused';

    test('the reworded lines pass through untouched', () {
      for (final line in [
        'Error checking the pending game session, error=$detail',
        'Failed to queue a RomM play session, error=$detail',
      ]) {
        expect(redactSecrets(line), line, reason: line);
      }
    });

    test('the old wording really did lose the exception type', () {
      expect(
        redactSecrets('Error checking pending game session: $detail'),
        contains('SocketException'),
      );
      expect(
        redactSecrets('Error queueing RomM play session: $detail'),
        contains('SocketException'),
      );
    });
  });
}

/// Implements [ISyncProvider] with inert defaults so each test double only
/// writes the members it actually cares about.
class _StubProvider implements ISyncProvider {
  _StubProvider(this.providerId);

  @override
  final String providerId;

  @override
  SyncProviderMeta get meta => SyncProviderMeta(
    id: providerId,
    name: providerId,
    description: '',
    author: '',
  );

  @override
  SyncProviderStatus get status => isAuthenticated
      ? SyncProviderStatus.connected
      : SyncProviderStatus.disconnected;

  @override
  bool get isAuthenticated => true;

  @override
  String? get lastError => null;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  Future<SyncResult> login() async => SyncResult.ok();

  @override
  Future<void> logout() async {}

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async =>
      SyncResult.ok();

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async => SyncResult.ok();

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async =>
      SyncResult.ok();

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async => const [];

  @override
  Future<SyncResult> fullSync() async => SyncResult.ok();

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async =>
      SyncResult.ok();

  @override
  GameSyncState? getGameSyncState(String gameId) => null;

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async => SyncResult.ok();

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {}

  @override
  Future<SyncQuota?> getQuota() async => null;

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.ok();
}

/// Records what the session hooks offer it. Connected from the first tick, so
/// the recovery path's wait resolves immediately rather than polling out the
/// timeout.
class _RecordingProvider extends _StubProvider
    implements ISessionScreenshotSync {
  _RecordingProvider() : super('recording');

  final List<GameModel> savedGames = [];
  final List<GameModel> shotGames = [];
  final List<DateTime> shotStarts = [];

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    savedGames.add(game);
    return SyncResult.ok();
  }

  @override
  Future<int> uploadSessionScreenshots(
    GameModel game,
    DateTime sessionStart,
  ) async {
    shotGames.add(game);
    shotStarts.add(sessionStart);
    return 1;
  }
}

/// A NeoSync stand-in: authenticated before anything else is registered, and
/// the provider that owns save sync — but it does not declare
/// [ISessionScreenshotSync], so it can never be the one that uploads a
/// capture.
class _SaveOnlyProvider extends _StubProvider {
  _SaveOnlyProvider() : super('save-only');

  final List<GameModel> savedGames = [];

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    savedGames.add(game);
    return SyncResult.ok();
  }
}

/// A RomM stand-in: registered while still disconnected, and only usable once
/// [connected] flips. Records whether it was connected at the moment the pass
/// reached it — which is the whole question.
class _LateScreenshotProvider extends _StubProvider
    implements ISessionScreenshotSync {
  _LateScreenshotProvider() : super('late-shots');

  bool connected = false;

  final List<GameModel> shotGames = [];
  final List<bool> connectedWhenCalled = [];

  @override
  bool get isAuthenticated => connected;

  @override
  Future<int> uploadSessionScreenshots(
    GameModel game,
    DateTime sessionStart,
  ) async {
    shotGames.add(game);
    connectedWhenCalled.add(connected);
    // What RomM does when it is reached disconnected: nothing, silently.
    return connected ? 1 : 0;
  }
}
