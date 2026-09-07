import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/game_session_persistence.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();
  late dynamic db;
  late _RecordingProvider provider;

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

    provider = _RecordingProvider();
    SyncManager.instance.register(provider);
    await SyncManager.instance.setActive(
      _RecordingProvider.kProviderId,
      persist: (_) async {},
    );
  });

  tearDown(() async {
    // The manager is a singleton: an un-torn-down registration leaks into
    // every later test in the run.
    SyncManager.instance.unregister(_RecordingProvider.kProviderId);
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
    // Under the five-second floor the recovery path treats the session as a
    // failed launch. Playtime is not credited for one, and nothing should be
    // pushed for one either.
    await persistKilledSession(ago: const Duration(seconds: 2));

    await GameSessionManager.checkPendingGameSession();
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(provider.savedGames, isEmpty);
    expect(provider.shotGames, isEmpty);
  });
}

/// Records what the session hooks offer it. Every other transfer method is a
/// stub: these tests only exercise which hooks a recovered session reaches.
class _RecordingProvider implements ISyncProvider, ISessionScreenshotSync {
  static const String kProviderId = 'recording';

  final List<GameModel> savedGames = [];
  final List<GameModel> shotGames = [];
  final List<DateTime> shotStarts = [];

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => SyncProviderMeta(
    id: kProviderId,
    name: 'Recording',
    description: '',
    author: '',
  );

  @override
  SyncProviderStatus get status => SyncProviderStatus.connected;

  /// Connected from the first tick, so the recovery path's wait for a usable
  /// provider resolves immediately rather than polling out the timeout.
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
