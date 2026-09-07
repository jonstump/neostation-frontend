import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_catalog_refresh.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';

/// [RommCatalogRefresh] against in-memory fakes: a server of platforms and ROM
/// pages, a catalog sink, and the real [RommLibraryLinker] riding along on the
/// same walk. No filesystem, no database, no network.
///
/// The point of the story this covers is that the server is walked *once* for
/// both the catalog and the link pass (SPEC-0019 "Catalog Refresh Shares The
/// Walk"), including on a library where every game is already linked — the
/// case where the link pass on its own would not have walked at all.

const _server = 'https://romm.example';

RommRom _rom(int id, {required int platformId, required String fsName}) =>
    RommRom(
      id: id,
      name: fsName,
      platformId: platformId,
      platformSlug: 'snes',
      fsName: fsName,
      fsNameNoExt: fsName.split('.').first,
      fsExtension: fsName.split('.').last,
      fsSizeBytes: 1024,
    );

RommPlatform _platform(int id, String slug) =>
    RommPlatform(id: id, name: slug.toUpperCase(), slug: slug, romCount: 1);

SystemModel _system(String folder) => SystemModel(
  folderName: folder,
  realName: folder.toUpperCase(),
  iconImage: '/images/icons/$folder.png',
  color: '#000000',
  folders: [folder],
);

DatabaseGameModel _game(String filename, String folder) => DatabaseGameModel(
  filename: filename,
  romPath: '/roms/$folder/$filename',
  systemFolderName: folder,
);

/// The mapping table, insert-if-absent, as the linker's own tests fake it.
class _FakeMap {
  final Map<String, int> rows = {};

  Future<int> putIfAbsent(List<RommSaveMapEntry> entries) async {
    var inserted = 0;
    for (final e in entries) {
      final key = '${e.systemFolder}\t${e.romname}';
      if (rows.containsKey(key)) continue;
      rows[key] = e.rommRomId;
      inserted++;
    }
    return inserted;
  }

  Future<RommRomIdIndex> index() async => RommRomIdIndex(Map.of(rows));
}

/// The catalog, in memory: what was upserted, what was pruned, what was
/// recorded per platform.
class _FakeCatalog {
  final Map<int, RommCatalogRow> rows = {};
  final List<int> upsertBatchSizes = [];
  final List<int> prunedPlatforms = [];
  final Map<int, DateTime?> platformStamps = {};
  final Map<int, int> platformCounts = {};
  DateTime? newest;

  /// Platforms whose writes fail: the batch is dropped and the short count
  /// the real repository returns for a failed chunk is reported.
  Set<int> failingWrites = const {};

  Future<int> upsert(List<RommCatalogRow> batch) async {
    upsertBatchSizes.add(batch.length);
    if (batch.isNotEmpty && failingWrites.contains(batch.first.platformId)) {
      return 0;
    }
    for (final row in batch) {
      rows[row.rommRomId] = row;
    }
    return batch.length;
  }

  Future<int> deleteUnseen({
    required String serverUrl,
    required int platformId,
    required DateTime before,
  }) async {
    prunedPlatforms.add(platformId);
    final gone = rows.values
        .where((r) => r.platformId == platformId && r.seenAt.isBefore(before))
        .map((r) => r.rommRomId)
        .toList();
    for (final id in gone) {
      rows.remove(id);
    }
    return gone.length;
  }

  Future<bool> recordPlatform({
    required String serverUrl,
    required int platformId,
    required String systemFolder,
    required String name,
    required int romCount,
    DateTime? refreshedAt,
  }) async {
    platformStamps[platformId] = refreshedAt;
    platformCounts[platformId] = romCount;
    return true;
  }

  Future<DateTime?> newestRefreshedAt(String serverUrl) async => newest;
}

/// A RomM server: platforms, their ROMs, and what was asked of it.
class _FakeServer {
  final List<RommPlatform> platforms;
  final Map<int, List<RommRom>> romsByPlatform;
  final Map<String, SystemModel?> systemBySlug;
  final Set<int> failingPlatforms;

  /// `platformId@offset` per page request, in order.
  final List<String> requests = [];
  void Function()? onFetch;

