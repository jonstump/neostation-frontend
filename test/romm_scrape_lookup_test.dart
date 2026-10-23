import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/romm_scrape_step.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_metadata_fetch.dart';
import 'package:neostation/services/romm/romm_paging.dart';
import 'package:neostation/services/romm/romm_scrape_lookup.dart';
import 'package:neostation/services/romm/romm_server_guard.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/romm_scrape_matcher.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

import 'database_test_helper.dart';

/// Scraping a game from RomM when it has no link: the lookup
/// service on its own, then the provider's steps against a scripted RomM.

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes'],
);
const _gba = SystemModel(
  id: 'gba',
  folderName: 'gba',
  realName: 'Game Boy Advance',
  iconImage: '',
  color: '#000000',
  folders: ['gba'],
);

Map<String, dynamic> romJson(int id, String name, String fsName) {
  final dot = fsName.lastIndexOf('.');
  return {
    'id': id,
    'name': name,
    'fs_name': fsName,
    'fs_name_no_ext': dot > 0 ? fsName.substring(0, dot) : fsName,
    'fs_extension': dot > 0 ? fsName.substring(dot + 1) : '',
    'platform_id': 1,
    'platform_slug': 'snes',
    'summary': 'About $name.',
    'metadatum': const {
      'genres': ['RPG'],
    },
  };
}

