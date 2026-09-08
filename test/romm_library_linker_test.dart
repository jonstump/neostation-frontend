import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/rom_fingerprint.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/rom_fingerprint_service.dart';
import 'package:neostation/services/romm/romm_library_linker.dart';
import 'package:neostation/services/romm/romm_paging.dart';

/// The connect-time link pass ([RommLibraryLinker]) against in-memory fakes:
/// a server of platforms and ROM pages, a scanned library, and a mapping table
/// with insert-if-absent semantics. No filesystem, no database, no network —
/// the pass is supposed to need none of them (SPEC-0001 "Connect-Time Link
/// Pass": match the library index, not the disk).

RommRom _rom(
  int id, {
  required int platformId,
  required String fsName,
  String slug = 'snes',
  bool multiFile = false,
  String? crc,
  String? md5,
  int size = 0,
  List<RommRomFile> files = const [],
}) => RommRom(
  id: id,
  name: fsName,
  platformId: platformId,
  platformSlug: slug,
  fsName: fsName,
  fsNameNoExt: fsName.contains('.')
      ? fsName.substring(0, fsName.lastIndexOf('.'))
      : fsName,
  fsExtension: fsName.contains('.')
      ? fsName.substring(fsName.lastIndexOf('.') + 1)
      : '',
  hasMultipleFiles: multiFile,
  fsSizeBytes: size,
  crcHash: normalizeRommHash(crc),
  md5Hash: normalizeRommHash(md5),
  files: files,
);

RommRomFile _file(int id, {String? crc, String? md5, int size = 0}) =>
    RommRomFile(
      id: id,
      fileName: 'inner.bin',
      fileSizeBytes: size,
      crcHash: normalizeRommHash(crc),
      md5Hash: normalizeRommHash(md5),
    );

RommPlatform _platform(int id, String slug) =>
    RommPlatform(id: id, name: slug.toUpperCase(), slug: slug, romCount: 1);

SystemModel _system(String folder, {List<String> aliases = const []}) =>
    SystemModel(
      folderName: folder,
      realName: folder.toUpperCase(),
      iconImage: '/images/icons/$folder.png',
      color: '#000000',
      folders: [folder, ...aliases],
    );

DatabaseGameModel _game(
  String filename,
  String folder, {
  String? crc32,
  String? md5,
  int? size,
  String? skipped,
}) => DatabaseGameModel(
  filename: filename,
  romPath: '/roms/$folder/$filename',
  systemFolderName: folder,
  romCrc32: crc32,
  ssHash: md5,
  romSize: size,
  fingerprintSkipped: skipped,
);

/// The fingerprint step's two halves, faked: what each path answers, and
/// what was persisted.
class _FakeFingerprints {
  /// Answers per rom path; a path absent here answers `deferredCostly`.
  final Map<String, ({RomFingerprint? fingerprint, String? skipReason})>
  answers = {};

  /// Paths that throw instead of answering.
  final Set<String> throwing = {};

  /// Every path asked, in order.
  final List<String> asked = [];

  /// Every batch handed to the saver.
  final List<List<RomFingerprintWrite>> saved = [];

  /// Called before each answer, for tests that stop mid-step.
  void Function()? onFingerprint;

  Future<({RomFingerprint? fingerprint, String? skipReason})> fingerprint(
    String romPath,
    String? systemFolder,
  ) async {
    asked.add(romPath);
    onFingerprint?.call();
    if (throwing.contains(romPath)) throw StateError('unreadable');
    return answers[romPath] ??
        (fingerprint: null, skipReason: RomFingerprintService.deferredCostly);
  }

  Future<int> save(List<RomFingerprintWrite> writes) async {
    saved.add(writes);
    return writes.length;
  }

  /// Every write persisted, across batches.
  List<RomFingerprintWrite> get writes => [for (final b in saved) ...b];
}

RomFingerprint _fp(String crc32, {String? md5, int size = 1024}) =>
    RomFingerprint(crc32: crc32, md5: md5, sizeBytes: size);

/// The mapping table: `(systemFolder, filename)` → rom id, insert-if-absent.
class _FakeMap {
  final Map<String, int> rows = {};

  /// Provenance per key; a key absent here reads as `auto`, like a legacy
  /// null row does in the real index.
  final Map<String, RommLinkSource> sources = {};
  final List<List<RommSaveMapEntry>> batches = [];

  static String _key(String folder, String romname) => '$folder\t$romname';

  Future<int> putIfAbsent(List<RommSaveMapEntry> entries) async {
    batches.add(entries);
    var inserted = 0;
    for (final e in entries) {
      final key = _key(e.systemFolder, e.romname);
      if (rows.containsKey(key)) continue;
      rows[key] = e.rommRomId;
      sources[key] = e.source;
      inserted++;
    }
    return inserted;
  }

  /// A row the user picked by hand, as the picker writes it.
  void putManual(String folder, String filename, int romId) {
    rows[_key(folder, filename)] = romId;
    sources[_key(folder, filename)] = RommLinkSource.manual;
  }

  /// Same shape [RommSaveMapRepository.getRomIdIndex] builds — keyed on the
  /// stored (on-disk) spelling, which is what the linker asks for first.
  Future<RommRomIdIndex> index() async =>
      RommRomIdIndex(Map.of(rows), Map.of(sources));

  int? romIdFor(String folder, String filename) => rows[_key(folder, filename)];

  RommLinkSource? sourceFor(String folder, String filename) =>
      sources[_key(folder, filename)];
}

/// A RomM server: platforms, their ROMs, and what was asked of it.
class _FakeServer {
  final List<RommPlatform> platforms;
  final Map<int, List<RommRom>> romsByPlatform;
  final Map<String, SystemModel?> systemBySlug;
  final Set<int> failingPlatforms;

  /// `platformId@offset` per page request, in order.
  final List<String> requests = [];

