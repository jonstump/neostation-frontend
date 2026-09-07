import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/sync/i_sync_provider.dart';
import 'package:neostation/sync/providers/neo_sync_adapter.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

/// Guards the rule that signing out of a provider must not leave it holding
/// save sync.
///
/// Both RomM disconnect paths (the library header's logout button and the
/// connect panel's Disconnect row) call [SyncManager.releaseIfActive]. Without
/// it, "romm" stays active against a server the user just forgot, every save
/// hook errors out, NeoSync sits idle, and nothing on screen connects the dead
/// sync to the disconnect that caused it. There was no coverage of this before;
/// the same gap is why `RomMSyncProvider.logout()` was written without a
/// handback and nobody noticed.
void main() {
  late _FakeProvider neoSync;
  late _FakeProvider romm;
  late List<String> persisted;

  setUp(() {
    neoSync = _FakeProvider(NeoSyncAdapter.kProviderId, 'NeoSync');
    romm = _FakeProvider(RomMSyncProvider.kProviderId, 'RomM');
    persisted = [];
    SyncManager.instance.register(neoSync);
    SyncManager.instance.register(romm);
  });

  tearDown(() {
    // The manager is a singleton, so an un-torn-down registration leaks into
    // every later test in the run.
    SyncManager.instance.unregister(RomMSyncProvider.kProviderId);
    SyncManager.instance.unregister(NeoSyncAdapter.kProviderId);
  });

  Future<void> persist(String id) async => persisted.add(id);

  test(
    'disconnecting the active provider hands save sync back to NeoSync',
    () async {
      await SyncManager.instance.setActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );
      persisted.clear();

      final moved = await SyncManager.instance.releaseIfActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );

      expect(moved, isTrue);
      expect(SyncManager.instance.activeProviderId, NeoSyncAdapter.kProviderId);
      // Persisted, not just held in memory: the choice has to survive a restart,
      // or the next launch resurrects the disconnected provider.
      expect(persisted, [NeoSyncAdapter.kProviderId]);
    },
  );

  test(
    'disconnecting a provider that does not own save sync changes nothing',
    () async {
      await SyncManager.instance.setActive(
        NeoSyncAdapter.kProviderId,
        persist: persist,
      );
      persisted.clear();

      final moved = await SyncManager.instance.releaseIfActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );

      expect(moved, isFalse);
      expect(SyncManager.instance.activeProviderId, NeoSyncAdapter.kProviderId);
      // A NeoSync user who merely disconnects a RomM server must not have their
      // setting rewritten underneath them.
      expect(persisted, isEmpty);
    },
  );

  test(
    'handing back notifies listeners so the UI can drop its owner line',
    () async {
      await SyncManager.instance.setActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );
      var notifications = 0;
      void listener() => notifications++;
      SyncManager.instance.addListener(listener);
      addTearDown(() => SyncManager.instance.removeListener(listener));

      await SyncManager.instance.releaseIfActive(
        RomMSyncProvider.kProviderId,
        persist: persist,
      );

      expect(notifications, greaterThan(0));
    },
  );

  group('session screenshot capability', () {
    // The regression: the session hook reached for the RomM adapter by id and
    // downcast to the concrete RomMSyncProvider, which inverts the layering
    // (a service naming one sync adapter) that the provider-agnostic sync
    // layer exists to prevent. The hook now offers a finished session to every
    // registered provider that declares the capability.
    // Governing: ADR-0016, SPEC-0016 REQ "Concurrency Safety"
    test('every registered provider is reachable, active or not', () {
      final ids = SyncManager.instance.providers.map((p) => p.providerId);
      expect(ids, containsAll([NeoSyncAdapter.kProviderId, 'romm']));
    });

    test('only providers that declare the capability are offered the '
        'session', () async {
      final capable = _ScreenshotFakeProvider('shots', 'Shots');
      SyncManager.instance.register(capable);
      addTearDown(() => SyncManager.instance.unregister('shots'));

      final offered = SyncManager.instance.providers
          .whereType<ISessionScreenshotSync>()
          .toList();

      expect(offered, [capable]);
      expect(offered.single, isNot(same(romm)));

      await offered.single.uploadSessionScreenshots(
        _game('Game.sfc'),
        DateTime(2026, 9, 6, 10),
      );
      expect(capable.uploaded, ['Game.sfc']);
    });
  });
}

GameModel _game(String romname) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
);

/// A provider that also stores session screenshots, for the capability probe.
class _ScreenshotFakeProvider extends _FakeProvider
    implements ISessionScreenshotSync {
  _ScreenshotFakeProvider(super.providerId, super.name);

  final List<String> uploaded = [];

  @override
  Future<int> uploadSessionScreenshots(
    GameModel game,
    DateTime sessionStart,
  ) async {
    uploaded.add(game.romname);
    return 1;
  }
}

/// Minimal [ISyncProvider] stand-in: these tests only exercise registration and
/// active-id bookkeeping, so every transfer method is left unimplemented.
class _FakeProvider implements ISyncProvider {
  _FakeProvider(this.providerId, this.name);

  @override
  final String providerId;

  final String name;

  @override
  SyncProviderMeta get meta =>
      SyncProviderMeta(id: providerId, name: name, description: '', author: '');

  @override
  SyncProviderStatus get status => SyncProviderStatus.connected;

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
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async =>
      SyncResult.ok();

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {}

  @override
  Future<SyncQuota?> getQuota() async => null;

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.ok();
}