RommRom rom(int id, String name, String fsName) =>
    RommRom.fromJson(romJson(id, name, fsName));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  // ── The lookup service on its own ────────────────────────────────────────

  group('rommErrorIsTransport', () {
    test('what says something about the server', () {
      expect(rommErrorIsTransport(TimeoutException('t')), isTrue);
      expect(rommErrorIsTransport(const SocketException('s')), isTrue);
      expect(rommErrorIsTransport(const HandshakeException('h')), isTrue);
      expect(rommErrorIsTransport(http.ClientException('c')), isTrue);
      expect(rommErrorIsTransport(RommException('no reply')), isTrue);
      expect(
        rommErrorIsTransport(RommException('boom', statusCode: 500)),
        isTrue,
      );
      expect(
        rommErrorIsTransport(RommException('bad', statusCode: 503)),
        isTrue,
      );
      expect(
        rommErrorIsTransport(RommException('slow down', statusCode: 429)),
        isTrue,
      );
    });

    test('what the server answered about the request', () {
      expect(
        rommErrorIsTransport(RommException('no', statusCode: 401)),
        isFalse,
      );
      expect(
        rommErrorIsTransport(RommException('no', statusCode: 403)),
        isFalse,
      );
      expect(
        rommErrorIsTransport(RommException('gone', statusCode: 404)),
        isFalse,
      );
      expect(rommErrorIsTransport(StateError('parse')), isFalse);
      expect(rommErrorIsTransport(const FormatException('json')), isFalse);
    });
  });

  group('RommScrapeLookup', () {
    late int loads;
    late int searches;
    late List<String> terms;

    RommScrapeLookup lookupWith({
      Future<List<RommRom>> Function(SystemModel)? catalog,
      Future<List<RommRom>> Function(SystemModel, String)? search,
    }) {
      loads = 0;
      searches = 0;
      terms = [];
      return RommScrapeLookup(
        loadCatalog: (system) {
          loads++;
          return (catalog ?? (s) async => [rom(1, 'ActRaiser', 'ar.sfc')])(
            system,
          );
        },
        search: (system, term) {
          searches++;
          terms.add(term);
          return (search ?? (s, t) async => [rom(1, 'ActRaiser', 'ar.sfc')])(
            system,
            term,
          );
        },
      );
    }

    test(
      'twelve workers asking about one system load its catalog once',
      () async {
        final gate = Completer<void>();
        final lookup = lookupWith(
          catalog: (s) async {
            await gate.future;
            return [rom(1, 'ActRaiser', 'ar.sfc')];
          },
        );

        final running = [
          for (var i = 0; i < 12; i++)
            lookup.findInCatalog(
              _snes,
              i == 0 ? 'ActRaiser (USA).sfc' : 'X$i.sfc',
            ),
        ];
        await pumpEventQueue();
        expect(loads, 1, reason: 'one load in flight, shared');
        gate.complete();
        final results = await Future.wait(running);

        expect(loads, 1);
        expect(lookup.catalogLoads, 1);
        expect(results.first.match!.romId, 1);
        expect(
          results.skip(1).map((r) => r.match!.kind),
          everyElement(RommScrapeMatchKind.none),
        );
      },
    );

    test('each system loads its own catalog', () async {
      final lookup = lookupWith();
      await lookup.findInCatalog(_snes, 'a.sfc');
      await lookup.findInCatalog(_gba, 'a.gba');
      await lookup.findInCatalog(_snes, 'b.sfc');
      expect(loads, 2);
    });

    test('a failed load is remembered, classified and not retried', () async {
      final lookup = lookupWith(
        catalog: (s) async => throw const SocketException('down'),
      );

      final first = await lookup.findInCatalog(_snes, 'a.sfc');
      final second = await lookup.findInCatalog(_snes, 'b.sfc');
      final third = await lookup.findInCatalog(_snes, 'c.sfc');

      expect(first.failed, isTrue);
      expect(first.transport, isTrue);
      expect(second.failed && third.failed, isTrue);
      expect(
        loads,
        1,
        reason: 'a dead server is asked once, not once per game',
      );
    });

    test('a failure that is not transport is not classified as one', () async {
      final lookup = lookupWith(
        catalog: (s) async => throw RommException('no', statusCode: 403),
      );
      final result = await lookup.findInCatalog(_snes, 'a.sfc');
      expect(result.failed, isTrue);
      expect(result.transport, isFalse);
    });

    test('a catalog with nothing in it is a miss, not a failure', () async {
      final lookup = lookupWith(catalog: (s) async => const []);
      final result = await lookup.findInCatalog(_snes, 'a.sfc');
      expect(result.failed, isFalse);
      expect(result.match!.kind, RommScrapeMatchKind.none);
    });

    test(
      'a search sends the title, not the file name, and matches in memory',
      () async {
        final lookup = lookupWith(
          search: (s, t) async => [
            rom(1, 'ActRaiser', 'ar.sfc'),
            rom(2, 'ActRaiser 2', 'ar2.sfc'),
          ],
        );
        final result = await lookup.findBySearch(
          _snes,
          'ActRaiser (USA) [!].sfc',
        );

        expect(terms, ['ActRaiser']);
        expect(result.match!.romId, 1);
        expect(loads, 0, reason: 'a single game never walks the catalog');
      },
    );

    test('a search that fails is classified', () async {
      final lookup = lookupWith(
        search: (s, t) async => throw TimeoutException('slow'),
      );
      final result = await lookup.findBySearch(_snes, 'ActRaiser.sfc');
      expect(result.failed, isTrue);
      expect(result.transport, isTrue);
    });

    test('a name with no title makes no request', () async {
      final lookup = lookupWith();
      final result = await lookup.findBySearch(_snes, '(USA).sfc');
      expect(searches, 0);
      expect(result.match!.kind, RommScrapeMatchKind.none);
    });
  });

  // ── The provider's steps against a scripted RomM ─────────────────────────

  group('provider steps look unlinked games up', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory root;
    late _Server server;
    late _Provider provider;
    late _Media media;

    setUp(() async {
      RommMetadataNetwork.resetForTesting();
      db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(
        "INSERT INTO app_systems (id, folder_name, real_name) "
        "VALUES ('snes', 'snes', 'Super Nintendo')",
      );
      root = await Directory.systemTemp.createTemp('romm_scrape_lookup_');
      media = _Media(root.path);
      server = _Server();
      provider = _Provider(server);
      LoggerService.instance.startCapture();
    });

    tearDown(() async {
      LoggerService.instance.takeCapture();
      await helper.tearDown();
      await root.delete(recursive: true);
    });

    RommScrapeTarget target(String filename, {bool overwrite = false}) =>
        RommScrapeTarget(
          appSystemId: 'snes',
          filename: filename,
          systemFolder: 'snes',
          forceOverwrite: overwrite,
        );

    Future<int> mappingRows() async =>
        (await db.rawQuery(
              'SELECT COUNT(*) AS n FROM app_romm_rom_map',
            )).first['n']
            as int;

    Future<Map<String, dynamic>?> row(String filename) =>
        ScraperRepository.getGameMetadata('snes', filename);

    test('an unlinked game with the same file name is scraped, with no link '
        'written', () async {
      server.catalog = [romJson(5, 'ActRaiser', 'ActRaiser (USA).sfc')];

      final result = await (await provider.bulkScrapeStep(media))!(
        target('ActRaiser (USA).sfc'),
      );

      expect(result.status, RommScrapeStepStatus.scraped);
      expect(server.detailRequests, [5]);
      expect(
        (await row('ActRaiser (USA).sfc'))!['description_en'],
        'About ActRaiser.',
      );
      expect(
        await mappingRows(),
        0,
        reason: 'a scrape is a lookup, not a link',
      );
    });

    test('an unlinked game with the same title is scraped', () async {
      server.catalog = [romJson(6, 'ActRaiser', 'actraiser.zip')];

      final result = await (await provider.bulkScrapeStep(media))!(
        target('ActRaiser (USA).sfc'),
      );

      expect(result.status, RommScrapeStepStatus.scraped);
      expect(server.detailRequests, [6]);
      expect(await mappingRows(), 0);
    });

    test(
      'an ambiguous title is not guessed: not found, nothing written',
      () async {
        server.catalog = [
          romJson(1, 'ActRaiser', 'ActRaiser (USA).sfc'),
          romJson(2, 'ActRaiser', 'ActRaiser (Europe).sfc'),
        ];

        final result = await (await provider.bulkScrapeStep(media))!(
          target('ActRaiser (Japan).sfc'),
        );

        expect(result.status, RommScrapeStepStatus.notFound);
        expect(server.detailRequests, isEmpty);
        expect(await row('ActRaiser (Japan).sfc'), isNull);
      },
    );

    test(
      'a game RomM does not have is not found with no detail request',
      () async {
        server.catalog = [romJson(1, 'Chrono Trigger', 'ct.sfc')];

        final result = await (await provider.bulkScrapeStep(media))!(
          target('Secret of Mana.sfc'),
        );

        expect(result.status, RommScrapeStepStatus.notFound);
        expect(server.detailRequests, isEmpty);
      },
    );

    test('a linked game never touches the catalog', () async {
      await RommSaveMapRepository.putMapping(
        romname: 'ct.sfc',
        systemFolder: 'snes',
        rommRomId: 42,
        source: RommLinkSource.download,
        fsName: 'ct.sfc',
      );
      server.catalog = [romJson(99, 'Chrono Trigger', 'ct.sfc')];

      final result = await (await provider.bulkScrapeStep(media))!(
        target('ct.sfc'),
      );

      expect(result.status, RommScrapeStepStatus.scraped);
      expect(server.detailRequests, [42], reason: 'the link wins');
      expect(server.pageRequests, isEmpty);
    });

    test('twelve unlinked games of one system walk the catalog once', () async {
      server.catalog = [
        for (var i = 0; i < 12; i++) romJson(100 + i, 'Game $i', 'g$i.sfc'),
      ];
      final step = (await provider.bulkScrapeStep(media))!;

      final results = await Future.wait([
        for (var i = 0; i < 12; i++) step(target('g$i.sfc')),
      ]);

      expect(
        results.map((r) => r.status),
        everyElement(RommScrapeStepStatus.scraped),
      );
      expect(server.pageRequests, hasLength(1));
      expect(server.platformListings, 1);
    });

    test('a catalog larger than a page is walked page by page', () async {
      server.catalog = [
        for (var i = 0; i < RommPaging.pageSize + 40; i++)
          romJson(1000 + i, 'Title $i', 'title$i.sfc'),
      ];
      final window = RommMetadataNetwork.instance.openWindow();

      final result = await (await provider.bulkScrapeStep(media))!(
        target('title${RommPaging.pageSize + 10}.sfc'),
      );

      expect(
        result.status,
        RommScrapeStepStatus.scraped,
        reason: 'on page two',
      );
      expect(server.pageRequests.map((r) => r.offset), [
        0,
        RommPaging.pageSize,
      ]);
      expect(RommMetadataNetwork.instance.closeWindow(window).catalog, 2);
    });

    test('every catalog page goes through the shared gate', () async {
      server.catalog = [
        for (var i = 0; i < 30; i++) romJson(200 + i, 'G$i', 'g$i.sfc'),
      ];
      server.pageGate = Completer<void>();
      final step = (await provider.bulkScrapeStep(media))!;

      final running = [for (var i = 0; i < 30; i++) step(target('g$i.sfc'))];
      await pumpEventQueue();
      expect(server.pagesInFlight, lessThanOrEqualTo(RommPaging.concurrency));

      server.pageGate!.complete();
      await Future.wait(running);
      expect(server.maxInFlight, lessThanOrEqualTo(RommPaging.concurrency));
    });

    test('a failed platform listing is a transport failure, not "RomM has '
        'nothing"', () async {
      server.platformsThrow = true;
      final step = (await provider.bulkScrapeStep(media))!;

      final results = [
        for (var i = 0; i < 3; i++) await step(target('g$i.sfc')),
      ];

      expect(
        results.map((r) => r.status),
        everyElement(RommScrapeStepStatus.failed),
      );
      expect(results.map((r) => r.serverUnavailable), everyElement(isTrue));
      expect(server.platformListings, 1, reason: 'asked once for the run');
      expect(server.detailRequests, isEmpty);
    });

    test('a failed catalog page is a transport failure, remembered for the '
        'run', () async {
      server.catalogThrows = true;
      final step = (await provider.bulkScrapeStep(media))!;

      final results = [
        for (var i = 0; i < 4; i++) await step(target('g$i.sfc')),
      ];

      expect(results.map((r) => r.serverUnavailable), everyElement(isTrue));
      expect(server.pageRequests, hasLength(1), reason: 'not retried per game');
    });

    test('a server with no platforms is a miss, not a failure', () async {
      server.platforms = const [];
      final result = await (await provider.bulkScrapeStep(media))!(
        target('g.sfc'),
      );
      expect(result.status, RommScrapeStepStatus.notFound);
      expect(result.serverUnavailable, isFalse);
    });

    test(
      'lookup failures reach the guard, and a dead catalog trips it',
      () async {
        server.catalogThrows = true;
        final guard = RommServerGuard();
        final step = (await provider.bulkScrapeStep(media, guard: guard))!;

        for (var i = 0; i < 8; i++) {
          await step(target('g$i.sfc'));
        }

        expect(guard.tripped, isTrue);
        expect(guard.skipped, 3, reason: 'five counted, then skipped');
        expect(server.pageRequests, hasLength(1));
      },
    );

    test('a lookup miss is neutral to the guard', () async {
      server.catalog = [romJson(1, 'Other', 'other.sfc')];
      final guard = RommServerGuard();
      final step = (await provider.bulkScrapeStep(media, guard: guard))!;

      for (var i = 0; i < 20; i++) {
        await step(target('g$i.sfc'));
      }

      expect(guard.tripped, isFalse);
      expect(guard.transportFailures, 0);
    });

    test(
      'a single game uses one search for its title, not the catalog',
      () async {
        server.catalog = [
          romJson(1, 'ActRaiser', 'ActRaiser (USA).sfc'),
          romJson(2, 'Chrono Trigger', 'ct.sfc'),
        ];

        final result = await provider.scrapeStep(media)!(
          target('ActRaiser (USA).sfc'),
        );

        expect(result.status, RommScrapeStepStatus.scraped);
        expect(server.pageRequests, hasLength(1));
        expect(server.pageRequests.single.search, 'ActRaiser');
        expect(await mappingRows(), 0);
      },
    );

    test('overwrite maps onto the mode for a looked-up game too', () async {
      server.catalog = [romJson(5, 'ActRaiser', 'ActRaiser (USA).sfc')];
      await ScraperRepository.saveGameMetadata(
        {
          'filename': 'ActRaiser (USA).sfc',
          'real_name': 'ActRaiser',
          'description_en': 'SS English',
        },
        'snes',
        source: MetadataSource.screenscraper,
        mode: MetadataWriteMode.replace,
      );
      final step = (await provider.bulkScrapeStep(media))!;

      await step(target('ActRaiser (USA).sfc'));
      expect(
        (await row('ActRaiser (USA).sfc'))!['description_en'],
        'SS English',
      );

      await step(target('ActRaiser (USA).sfc', overwrite: true));
      expect(
        (await row('ActRaiser (USA).sfc'))!['description_en'],
        'About ActRaiser.',
      );
    });
  });
}