  /// Called before each page is answered, for tests that stop mid-run.
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

RommLibraryLinker _linker(
  _FakeServer server,
  _FakeMap map,
  List<DatabaseGameModel> games, {
  bool Function()? shouldStop,
  _FakeFingerprints? fingerprints,
}) => RommLibraryLinker(
  listPlatforms: server.listPlatforms,
  resolveSystem: server.resolve,
  fetchPage: server.fetchPage,
  listGames: () async => games,
  loadRomIdIndex: map.index,
  putMappingsIfAbsent: map.putIfAbsent,
  fingerprintCheap: fingerprints?.fingerprint,
  saveFingerprints: fingerprints?.save,
  shouldStop: shouldStop,
);

/// The summary lines the pass logged, from the logger's capture.
List<String> _summaryLines() => LoggerService.instance
    .takeCapture()
    .where((l) => l.startsWith('i|RomM link pass'))
    .toList();

/// Enough ROMs to need more than one page: a full first page plus one, so
/// there is a second page request to complete or to stop before.
List<RommRom> _twoPages(int platformId) => [
  for (var i = 0; i < RommLibraryLinker.pageSize + 1; i++)
    _rom(1000 + i, platformId: platformId, fsName: 'Game $i.sfc'),
];

void main() {
  final snes = _system('snes');

  setUp(() => LoggerService.instance.startCapture());
  tearDown(() => LoggerService.instance.takeCapture());

  // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Connect-Time Link Pass"
  test('paging reuses bulk sync\'s page size and cap, from one definition', () {
    expect(RommLibraryLinker.pageSize, RommBulkSync.defaultPageSize);
    expect(RommLibraryLinker.pageCap, RommBulkSync.maxPages);
    expect(RommLibraryLinker.pageSize, RommPaging.pageSize);
    expect(RommLibraryLinker.pageCap, RommPaging.maxPages);
  });

  group('linking', () {
    test('an unlinked game whose filename matches is linked', () async {
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
      final map = _FakeMap();
      final games = [_game('Chrono Trigger (USA).sfc', 'snes')];

      final summary = await _linker(server, map, games).run();

      expect(map.romIdFor('snes', 'Chrono Trigger (USA).sfc'), 10);
      expect(map.rows, hasLength(1));
      expect(summary.rowsAdded, 1);
      expect(summary.rowsAlreadyPresent, 0);
      expect(summary.platformsProcessed, 1);
      expect(summary.romsEnumerated, 2);
      expect(summary.linkedRomnames, ['Chrono Trigger (USA)']);
      expect(map.batches.single.single.fsName, 'Chrono Trigger (USA).sfc');
    });

    test('case differs: linked under the library\'s own spelling', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Chrono Trigger (USA).sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();

      await _linker(server, map, [
        _game('chrono trigger (usa).sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'chrono trigger (usa).sfc'), 10);
    });

    test('a multi-disc playlist links to the multi-file ROM', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'psx')],
        romsByPlatform: {
          1: [
            _rom(
              10,
              platformId: 1,
              fsName: 'Final Fantasy VII (USA)',
              multiFile: true,
            ),
          ],
        },
        systemBySlug: {'psx': _system('psx')},
      );
      final map = _FakeMap();

      await _linker(server, map, [
        _game('Final Fantasy VII (USA).m3u', 'psx'),
      ]).run();

      expect(map.romIdFor('psx', 'Final Fantasy VII (USA).m3u'), 10);
    });

    test('a game the rom-id index already holds is skipped', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Linked.sfc'),
            _rom(11, platformId: 1, fsName: 'Unlinked.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..rows['snes\tLinked.sfc'] = 99;

      final summary = await _linker(server, map, [
        _game('Linked.sfc', 'snes'),
        _game('Unlinked.sfc', 'snes'),
      ]).run();

      expect(
        map.romIdFor('snes', 'Linked.sfc'),
        99,
        reason: 'never overwritten',
      );
      expect(map.romIdFor('snes', 'Unlinked.sfc'), 11);
      expect(summary.rowsAdded, 1);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.linkedRomnames, ['Unlinked']);
    });

    // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Existing Mappings Are Never Overwritten"
    test('a row pointing at a different ROM is kept and reported', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(40, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..rows['snes\tGame.sfc'] = 12;

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'Game.sfc'), 12, reason: 'never overwritten');
      expect(summary.rowsAdded, 0);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflictCount, 1);
      final conflict = summary.conflicts.single;
      expect(conflict.systemFolder, 'snes');
      expect(conflict.filename, 'Game.sfc');
      expect(conflict.existingRomId, 12);
      expect(
        conflict.existingSource,
        RommLinkSource.auto,
        reason: 'a row with no recorded source reads as automatic',
      );
      expect(conflict.matchedRomId, 40);

      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where((l) => l.startsWith('i|RomM link pass')).single,
        contains('1 conflicting'),
      );
      expect(
        lines.where((l) => l.startsWith('w|')).single,
        allOf([
          contains('snes/Game.sfc'),
          contains('rom 12'),
          contains('rom 40'),
        ]),
      );
    });

    // Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Manual Rows Are Never Replaced by Automatic Writers"
    test('a manual row matched to a different ROM is kept and reported '
        'with its source', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(40, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..putManual('snes', 'Game.sfc', 12);

      // An unlinked sibling keeps the pass from short-circuiting on a fully
      // linked library, which is the case under test for the manual row.
      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'Game.sfc'), 12, reason: 'the user\'s pick');
      expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.manual);
      expect(map.batches, isEmpty, reason: 'nothing was even offered');
      expect(summary.rowsAdded, 0);
      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflictCount, 1);
      final conflict = summary.conflicts.single;
      expect(conflict.systemFolder, 'snes');
      expect(conflict.filename, 'Game.sfc');
      expect(conflict.existingRomId, 12);
      expect(conflict.existingSource, RommLinkSource.manual);
      expect(conflict.matchedRomId, 40);
      expect(conflict.toString(), contains('manual'));

      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where((l) => l.startsWith('i|RomM link pass')).single,
        contains('1 conflicting'),
      );
      expect(
        lines.where((l) => l.startsWith('w|')).single,
        allOf([
          contains('snes/Game.sfc'),
          contains('rom 12'),
          contains('manual'),
          contains('rom 40'),
        ]),
      );
    });

    test('a manual row the pass agrees with is no conflict', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(12, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..putManual('snes', 'Game.sfc', 12);

      // An unlinked sibling keeps the pass from short-circuiting on a fully
      // linked library, which is the case under test for the manual row.
      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflicts, isEmpty);
      expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.manual);
    });

    test('a row the pass agrees with is no conflict', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(12, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..rows['snes\tGame.sfc'] = 12;

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
        _game('Other.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAlreadyPresent, 1);
      expect(summary.conflicts, isEmpty);
      expect(_summaryLines().single, contains('0 conflicting'));
    });

    test('a file under a folder alias of the resolved system links', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'segacd')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Sonic CD (USA).chd')],
        },
        systemBySlug: {
          'segacd': _system('scd', aliases: ['segacd']),
        },
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic CD (USA).chd', 'segacd'),
      ]).run();

      expect(summary.rowsAdded, 1);
      expect(
        map.romIdFor('segacd', 'Sonic CD (USA).chd'),
        10,
        reason: 'written under the folder the library row carries',
      );
    });

    test('a platform spanning two pages is paged to the end', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: _twoPages(1)},
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      const last = RommLibraryLinker.pageSize;

      final summary = await _linker(server, map, [
        _game('Game 0.sfc', 'snes'),
        _game('Game $last.sfc', 'snes'),
      ]).run();

      expect(server.requests, [
        '1@0',
        '1@${RommLibraryLinker.pageSize}',
      ], reason: 'the second page is requested at the first page\'s end');
      expect(map.romIdFor('snes', 'Game 0.sfc'), 1000);
      expect(
        map.romIdFor('snes', 'Game $last.sfc'),
        1000 + last,
        reason: 'a ROM on the second page links',
      );
      expect(map.batches, hasLength(1), reason: 'one write per system group');
      expect(summary.platformsProcessed, 1);
      expect(summary.romsEnumerated, RommLibraryLinker.pageSize + 1);
      expect(summary.rowsAdded, 2);
      expect(summary.stoppedEarly, isFalse);
    });
  });

  group('nothing to link', () {
    // Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fill Gaps On Link Confirm"
    test('links 400 games without a single detail request', () async {
      // The linker's whole server surface is [RommLibraryLinker.listPlatforms]
      // and [RommLibraryLinker.fetchPage]; no detail fetcher can even be
      // injected. So every request the fake server saw must be a page
      // request, and the count is a function of the page size, not of the
      // number of games linked.
      final roms = [
        for (var i = 0; i < 400; i++)
          _rom(1 + i, platformId: 1, fsName: 'Game $i.sfc'),
      ];
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: roms},
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final games = [for (final r in roms) _game(r.fsName, 'snes')];

      final summary = await _linker(server, map, games).run();

      expect(summary.rowsAdded, 400);
      expect(map.rows, hasLength(400));
      expect(
        server.requests,
        everyElement(matches(RegExp(r'^1@\d+$'))),
        reason: 'page requests only',
      );
      expect(
        server.requests.length,
        (400 / RommLibraryLinker.pageSize).ceil(),
        reason: 'one request per page, none per game',
      );
    });

    test('every game already linked: no server traffic, zero rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap()..rows['snes\tGame.sfc'] = 10;

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes'),
      ]).run();

      expect(summary.rowsAdded, 0);
      expect(server.requests, isEmpty);
      expect(map.batches, isEmpty);
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(lines.single, contains('0 rows added'));
    });

    test('an empty library: zero rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final summary = await _linker(server, _FakeMap(), []).run();

      expect(summary.rowsAdded, 0);
      expect(server.requests, isEmpty);
    });

    test('reconnect: a second run adds nothing and writes nothing', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'A.sfc'),
            _rom(11, platformId: 1, fsName: 'B.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final games = [_game('A.sfc', 'snes'), _game('B.sfc', 'snes')];

      final first = await _linker(server, map, games).run();
      final second = await _linker(server, map, games).run();

      expect(first.rowsAdded, 2);
      expect(second.rowsAdded, 0);
      expect(map.rows, hasLength(2), reason: 'no duplicates');
      expect(map.batches, hasLength(1), reason: 'the second run wrote nothing');
    });
  });

  group('platforms', () {
    test('an unresolved platform is counted and yields no rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [
            _rom(20, platformId: 2, fsName: 'Mine Storm.vec', slug: 'vectrex'),
          ],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('Mine Storm.vec', 'vectrex'),
      ]).run();

      expect(summary.platformsUnresolved, 1);
      expect(summary.unresolvedSlugs, ['vectrex']);
      expect(summary.platformsProcessed, 1);
      expect(map.romIdFor('vectrex', 'Mine Storm.vec'), isNull);
      expect(map.rows, hasLength(1));
      expect(
        server.requests.where((r) => r.startsWith('2@')),
        isEmpty,
        reason: 'an unresolved platform is not paged',
      );
      expect(_summaryLines().single, contains('unresolved: vectrex'));
    });

    test('two platforms on one system claiming one file is skipped', () async {
      final genesis = _system('genesis');
      final server = _FakeServer(
        platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Sonic.md', slug: 'genesis'),
            _rom(
              11,
              platformId: 1,
              fsName: 'Streets of Rage.md',
              slug: 'genesis',
            ),
          ],
          2: [_rom(20, platformId: 2, fsName: 'Sonic.md', slug: 'megadrive')],
        },
        systemBySlug: {'genesis': genesis, 'megadrive': genesis},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic.md', 'genesis'),
        _game('Streets of Rage.md', 'genesis'),
      ]).run();

      expect(map.romIdFor('genesis', 'Sonic.md'), isNull);
      expect(map.romIdFor('genesis', 'Streets of Rage.md'), 11);
      expect(summary.ambiguousSkipped, 1);
      expect(summary.ambiguities.single.filename, 'Sonic.md');
      expect(summary.ambiguities.single.romIds, [10, 20]);
      final line = _summaryLines().single;
      expect(line, contains('1 ambiguous skipped'));
      expect(line, contains('genesis/Sonic.md (10, 20)'));
    });

    test('a failing platform is logged, counted and stepped over', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
        failingPlatforms: {1},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ]).run();

      expect(summary.platformFailures, 1);
      expect(summary.platformsProcessed, 1);
      expect(map.romIdFor('snes', 'A.sfc'), isNull);
      expect(map.romIdFor('nes', 'B.nes'), 20);
      final captured = LoggerService.instance.takeCapture();
      expect(
        captured.where((l) => l.startsWith('w|') && l.contains('"snes"')),
        hasLength(1),
        reason: 'the platform and the error are named',
      );
      expect(
        captured.where((l) => l.startsWith('i|RomM link pass')),
        hasLength(1),
      );
      expect(captured.last, contains('1 failed'));
    });

    test('a failed platform leaves its whole system group unwritten', () async {
      // Sonic.md is on both platforms; with megadrive failing, genesis alone
      // would see it as a single claim and write a guess that never-overwrite
      // then makes permanent. The group must write nothing.
      final genesis = _system('genesis');
      final server = _FakeServer(
        platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'Sonic.md', slug: 'genesis'),
            _rom(
              11,
              platformId: 1,
              fsName: 'Streets of Rage.md',
              slug: 'genesis',
            ),
          ],
          2: [_rom(20, platformId: 2, fsName: 'Sonic.md', slug: 'megadrive')],
        },
        systemBySlug: {'genesis': genesis, 'megadrive': genesis},
        failingPlatforms: {2},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic.md', 'genesis'),
        _game('Streets of Rage.md', 'genesis'),
      ]).run();

      expect(map.rows, isEmpty);
      expect(map.batches, isEmpty, reason: 'the group is never written');
      expect(map.romIdFor('genesis', 'Sonic.md'), isNull);
      expect(
        map.romIdFor('genesis', 'Streets of Rage.md'),
        isNull,
        reason: 'even the unambiguous survivor waits for the next connect',
      );
      expect(summary.platformFailures, 1);
      expect(summary.platformsProcessed, 1);
      expect(summary.groupsSkipped, 1);
      expect(summary.rowsAdded, 0);
      expect(summary.ambiguousSkipped, 0);
      expect(summary.linkedRomnames, isEmpty);
      final captured = LoggerService.instance.takeCapture();
      expect(
        captured.where(
          (l) => l.startsWith('w|') && l.contains('skipped system "genesis"'),
        ),
        hasLength(1),
      );
      expect(captured.last, contains('1 failed'));
      expect(captured.last, contains('1 systems skipped after a failure'));
    });

    test('a failed platform alone on its system skips no group', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
        failingPlatforms: {1},
      );

      final summary = await _linker(server, _FakeMap(), [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ]).run();

      expect(summary.platformFailures, 1);
      expect(summary.groupsSkipped, 0);
      expect(summary.rowsAdded, 1);
    });

    // Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Filename Equivalence Rule"
    test(
      'a platform that resolved to nothing is asked again next run',
      () async {
        // The resolver answers null once (the systems table unreadable for a
        // moment) and then resolves. Nothing about the first run may pin the
        // platform to "unresolved" for the second.
        final server = _FakeServer(
          platforms: [_platform(1, 'snes')],
          romsByPlatform: {
            1: [_rom(10, platformId: 1, fsName: 'Game.sfc')],
          },
          systemBySlug: {'snes': null},
        );
        final map = _FakeMap();
        final linker = _linker(server, map, [_game('Game.sfc', 'snes')]);

        final first = await linker.run();
        expect(first.platformsUnresolved, 1);
        expect(first.rowsAdded, 0);

        server.systemBySlug['snes'] = snes;
        final second = await linker.run();

        expect(second.platformsUnresolved, 0);
        expect(second.rowsAdded, 1);
        expect(map.romIdFor('snes', 'Game.sfc'), 10);
      },
    );

    test('a throwing system resolver is wrapped, not thrown raw', () async {
      final linker = RommLibraryLinker(
        listPlatforms: () async => [_platform(1, 'snes')],
        resolveSystem: (_) async => throw StateError('systems table closed'),
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => [_game('A.sfc', 'snes')],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => 0,
      );

      await expectLater(
        linker.run(),
        throwsA(
          isA<RommLinkPassException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('platform resolution failed'),
              contains('systems table closed'),
            ),
          ),
        ),
      );
      expect(linker.isRunning, isFalse);
    });

    test('a library or platform listing failure is wrapped', () async {
      final linker = RommLibraryLinker(
        listPlatforms: () async => throw Exception('connection refused'),
        resolveSystem: (_) async => snes,
        fetchPage: ({required platformId, required limit, required offset}) =>
            throw UnimplementedError(),
        listGames: () async => [_game('A.sfc', 'snes')],
        loadRomIdIndex: () async => const RommRomIdIndex({}),
        putMappingsIfAbsent: (_) async => 0,
      );

      await expectLater(
        linker.run(),
        throwsA(
          isA<RommLinkPassException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('platform enumeration failed'),
              contains('connection refused'),
            ),
          ),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a stop between pages writes no further rows', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {1: _twoPages(1)},
        systemBySlug: {'snes': snes},
      );
      var stop = false;
      server.onFetch = () => stop = true;
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game 0.sfc', 'snes'),
        _game('Game 500.sfc', 'snes'),
      ], shouldStop: () => stop).run();

      expect(server.requests, ['1@0'], reason: 'no second page request');
      expect(map.batches, isEmpty);
      expect(summary.stoppedEarly, isTrue);
      expect(summary.rowsAdded, 0);
      expect(_summaryLines().single, startsWith('i|RomM link pass stopped'));
    });

    test('a stop between platforms keeps what was written', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'nes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
          2: [_rom(20, platformId: 2, fsName: 'B.nes', slug: 'nes')],
        },
        systemBySlug: {'snes': snes, 'nes': _system('nes')},
      );
      final map = _FakeMap();
      // Disconnect as soon as anything has been written.
      final summary = await _linker(server, map, [
        _game('A.sfc', 'snes'),
        _game('B.nes', 'nes'),
      ], shouldStop: () => map.rows.isNotEmpty).run();

      expect(map.romIdFor('snes', 'A.sfc'), 10);
      expect(map.romIdFor('nes', 'B.nes'), isNull);
      expect(server.requests, ['1@0']);
      expect(summary.stoppedEarly, isTrue);
      expect(summary.rowsAdded, 1);
      expect(summary.platformsProcessed, 1);
    });

    test('a run while one is in flight is refused', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [_rom(10, platformId: 1, fsName: 'A.sfc')],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final linker = _linker(server, map, [_game('A.sfc', 'snes')]);

      final first = linker.run();
      expect(linker.isRunning, isTrue);
      final second = await linker.run();
      expect(second.rowsAdded, 0);
      expect((await first).rowsAdded, 1);
      expect(linker.isRunning, isFalse);
    });
  });

  group('observability', () {
    test('exactly one summary line, with every count', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes'), _platform(2, 'vectrex')],
        romsByPlatform: {
          1: [
            _rom(10, platformId: 1, fsName: 'A.sfc'),
            _rom(11, platformId: 1, fsName: 'B.sfc'),
            _rom(12, platformId: 1, fsName: 'C.sfc'),
          ],
        },
        systemBySlug: {'snes': snes, 'vectrex': null},
      );
      final map = _FakeMap()..rows['snes\tB.sfc'] = 11;
      var now = DateTime(2026, 9, 4, 12, 0, 0);
      final linker = RommLibraryLinker(
        listPlatforms: server.listPlatforms,
        resolveSystem: server.resolve,
        fetchPage: server.fetchPage,
        listGames: () async => [
          _game('A.sfc', 'snes'),
          _game('B.sfc', 'snes'),
          _game('Z.sfc', 'snes'),
        ],
        loadRomIdIndex: map.index,
        putMappingsIfAbsent: map.putIfAbsent,
        clock: () {
          final t = now;
          now = now.add(const Duration(milliseconds: 250));
          return t;
        },
      );

      final summary = await linker.run();

      expect(summary.elapsed, const Duration(milliseconds: 250));
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        allOf([
          contains('1 platforms processed'),
          contains('1 unresolved'),
          contains('0 failed'),
          contains('0 systems skipped after a failure'),
          contains('3 ROMs enumerated'),
          contains('1 rows added'),
          contains('0 hash rows added'),
          contains('1 already present'),
          contains('0 ambiguous skipped'),
          contains('0 conflicting'),
          contains('0 fingerprints computed'),
          contains('0 fingerprints skipped'),
          contains('0 fingerprints left for the next pass'),
          contains('0 hash mismatches'),
          contains('250 ms'),
        ]),
      );
    });

    test('no per-game line at info level', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            for (var i = 0; i < 40; i++)
              _rom(i, platformId: 1, fsName: '$i.sfc'),
          ],
        },
        systemBySlug: {'snes': snes},
      );

      await _linker(server, _FakeMap(), [
        for (var i = 0; i < 40; i += 2) _game('$i.sfc', 'snes'),
      ]).run();

      final info = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('i|'))
          .toList();
      expect(info, hasLength(1));
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Matching Stage"
  group('hash stage', () {
    _FakeServer serverWith(List<RommRom> roms) => _FakeServer(
      platforms: [_platform(1, 'snes')],
      romsByPlatform: {1: roms},
      systemBySlug: {'snes': snes},
    );

    test('a renamed file links by crc32 with source hash', () async {
      final server = serverWith([
        _rom(
          10,
          platformId: 1,
          fsName: 'Super Game (USA).zip',
          crc: 'deadbeef',
        ),
        _rom(11, platformId: 1, fsName: 'Other.zip', crc: 'cafebabe'),
      ]);
      final map = _FakeMap();

      // Persisted uppercase, as RomFingerprint writes it; RomM's is lowercase.
      final summary = await _linker(server, map, [
        _game('Super Game (U).zip', 'snes', crc32: 'DEADBEEF'),
      ]).run();

      expect(map.romIdFor('snes', 'Super Game (U).zip'), 10);
      expect(map.sourceFor('snes', 'Super Game (U).zip'), RommLinkSource.hash);
      expect(map.batches.single.single.source, RommLinkSource.hash);
      expect(map.batches.single.single.fsName, 'Super Game (USA).zip');
      expect(
        summary.rowsAdded,
        0,
        reason: 'the filename stage matched nothing',
      );
      expect(summary.hashRowsAdded, 1);
      expect(summary.hashMismatches, 0);
      expect(summary.linkedRomnames, ['Super Game (U)']);
      expect(server.requests, ['1@0'], reason: 'no extra request');
      expect(_summaryLines().single, contains('1 hash rows added'));
    });

    test('a file-level hash matches when the ROM level has none', () async {
      final server = serverWith([
        _rom(
          10,
          platformId: 1,
          fsName: 'Set.zip',
          files: [_file(1, crc: 'deadbeef')],
        ),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Renamed.zip', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.romIdFor('snes', 'Renamed.zip'), 10);
      expect(summary.hashRowsAdded, 1);
    });

    test('an md5 disagreement blocks the link and is counted', () async {
      final server = serverWith([
        _rom(
          10,
          platformId: 1,
          fsName: 'Game (USA).sfc',
          crc: 'deadbeef',
          md5: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game(
          'Game (U).sfc',
          'snes',
          crc32: 'deadbeef',
          md5: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        ),
      ]).run();

      expect(map.rows, isEmpty);
      expect(map.batches, isEmpty);
      expect(summary.hashRowsAdded, 0);
      expect(summary.hashMismatches, 1);
      expect(_summaryLines().single, contains('1 hash mismatches'));
    });

    test('an md5 known on one side only does not veto', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).sfc', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game(
          'Game (U).sfc',
          'snes',
          crc32: 'deadbeef',
          md5: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ]).run();

      expect(map.romIdFor('snes', 'Game (U).sfc'), 10);
      expect(summary.hashMismatches, 0);
    });

    test('a size disagreement on a bare file blocks the link', () async {
      final server = serverWith([
        _rom(
          10,
          platformId: 1,
          fsName: 'Game (USA).sfc',
          crc: 'deadbeef',
          size: 4096,
        ),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game (U).sfc', 'snes', crc32: 'deadbeef', size: 8192),
      ]).run();

      expect(map.rows, isEmpty);
      expect(summary.hashMismatches, 1);
    });

    test('an archive\'s size is not compared: the local size is the inner '
        'image\'s, RomM\'s is the stored file\'s', () async {
      final server = serverWith([
        _rom(
          10,
          platformId: 1,
          fsName: 'Game (USA).zip',
          crc: 'deadbeef',
          size: 4096,
        ),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game (U).zip', 'snes', crc32: 'deadbeef', size: 8192),
      ]).run();

      expect(map.romIdFor('snes', 'Game (U).zip'), 10);
      expect(summary.hashMismatches, 0);
    });

    test('a crc32 matching two ROM ids is skipped as ambiguous', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).sfc', crc: 'deadbeef'),
        _rom(11, platformId: 1, fsName: 'Game (Europe).sfc', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.rows, isEmpty);
      expect(summary.hashRowsAdded, 0);
      expect(summary.ambiguousSkipped, 1);
      expect(summary.ambiguities.single.filename, 'Game.sfc');
      expect(summary.ambiguities.single.romIds, [10, 11]);
      expect(_summaryLines().single, contains('snes/Game.sfc (10, 11)'));
    });

    test(
      'a veto on one of two candidates leaves an unambiguous match',
      () async {
        final server = serverWith([
          _rom(10, platformId: 1, fsName: 'A.sfc', crc: 'deadbeef', md5: 'aa'),
          _rom(11, platformId: 1, fsName: 'B.sfc', crc: 'deadbeef', md5: 'bb'),
        ]);
        final map = _FakeMap();

        final summary = await _linker(server, map, [
          _game('Game.sfc', 'snes', crc32: 'deadbeef', md5: 'bb'),
        ]).run();

        expect(map.romIdFor('snes', 'Game.sfc'), 11);
        expect(summary.ambiguousSkipped, 0);
        expect(summary.hashMismatches, 0);
      },
    );

    test('a filename match takes precedence over a hash match', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game.sfc', crc: '11111111'),
        _rom(11, platformId: 1, fsName: 'Same Bytes.sfc', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game.sfc', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.romIdFor('snes', 'Game.sfc'), 10);
      expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.auto);
      expect(summary.rowsAdded, 1);
      expect(summary.hashRowsAdded, 0);
      expect(summary.ambiguousSkipped, 0);
    });

    test(
      'a game the filename stage found ambiguous is not hash-linked',
      () async {
        final genesis = _system('genesis');
        final server = _FakeServer(
          platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
          romsByPlatform: {
            1: [_rom(10, platformId: 1, fsName: 'Sonic.md', slug: 'genesis')],
            2: [
              _rom(
                20,
                platformId: 2,
                fsName: 'Sonic.md',
                slug: 'megadrive',
                crc: 'deadbeef',
              ),
            ],
          },
          systemBySlug: {'genesis': genesis, 'megadrive': genesis},
        );
        final map = _FakeMap();

        final summary = await _linker(server, map, [
          _game('Sonic.md', 'genesis', crc32: 'deadbeef'),
        ]).run();

        expect(map.rows, isEmpty);
        expect(summary.ambiguousSkipped, 1);
        expect(summary.hashRowsAdded, 0);
      },
    );

    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Hash Rows Follow The Link Rules"
    test(
      'a manual row is untouched and the hash match is a conflict',
      () async {
        final server = serverWith([
          _rom(9, platformId: 1, fsName: 'Game (USA).sfc', crc: 'deadbeef'),
        ]);
        final map = _FakeMap()..putManual('snes', 'Game.sfc', 7);

        final summary = await _linker(server, map, [
          _game('Game.sfc', 'snes', crc32: 'deadbeef'),
          _game('Other.sfc', 'snes'),
        ]).run();

        expect(map.romIdFor('snes', 'Game.sfc'), 7);
        expect(map.sourceFor('snes', 'Game.sfc'), RommLinkSource.manual);
        expect(map.batches, isEmpty, reason: 'nothing was even offered');
        expect(summary.hashRowsAdded, 0);
        expect(summary.rowsAlreadyPresent, 1);
        final conflict = summary.conflicts.single;
        expect(conflict.filename, 'Game.sfc');
        expect(conflict.existingRomId, 7);
        expect(conflict.existingSource, RommLinkSource.manual);
        expect(conflict.matchedRomId, 9);
        expect(
          LoggerService.instance.takeCapture().where((l) => l.startsWith('w|')),
          hasLength(1),
        );
      },
    );

    test(
      'a linked game whose row the hash agrees with is no conflict',
      () async {
        final server = serverWith([
          _rom(7, platformId: 1, fsName: 'Game (USA).sfc', crc: 'deadbeef'),
        ]);
        final map = _FakeMap()..rows['snes\tGame.sfc'] = 7;

        final summary = await _linker(server, map, [
          _game('Game.sfc', 'snes', crc32: 'deadbeef'),
          _game('Other.sfc', 'snes'),
        ]).run();

        expect(summary.conflicts, isEmpty);
        expect(summary.rowsAlreadyPresent, 1);
      },
    );

    test('two local files with one crc32 both link to the same ROM', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).sfc', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game (U).sfc', 'snes', crc32: 'deadbeef'),
        _game('Game (U) [!].sfc', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.romIdFor('snes', 'Game (U).sfc'), 10);
      expect(map.romIdFor('snes', 'Game (U) [!].sfc'), 10);
      expect(summary.hashRowsAdded, 2);
      expect(map.batches, hasLength(1), reason: 'one write per system group');
    });

    test('filename and hash rows go in one batch per group', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'By Name.sfc'),
        _rom(11, platformId: 1, fsName: 'By Hash (USA).sfc', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('By Name.sfc', 'snes'),
        _game('By Hash.sfc', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.batches, hasLength(1));
      expect(map.batches.single.map((e) => e.source), [
        RommLinkSource.auto,
        RommLinkSource.hash,
      ]);
      expect(summary.rowsAdded, 1);
      expect(summary.hashRowsAdded, 1);
      expect(summary.linkedRomnames, ['By Name', 'By Hash']);
    });

    test('a server without hashes adds no hash rows', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).sfc'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Game (U).sfc', 'snes', crc32: 'deadbeef'),
      ]).run();

      expect(map.rows, isEmpty);
      expect(summary.hashRowsAdded, 0);
      expect(summary.hashMismatches, 0);
    });

    test('a failed platform in a multi-platform group writes no hash rows '
        'either', () async {
      final genesis = _system('genesis');
      final server = _FakeServer(
        platforms: [_platform(1, 'genesis'), _platform(2, 'megadrive')],
        romsByPlatform: {
          1: [
            _rom(
              10,
              platformId: 1,
              fsName: 'Sonic (USA).md',
              slug: 'genesis',
              crc: 'deadbeef',
            ),
          ],
          2: [],
        },
        systemBySlug: {'genesis': genesis, 'megadrive': genesis},
        failingPlatforms: {2},
      );
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('Sonic.md', 'genesis', crc32: 'deadbeef'),
      ]).run();

      expect(map.batches, isEmpty);
      expect(summary.groupsSkipped, 1);
      expect(summary.hashRowsAdded, 0);
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  group('fingerprint step', () {
    _FakeServer serverWith(List<RommRom> roms) => _FakeServer(
      platforms: [_platform(1, 'snes')],
      romsByPlatform: {1: roms},
      systemBySlug: {'snes': snes},
    );

    test('unlinked games without a crc32 are fingerprinted, persisted and '
        'matched in the same run', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).zip', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();
      final fingerprints = _FakeFingerprints()
        ..answers['/roms/snes/Game (U).zip'] = (
          fingerprint: _fp('DEADBEEF', size: 4096),
          skipReason: null,
        );

      final summary = await _linker(server, map, [
        _game('Game (U).zip', 'snes'),
      ], fingerprints: fingerprints).run();

      expect(fingerprints.asked, ['/roms/snes/Game (U).zip']);
      expect(fingerprints.saved, hasLength(1), reason: 'one batch');
      final write = fingerprints.writes.single;
      expect(write.romPath, '/roms/snes/Game (U).zip');
      expect(write.crc32, 'DEADBEEF');
      expect(write.md5, isNull);
      expect(write.size, 4096);
      expect(write.skipReason, isNull);
      expect(map.romIdFor('snes', 'Game (U).zip'), 10);
      expect(map.sourceFor('snes', 'Game (U).zip'), RommLinkSource.hash);
      expect(summary.fingerprintsComputed, 1);
      expect(summary.fingerprintsSkipped, 0);
      expect(summary.hashRowsAdded, 1);
      expect(_summaryLines().single, contains('1 fingerprints computed'));
    });

    test('games with a crc32, parked games, linked games and games the '
        'filename stage claimed are not fingerprinted', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Named.zip'),
        _rom(11, platformId: 1, fsName: 'Hashed (USA).zip', crc: 'deadbeef'),
      ]);
      final map = _FakeMap()..rows['snes\tLinked.zip'] = 99;
      final fingerprints = _FakeFingerprints();

      await _linker(server, map, [
        _game('Named.zip', 'snes'),
        _game('Hashed.zip', 'snes', crc32: 'deadbeef'),
        _game('Parked.zip', 'snes', skipped: 'oversize'),
        _game('Linked.zip', 'snes'),
        _game('Fresh.zip', 'snes'),
      ], fingerprints: fingerprints).run();

      expect(fingerprints.asked, ['/roms/snes/Fresh.zip']);
    });

    test(
      'a skip reason is persisted and counted; the pass continues',
      () async {
        final server = serverWith([
          _rom(10, platformId: 1, fsName: 'Game (USA).zip', crc: 'deadbeef'),
        ]);
        final map = _FakeMap();
        final fingerprints = _FakeFingerprints()
          ..answers['/roms/snes/Disc.chd'] = (
            fingerprint: null,
            skipReason: RomFingerprintService.skipDisc,
          )
          ..answers['/roms/snes/Game (U).zip'] = (
            fingerprint: _fp('deadbeef'),
            skipReason: null,
          );

        final summary = await _linker(server, map, [
          _game('Disc.chd', 'snes'),
          _game('Game (U).zip', 'snes'),
        ], fingerprints: fingerprints).run();

        expect(fingerprints.saved, hasLength(1));
        final skip = fingerprints.writes.firstWhere(
          (w) => w.romPath == '/roms/snes/Disc.chd',
        );
        expect(skip.crc32, isNull);
        expect(skip.skipReason, RomFingerprintService.skipDisc);
        expect(summary.fingerprintsSkipped, 1);
        expect(summary.fingerprintsComputed, 1);
        expect(map.romIdFor('snes', 'Game (U).zip'), 10);
      },
    );

    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Error Handling Standards"
    test('a fingerprinter that throws parks the file as an error, names it, '
        'and the pass continues', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).zip', crc: 'deadbeef'),
      ]);
      final map = _FakeMap();
      final fingerprints = _FakeFingerprints()
        ..throwing.add('/roms/snes/Broken.zip')
        ..answers['/roms/snes/Game (U).zip'] = (
          fingerprint: _fp('deadbeef'),
          skipReason: null,
        );

      final summary = await _linker(server, map, [
        _game('Broken.zip', 'snes'),
        _game('Game (U).zip', 'snes'),
      ], fingerprints: fingerprints).run();

      final skip = fingerprints.writes.firstWhere(
        (w) => w.romPath == '/roms/snes/Broken.zip',
      );
      expect(skip.skipReason, RomFingerprintService.skipError);
      expect(summary.fingerprintsSkipped, 1);
      expect(summary.fingerprintsComputed, 1);
      expect(map.romIdFor('snes', 'Game (U).zip'), 10);
      final warnings = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('w|'))
          .toList();
      expect(warnings.single, contains('snes/Broken.zip'));
      expect(warnings.single, contains('unreadable'));
    });

    test(
      'a deferred fingerprint is neither persisted nor charged to the cap',
      () async {
        final server = serverWith([
          _rom(10, platformId: 1, fsName: 'Game (USA).zip', crc: 'deadbeef'),
        ]);
        final map = _FakeMap();
        // Every bare ROM answers deferredCostly (the fake's default); if those
        // consumed the cap, the zip behind them would never be reached.
        final games = [
          for (var i = 0; i < RommLibraryLinker.fingerprintCapPerPass + 10; i++)
            _game('Bare $i.sfc', 'snes'),
          _game('Game (U).zip', 'snes'),
        ];
        final fingerprints = _FakeFingerprints()
          ..answers['/roms/snes/Game (U).zip'] = (
            fingerprint: _fp('deadbeef'),
            skipReason: null,
          );

        final summary = await _linker(
          server,
          map,
          games,
          fingerprints: fingerprints,
        ).run();

        expect(fingerprints.asked, hasLength(games.length));
        expect(fingerprints.writes, hasLength(1));
        expect(fingerprints.writes.single.romPath, '/roms/snes/Game (U).zip');
        expect(summary.fingerprintsComputed, 1);
        // Deferred is its own count: nothing was parked, so the line must
        // not read as N files skipped on every pass over a bare-ROM library.
        expect(
          summary.fingerprintsDeferred,
          RommLibraryLinker.fingerprintCapPerPass + 10,
        );
        expect(summary.fingerprintsSkipped, 0);
        expect(summary.fingerprintsRemaining, 0);
        expect(map.romIdFor('snes', 'Game (U).zip'), 10);
        expect(
          _summaryLines().single,
          allOf([
            contains('0 fingerprints skipped'),
            contains(
              '${RommLibraryLinker.fingerprintCapPerPass + 10} '
              'fingerprints deferred',
            ),
          ]),
        );
      },
    );

    test('a group the server sent no hashes for is not fingerprinted, and '
        'the skip is logged once with the system', () async {
      // Nothing computed now could match this pass, so the zip-tail reads
      // are not spent; the games stay unfingerprinted for a pass that has
      // hashes to match against.
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'Game (USA).zip'),
      ]);
      final map = _FakeMap();
      final fingerprints = _FakeFingerprints()
        ..answers['/roms/snes/Game (U).zip'] = (
          fingerprint: _fp('deadbeef'),
          skipReason: null,
        );

      final summary = await _linker(server, map, [
        _game('Game (U).zip', 'snes'),
        _game('Other.zip', 'snes'),
      ], fingerprints: fingerprints).run();

      expect(fingerprints.asked, isEmpty, reason: 'nothing could match');
      expect(fingerprints.saved, isEmpty);
      expect(map.rows, isEmpty);
      expect(summary.fingerprintsComputed, 0);
      expect(summary.fingerprintsSkipped, 0);
      expect(summary.fingerprintsDeferred, 0);
      expect(summary.fingerprintsRemaining, 0);
      final info = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('i|'))
          .toList();
      expect(info, hasLength(2), reason: 'the skip line, then the summary');
      expect(
        info.first,
        allOf([contains('"snes"'), contains('no hashes'), contains('2 files')]),
      );
      expect(info.last, startsWith('i|RomM link pass complete'));
    });

    test(
      'the per-pass cap is respected and the remainder is reported',
      () async {
        const cap = RommLibraryLinker.fingerprintCapPerPass;
        const total = 900;
        final server = serverWith([
          for (var i = 0; i < total; i++)
            _rom(
              1000 + i,
              platformId: 1,
              fsName: 'Game $i (USA).zip',
              crc: i.toRadixString(16).padLeft(8, '0'),
            ),
        ]);
        final map = _FakeMap();
        final fingerprints = _FakeFingerprints();
        final games = <DatabaseGameModel>[];
        for (var i = 0; i < total; i++) {
          final game = _game('Game $i.zip', 'snes');
          games.add(game);
          fingerprints.answers[game.romPath] = (
            fingerprint: _fp(i.toRadixString(16).padLeft(8, '0').toUpperCase()),
            skipReason: null,
          );
        }

        final summary = await _linker(
          server,
          map,
          games,
          fingerprints: fingerprints,
        ).run();

        expect(fingerprints.asked, hasLength(cap));
        expect(fingerprints.writes, hasLength(cap));
        expect(summary.fingerprintsComputed, cap);
        expect(summary.fingerprintsRemaining, total - cap);
        expect(summary.hashRowsAdded, cap);
        expect(map.rows, hasLength(cap));
        expect(
          _summaryLines().single,
          contains('${total - cap} fingerprints left for the next pass'),
        );

        // The next pass starts from the persisted results: nothing it already
        // has is asked for again, and the rest gets its turn.
        final persisted = {for (final w in fingerprints.writes) w.romPath: w};
        final nextGames = [
          for (final g in games)
            persisted.containsKey(g.romPath)
                ? g.copyWith(romCrc32: persisted[g.romPath]!.crc32)
                : g,
        ];
        final next = _FakeFingerprints()..answers.addAll(fingerprints.answers);
        final second = await _linker(
          server,
          map,
          nextGames,
          fingerprints: next,
        ).run();

        expect(next.asked, hasLength(total - cap));
        expect(second.fingerprintsRemaining, 0);
        expect(map.rows, hasLength(total));
      },
    );

    // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Concurrency Safety"
    test('a stop between fingerprints ends the step after the current file, '
        'persists what was computed and reports stopped', () async {
      final server = serverWith([
        for (var i = 0; i < 4; i++)
          _rom(
            10 + i,
            platformId: 1,
            fsName: 'Game $i (USA).zip',
            crc: 'deadbee$i',
          ),
      ]);
      final map = _FakeMap();
      var stop = false;
      final fingerprints = _FakeFingerprints();
      final games = [for (var i = 0; i < 4; i++) _game('Game $i.zip', 'snes')];
      for (var i = 0; i < 4; i++) {
        fingerprints.answers[games[i].romPath] = (
          fingerprint: _fp('DEADBEE$i'),
          skipReason: null,
        );
      }
      // Disconnect while the second file is being read.
      fingerprints.onFingerprint = () {
        if (fingerprints.asked.length == 2) stop = true;
      };

      final summary = await _linker(
        server,
        map,
        games,
        fingerprints: fingerprints,
        shouldStop: () => stop,
      ).run();

      expect(fingerprints.asked, hasLength(2), reason: 'checked between files');
      expect(fingerprints.writes, hasLength(2), reason: 'both persisted');
      expect(summary.stoppedEarly, isTrue);
      expect(summary.fingerprintsComputed, 2);
      expect(summary.fingerprintsRemaining, 2);
      expect(_summaryLines().single, startsWith('i|RomM link pass stopped'));
    });

    test('without the fingerprint halves the pass matches on what the '
        'library holds', () async {
      final server = serverWith([
        _rom(10, platformId: 1, fsName: 'A (USA).zip', crc: 'deadbeef'),
        _rom(11, platformId: 1, fsName: 'B (USA).zip', crc: 'cafebabe'),
      ]);
      final map = _FakeMap();

      final summary = await _linker(server, map, [
        _game('A.zip', 'snes', crc32: 'deadbeef'),
        _game('B.zip', 'snes'),
      ]).run();

      expect(map.romIdFor('snes', 'A.zip'), 10);
      expect(map.romIdFor('snes', 'B.zip'), isNull);
      expect(summary.fingerprintsComputed, 0);
      expect(summary.fingerprintsRemaining, 0);
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Pass Summary And Observability"
  group('hash observability', () {
    test('the one summary line carries both stages\' counts', () async {
      final server = _FakeServer(
        platforms: [_platform(1, 'snes')],
        romsByPlatform: {
          1: [
            for (var i = 0; i < 3; i++)
              _rom(10 + i, platformId: 1, fsName: 'Name $i.zip'),
            for (var i = 0; i < 5; i++)
              _rom(
                20 + i,
                platformId: 1,
                fsName: 'Hash $i (USA).zip',
                crc: 'cafebab$i',
              ),
          ],
        },
        systemBySlug: {'snes': snes},
      );
      final map = _FakeMap();
      final fingerprints = _FakeFingerprints();
      final games = [
        for (var i = 0; i < 3; i++) _game('Name $i.zip', 'snes'),
        for (var i = 0; i < 5; i++) _game('Hash $i.zip', 'snes'),
        for (var i = 0; i < 7; i++) _game('Unknown $i.zip', 'snes'),
      ];
      for (var i = 0; i < 5; i++) {
        fingerprints.answers['/roms/snes/Hash $i.zip'] = (
          fingerprint: _fp('CAFEBAB$i'),
          skipReason: null,
        );
      }
      for (var i = 0; i < 7; i++) {
        fingerprints.answers['/roms/snes/Unknown $i.zip'] = (
          fingerprint: _fp('0000000$i'),
          skipReason: null,
        );
      }

      final summary = await _linker(
        server,
        map,
        games,
        fingerprints: fingerprints,
      ).run();

      expect(summary.rowsAdded, 3);
      expect(summary.hashRowsAdded, 5);
      expect(summary.fingerprintsComputed, 12);
      expect(summary.fingerprintsSkipped, 0);
      expect(summary.fingerprintsDeferred, 0);
      expect(summary.hashMismatches, 0);
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        allOf([
          contains('3 rows added'),
          contains('5 hash rows added'),
          contains('12 fingerprints computed'),
          contains('0 fingerprints skipped'),
          contains('0 fingerprints deferred'),
          contains('0 fingerprints left for the next pass'),
          contains('0 hash mismatches'),
        ]),
      );
      final info = LoggerService.instance
          .takeCapture()
          .where((l) => l.startsWith('i|'))
          .toList();
      expect(info, isEmpty, reason: 'the summary was the only info line');
    });
  });
}
