import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm/romm_catalog_refresh.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// The "Link now" hook's lifetime: [RomMSyncProvider] installs `linkLibrary`
/// on the browse provider when it is built and takes it back when it is
/// disposed, and a hook captured before the dispose — an upload summary's
/// action that outlived the provider — does nothing afterwards.
///
/// Instance-method tear-offs are `==` but never `identical`, which is why
/// the teardown is asserted on rather than assumed.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link
/// After Upload"

class _FakeRommService extends RommService {
  int platformLoads = 0;

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommPlatform>> getPlatforms() async {
    platformLoads++;
    return const [];
  }
}

class _FakeBrowse extends RommProvider {
  final _FakeRommService fakeService;
  bool connected = true;

  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}

/// Counts its runs; the algorithm has its own tests.
class _FakeLinker extends RommLibraryLinker {
  int runs = 0;

  _FakeLinker()
    : super(
        listPlatforms: () async => const [],
        resolveSystem: (_) async => null,
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => const [],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => 0,
      );

  @override
  Future<RommLinkPassSummary> run() async {
    runs++;
    return const RommLinkPassSummary(rowsAdded: 1);
  }
}

/// Records the reasons it was asked with and answers a skip, so the pass
/// falls through to the linker.
class _FakeRefresh extends RommCatalogRefresh {
  final List<RommRefreshReason> reasons = [];

  _FakeRefresh()
    : super(
        listPlatforms: () async => const [],
        resolveSystem: (_) async => null,
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        serverUrl: () => 'https://romm.example',
      );

  @override
  Future<RommCatalogRefreshSummary> run({
    RommRefreshReason reason = RommRefreshReason.scheduled,
  }) async {
    reasons.add(reason);
    return const RommCatalogRefreshSummary(skipped: RommRefreshSkip.noServer);
  }
}

void main() {
  final helper = DatabaseTestHelper();
  late _FakeBrowse browse;
  late _FakeLinker linker;
  late _FakeRefresh refresh;

  setUp(() async {
    await helper.setUp();
    browse = _FakeBrowse(_FakeRommService());
    linker = _FakeLinker();
    refresh = _FakeRefresh();
  });

  tearDown(() async {
    await helper.tearDown();
  });

  RomMSyncProvider build() => RomMSyncProvider(
    browse,
    NeoSyncProvider(NeoSyncService()),
    linker: linker,
    catalogRefresh: refresh,
    autoSweep: false,
  );

  test('construction installs the hook and "Link now" runs the pass', () async {
    final provider = build();
    addTearDown(provider.dispose);

    expect(browse.onLinkRequested, isNotNull);

    final result = await browse.linkNow();

    expect(refresh.reasons, [RommRefreshReason.connect]);
    expect(linker.runs, 1);
    expect(result?.rowsAdded, 1);
  });

  test('dispose clears the hook on the browse provider', () {
    final provider = build();

    provider.dispose();

    expect(
      browse.onLinkRequested,
      isNull,
      reason: 'the tear-off must be cleared without an identity check',
    );
    expect(browse.onReconnected, isNull);
  });

  test('"Link now" after dispose is a no-op', () async {
    final provider = build();
    provider.dispose();

    expect(await browse.linkNow(), isNull);
    expect(refresh.reasons, isEmpty);
    expect(linker.runs, 0);
  });

  test('a hook captured before dispose does nothing afterwards', () async {
    final provider = build();
    final stale = browse.onLinkRequested!;
    provider.dispose();

    final result = await stale();

    expect(result, isNull);
    expect(
      refresh.reasons,
      isEmpty,
      reason: 'no catalog walk on a dead provider',
    );
    expect(linker.runs, 0);
    expect(browse.fakeService.platformLoads, 0);
  });

  test(
    'a stale hook stays a no-op after a newer provider takes over',
    () async {
      final first = build();
      final stale = browse.onLinkRequested!;
      first.dispose();

      final second = build();
      addTearDown(second.dispose);

      expect(await stale(), isNull);
      expect(refresh.reasons, isEmpty);

      // The live hook is the new provider's.
      await browse.linkNow();
      expect(refresh.reasons, [RommRefreshReason.connect]);
    },
  );
}