// ── Test doubles ───────────────────────────────────────────────────────────

class _Server extends RommService {
  List<Map<String, dynamic>> catalog = const [];
  List<RommPlatform>? platforms = const [
    RommPlatform(id: 1, name: 'Super Nintendo', slug: 'snes'),
  ];
  bool platformsThrow = false;
  bool catalogThrows = false;
  Completer<void>? pageGate;
  int platformListings = 0;
  final List<({List<int> platforms, String? search, int offset})> pageRequests =
      [];
  final List<int> detailRequests = [];
  int pagesInFlight = 0;
  int _inFlight = 0;
  int maxInFlight = 0;

  void _enter() {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
  }

  @override
  Future<List<RommPlatform>> getPlatforms() async {
    platformListings++;
    if (platformsThrow) throw const SocketException('down');
    return platforms ?? const [];
  }

  @override
  Future<RommRomPage> getRomsPage({
    List<int> platformIds = const [],
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    List<String> genres = const [],
    List<String> companies = const [],
    int limit = 50,
    int offset = 0,
  }) async {
    pageRequests.add((platforms: platformIds, search: search, offset: offset));
    _enter();
    pagesInFlight++;
    try {
      await pageGate?.future;
      await Future<void>.delayed(Duration.zero);
      if (catalogThrows) throw const SocketException('down');
      final needle = search?.toLowerCase();
      final matching = [
        for (final r in catalog)
          if (needle == null ||
              (r['name'] as String).toLowerCase().contains(needle))
            r,
      ];
      return RommRomPage(
        items: matching.skip(offset).take(limit).map(RommRom.fromJson).toList(),
        total: matching.length,
      );
    } finally {
      pagesInFlight--;
      _inFlight--;
    }
  }

  @override
  Future<RommDetailFetch> fetchRomDetail(int id) async {
    detailRequests.add(id);
    _enter();
    try {
      await Future<void>.delayed(Duration.zero);
      final found = catalog.where((r) => r['id'] == id);
      final body = found.isEmpty
          ? romJson(id, 'Game $id', 'g$id.sfc')
          : found.first;
      return RommDetailFetch.found(body);
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<RommImageFetch> fetchImage(
    String pathOrUrl, {
    bool requireImage = true,
    bool quiet = false,
  }) async => const RommImageFetch.missing(RommImageMiss.absent);
}

class _Provider extends RommProvider {
  final RommService fake;
  _Provider(this.fake);

  @override
  RommService get service => fake;

  @override
  bool get isConnected => true;
}

class _Media extends FileProvider {
  final String root;
  _Media(this.root);

  @override
  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) => p.join(
    root,
    systemFolderName,
    imageType,
    '${p.basenameWithoutExtension(romName)}.$extension',
  );
}