  _FakeServer({
    required this.platforms,
    required this.romsByPlatform,
    required this.systemBySlug,
    this.failingPlatforms = const {},
  });

  Future<List<RommPlatform>> listPlatforms() async => platforms;

  Future<SystemModel?> resolve(RommPlatform platform) async =>
      systemBySlug[platform.slug];

  Future<RommRomPage> fetchPage({
    required int platformId,
    required int limit,
    required int offset,
  }) async {
    requests.add('$platformId@$offset');
    onFetch?.call();
    if (failingPlatforms.contains(platformId)) {
      throw Exception('500 from the server');
    }
    final all = romsByPlatform[platformId] ?? const [];
    final end = (offset + limit).clamp(0, all.length);
    return RommRomPage(
      items: all.sublist(offset.clamp(0, all.length), end),
      total: all.length,
    );
  }
}

/// The refresh lines the run logged.
List<String> _refreshLines() => LoggerService.instance
    .takeCapture()
    .where((l) => l.contains('RomM catalog refresh'))
    .toList();

void main() {
  final snes = _system('snes');

  setUp(() => LoggerService.instance.startCapture());
  tearDown(() => LoggerService.instance.takeCapture());

  RommCatalogRefresh build(
    _FakeServer server,
    _FakeCatalog catalog, {
    RommLibraryLinker? linker,
    bool Function()? shouldStop,
    DateTime Function()? clock,
    String serverUrl = _server,
  }) => RommCatalogRefresh(
    listPlatforms: server.listPlatforms,
    resolveSystem: server.resolve,
    fetchPage: server.fetchPage,
    serverUrl: () => serverUrl,
    linker: linker,
    shouldStop: shouldStop,
    upsert: catalog.upsert,
    deleteUnseen: catalog.deleteUnseen,
    recordPlatform: catalog.recordPlatform,
    newestRefreshedAt: catalog.newestRefreshedAt,
    clock: clock,
  );

  RommLibraryLinker linkerFor(
    _FakeServer server,
    _FakeMap map,
    List<DatabaseGameModel> games,
  ) => RommLibraryLinker(
    listPlatforms: server.listPlatforms,
    resolveSystem: server.resolve,
    fetchPage: ({required platformId, required limit, required offset}) =>
        throw StateError('the refresh owns the walk'),
    listGames: () async => games,
    loadRomIdIndex: map.index,
    putMappingsIfAbsent: map.putIfAbsent,
  );

  group('one walk, two consumers', () {
    // Governing: SPEC-0019 REQ "Catalog Refresh Shares The Walk" — "One walk"
    test('each page is fetched once and feeds catalog and links', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Chrono Trigger (USA).sfc'),
            _rom(11, platformId: 1, fsName: 'Not Here.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();
      final map = _FakeMap();
      final linker = linkerFor(server, map, [
        _game('Chrono Trigger (USA).sfc', 'snes'),
      ]);

      final summary = await build(
        server,
        catalog,
        linker: linker,
      ).run(reason: RommRefreshReason.connect);

      expect(server.requests, ['1@0'], reason: 'one walk, one page');
      expect(catalog.rows.keys, unorderedEquals([10, 11]));
      expect(map.rows['snes\tChrono Trigger (USA).sfc'], 10);
      expect(summary.rowsUpserted, 2);
      expect(summary.platformsProcessed, 1);
      expect(summary.linkSummary?.rowsAdded, 1);
      expect(summary.linkSummary?.romsEnumerated, 2);
    });

    // The regression this story exists for: the link pass used to return
    // before the walk when nothing was unlinked, which would leave the catalog
    // empty forever on an already-linked library.
    test('a fully linked library is still walked for the catalog', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();
      final map = _FakeMap()..rows['snes\tGame.sfc'] = 10;
      final linker = linkerFor(server, map, [_game('Game.sfc', 'snes')]);

      final summary = await build(
        server,
        catalog,
        linker: linker,
      ).run(reason: RommRefreshReason.connect);

      expect(server.requests, ['1@0']);
      expect(catalog.rows.keys, [10]);
      expect(summary.rowsUpserted, 1);
      expect(
        summary.linkSummary,
        isNull,
        reason: 'the link stage had nothing to do; the walk happened anyway',
      );
    });

    test('a refresh with no linker walks for the catalog alone', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();

      final summary = await build(
        server,
        catalog,
      ).run(reason: RommRefreshReason.manual);

      expect(catalog.rows.keys, [10]);
      expect(summary.linkSummary, isNull);
    });

    test('an unresolved platform is counted and never paged', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'Mine Storm.vec')],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final catalog = _FakeCatalog();

      final summary = await build(
        server,
        catalog,
      ).run(reason: RommRefreshReason.manual);

      expect(summary.platformsUnresolved, 1);
      expect(server.requests, ['1@0']);
      expect(catalog.rows.keys, [10]);
    });
  });

  group('deletion', () {
    // Governing: SPEC-0019 REQ "Catalog Refresh Shares The Walk" — "Deleted on server"
    test('a completed platform prunes what it did not see', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();
      // A row the previous run left behind for a ROM the server no longer has.
      catalog.rows[99] = RommCatalogRow(
        serverUrl: _server,
        rommRomId: 99,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Deleted On Server',
        fsName: 'Deleted On Server.sfc',
        seenAt: DateTime.utc(2020),
      );

      final summary = await build(
        server,
        catalog,
      ).run(reason: RommRefreshReason.manual);

      expect(catalog.prunedPlatforms, [1]);
      expect(catalog.rows.keys, [10]);
      expect(summary.rowsDeleted, 1);
      expect(catalog.platformStamps[1], isNotNull);
      expect(catalog.platformCounts[1], 1);
    });

    // Governing: SPEC-0019 REQ "Error Handling Standards" — "Platform failure"
    test('a failed platform is counted and its rows are untouched', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
        failingPlatforms: {1},
      );
      final catalog = _FakeCatalog();
      catalog.rows[99] = RommCatalogRow(
        serverUrl: _server,
        rommRomId: 99,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Still On The Server',
        fsName: 'Still On The Server.sfc',
        seenAt: DateTime.utc(2020),
      );

      final summary = await build(
        server,
        catalog,
      ).run(reason: RommRefreshReason.manual);

      expect(summary.platformsFailed, 1);
      expect(summary.platformsProcessed, 1);
      expect(catalog.prunedPlatforms, [
        2,
      ], reason: 'only the platform that completed is pruned');
      expect(
        catalog.rows.containsKey(99),
        isTrue,
        reason: 'a partial view must never delete rows',
      );
      expect(catalog.platformStamps.containsKey(1), isFalse);
      final failure = LoggerService.instance.takeCapture().where(
        (l) => l.startsWith('w|') && l.contains('"snes"'),
      );
      expect(failure, hasLength(1), reason: 'named once, not swallowed');
    });

    // A platform can page to the end and still have lost a write chunk. Its
    // surviving rows keep an older `seen_at`, so pruning it would delete ROMs
    // that are still on the server.
    // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Error Handling Standards"
    test('a platform whose write failed is not pruned', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
      );
      final catalog = _FakeCatalog();
      catalog.failingWrites = {1};
      catalog.rows[99] = RommCatalogRow(
        serverUrl: _server,
        rommRomId: 99,
        platformId: 1,
        systemFolder: 'snes',
        name: 'Still On The Server',
        fsName: 'Still On The Server.sfc',
        seenAt: DateTime.utc(2020),
      );

      final summary = await build(
        server,
        catalog,
      ).run(reason: RommRefreshReason.manual);

      expect(catalog.prunedPlatforms, [
        2,
      ], reason: 'the platform that wrote cleanly is still pruned');
      expect(
        catalog.rows.containsKey(99),
        isTrue,
        reason: 'a half-written platform must never delete rows',
      );
      expect(
        catalog.platformStamps.containsKey(1),
        isFalse,
        reason: 'no fresh stamp, so the hourly guard lets the next run retry',
      );
      expect(summary.platformsFailed, 1);
      expect(summary.platformsProcessed, 1);
      final warned = LoggerService.instance.takeCapture().where(
        (l) => l.startsWith('w|') && l.contains('catalog write incomplete'),
      );
      expect(warned, hasLength(1), reason: 'said once per platform');
    });
  });

  group('guards', () {
    // Governing: SPEC-0019 REQ "Catalog Refresh Shares The Walk" — "Hourly guard"
    test('an automatic refresh 10 minutes later is skipped', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog()
        ..newest = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final summary = await build(
        server,
        catalog,
        clock: () => DateTime.utc(2026, 9, 6, 12, 10, 0),
      ).run(reason: RommRefreshReason.connect);

      expect(summary.ran, isFalse);
      expect(summary.skipped, RommRefreshSkip.tooSoon);
      expect(server.requests, isEmpty);
      final lines = _refreshLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('cause=too_soon'));
    });

    test('a manual or reconnect refresh ignores the guard', () async {
      for (final reason in [
        RommRefreshReason.manual,
        RommRefreshReason.reconnect,
      ]) {
        final server = _FakeServer(
          platforms: [_platform(1, 'snes')],
          romsByPlatform: {
            1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
          },
          systemBySlug: {'snes': snes},
        );
        final catalog = _FakeCatalog()
          ..newest = DateTime.utc(2026, 9, 6, 12, 0, 0);

        final summary = await build(
          server,
          catalog,
          clock: () => DateTime.utc(2026, 9, 6, 12, 10, 0),
        ).run(reason: reason);

        expect(summary.ran, isTrue, reason: '${reason.name} bypasses');
        expect(server.requests, ['1@0']);
      }
    });

    test('an automatic refresh an hour later runs', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog()
        ..newest = DateTime.utc(2026, 9, 6, 12, 0, 0);

      final summary = await build(
        server,
        catalog,
        clock: () => DateTime.utc(2026, 9, 6, 13, 30, 0),
      ).run(reason: RommRefreshReason.scheduled);

      expect(summary.ran, isTrue);
    });

    test('without a server nothing is walked', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: const {},
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();

      final summary = await build(
        server,
        catalog,
        serverUrl: '',
      ).run(reason: RommRefreshReason.manual);

      expect(summary.skipped, RommRefreshSkip.noServer);
      expect(server.requests, isEmpty);
    });

    test('a second run while one is in flight is refused', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final catalog = _FakeCatalog();
      final refresh = build(server, catalog);

      final first = refresh.run(reason: RommRefreshReason.manual);
      final second = await refresh.run(reason: RommRefreshReason.manual);

      expect(second.skipped, RommRefreshSkip.alreadyRunning);
      expect((await first).ran, isTrue);
      expect(refresh.isRunning, isFalse);
    });
  });

  group('cancellation', () {
    // Governing: SPEC-0019 REQ "Concurrency Safety" — "Disconnect mid-refresh"
    test('a stop between pages keeps the rows already written', () async {
      final roms = [
        for (var i = 0; i < 501; i++)
          _rom(1000 + i, platformId: 1, fsName: 'Game $i.sfc'),
      ];
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: roms},
        systemBySlug: {'snes': snes},
      );
      var stop = false;
      server.onFetch = () => stop = true;
      final catalog = _FakeCatalog();

      final summary = await build(
        server,
        catalog,
        shouldStop: () => stop,
      ).run(reason: RommRefreshReason.manual);

      expect(server.requests, ['1@0'], reason: 'no second page request');
      expect(summary.stoppedEarly, isTrue);
      expect(catalog.rows, hasLength(500), reason: 'the first page stays');
      expect(
        catalog.prunedPlatforms,
        isEmpty,
        reason: 'an unfinished platform is never pruned',
      );
    });
  });

  group('observability', () {
    test('exactly one summary line, in key=value form', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'A.sfc'),
            _rom(11, platformId: 1, fsName: 'B.sfc'),
          ],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final catalog = _FakeCatalog();
      var now = DateTime.utc(2026, 9, 6, 12);

      await build(
        server,
        catalog,
        clock: () {
          final t = now;
          now = now.add(const Duration(milliseconds: 250));
          return t;
        },
      ).run(reason: RommRefreshReason.manual);

      final lines = _refreshLines().where((l) => l.startsWith('i|')).toList();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        allOf([
          contains('reason=manual'),
          contains('platforms=1'),
          contains('unresolved=1'),
          contains('failed=0'),
          contains('rows_upserted=2'),
          contains('rows_deleted=0'),
          contains('elapsed_ms='),
        ]),
      );
    });
  });
}
