import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/models/romm_collection.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_bulk_sync.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/collection_repository.dart';
import 'package:neostation/services/romm/romm_collection_mirror.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// [RommProvider.syncSource] mirroring a synced RomM collection into a local
/// collection, end to end against an in-memory database, a temp ROM folder
/// and a scripted RomM: the mirror runs after a completed sync with the
/// ROMs already local, not after a declined plan, not for a platform sync,
/// and again after the settle so a downloaded ROM joins once indexed.
///
/// [RommProvider.resolveSystem] is the only server-facing step in the local
/// probe, so the subclass pins it; the ROM list comes from the fake service.
///
/// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ
/// "Triggered By The Collection Sync"

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes', 'sfc'],
);

const _bestOfSnes = RommCollection(id: '12', name: 'Best of SNES');

RommRom _rom(int id, String fsName) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: fsName,
  fsNameNoExt: p.basenameWithoutExtension(fsName),
  fsExtension: p.extension(fsName).replaceFirst('.', ''),
  fsSizeBytes: 1024,
);

/// A server whose `/api/roms` answers from [roms], recording each query.
class _FakeRommService extends RommService {
  List<RommRom> roms = const [];
  final List<Map<String, Object?>> queries = [];

  _FakeRommService() {
    configure(serverUrl: 'https://romm.local/', apiKey: 'k');
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
    queries.add({
      'platformIds': platformIds,
      'collectionId': collectionId,
      'virtualCollectionId': virtualCollectionId,
      'search': search,
      'limit': limit,
      'offset': offset,
    });
    final end = (offset + limit).clamp(0, roms.length);
    return RommRomPage(
      items: roms.sublist(offset.clamp(0, roms.length), end),
      total: roms.length,
    );
  }
}

class _PinnedProvider extends RommProvider {
  final _FakeRommService fake = _FakeRommService();
  bool connected = true;

  /// ROMs the sync asked to download, in order.
  final List<int> downloaded = [];

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => _snes;

  @override
  RommService get service => fake;

  @override
  bool get isConnected => connected;

  /// No transfer: records the completion exactly as a finished download
  /// would, under the ROM's own filename, and leaves the settle to the test.
  /// When set, every "download" waits on it, so a test can look at the
  /// state the sync leaves while transfers are still in flight.
  Completer<void>? downloadGate;

  @override
  Future<RommDownload> downloadRom(
    RommRom rom, {
    required List<String> romFolders,
    FileProvider? fileProvider,
  }) async {
    downloaded.add(rom.id);
    final gate = downloadGate;
    if (gate != null) await gate.future;
    debugRegisterCompletedDownload(rom, _snes, rom.fsName);
    return RommDownload(romId: rom.id, status: RommDownloadStatus.completed);
  }
}

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late List<String> romFolders;
  late _PinnedProvider provider;
  int mirrored = 0;

  setUp(() async {
    RommCollectionMirror.resetForTesting();
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createUserCollectionsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsTableSql);
    await db.execute(SqliteMigrations.createUserCollectionItemsIndexSql);
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    root = await Directory.systemTemp.createTemp('romm_mirror_');
    romFolders = [root.path];
    mirrored = 0;
    provider = _PinnedProvider()..onCollectionsMirrored = () => mirrored++;
  });

  tearDown(() async {
    provider.dispose();
    RommCollectionMirror.resetForTesting();
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  /// Puts a ROM file on disk and, unless [indexed] is false, its library row
  /// — what the scan would have produced for it.
  Future<String> local(String name, {bool indexed = true}) async {
    final file = File(p.join(root.path, 'snes', name));
    await file.create(recursive: true);
    if (indexed) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id) '
        'VALUES (?, ?, ?)',
        [name, file.path, 'snes'],
      );
    }
    return file.path;
  }

  Future<List<CollectionModel>> collections() async =>
      (await CollectionRepository.getCollections())
          .map(CollectionModel.fromJson)
          .toList();

  group('collection sync', () {
    test('mirrors the collection with its local ROMs', () async {
      final a = await local('Game A.sfc');
      final b = await local('Game B.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc'), _rom(2, 'Game B.sfc')];

      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
      );

      final all = await collections();
      expect(all, hasLength(1));
      final c = all.single;
      expect(c.name, 'Best of SNES');
      expect(c.isRommMirror, isTrue);
      expect(c.rommServerUrl, provider.fake.baseUrl);
      expect(c.rommCollectionId, '12');
      expect(c.rommCollectionVirtual, isFalse);
      expect(c.rommSyncedAt, isNotNull);
      expect(c.gameCount, 2);
      expect(await CollectionRepository.getMemberRomPaths(c.id), {a, b});

      final s = provider.lastCollectionMirror!;
      expect(s.created, isTrue);
      expect(s.collectionId, c.id);
      expect(s.members, 2);
      expect(s.unresolved, 0);
      expect(mirrored, 1);

      // The mirror paged the collection itself, without a search term.
      final mirrorQuery = provider.fake.queries.last;
      expect(mirrorQuery['collectionId'], 12);
      expect(mirrorQuery['virtualCollectionId'], isNull);
      expect(mirrorQuery['search'], isNull);
      expect(mirrorQuery['limit'], RommCollectionMirror.pageSize);
    });

    test('a second sync updates the same collection', () async {
      final a = await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc'), _rom(2, 'Game B.sfc')];
      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
      );
      final first = (await collections()).single;
      await CollectionRepository.updateCollection(first.id, name: 'Mine');

      final b = await local('Game B.sfc');
      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
      );

      final all = await collections();
      expect(all, hasLength(1));
      expect(all.single.id, first.id);
      expect(all.single.name, 'Mine', reason: 'the rename sticks');
      expect(await CollectionRepository.getMemberRomPaths(first.id), {a, b});
      expect(provider.lastCollectionMirror!.created, isFalse);
      expect(provider.lastCollectionMirror!.added, 1);
      expect(mirrored, 2);
    });

    test('a virtual collection pages by its virtual id', () async {
      await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc')];
      await provider.syncSource(
        collection: const RommCollection(
          id: 'genre:rpg',
          name: 'RPG',
          isVirtual: true,
        ),
        romFolders: romFolders,
      );
      final c = (await collections()).single;
      expect(c.rommCollectionId, 'genre:rpg');
      expect(c.rommCollectionVirtual, isTrue);
      expect(provider.fake.queries.last['virtualCollectionId'], 'genre:rpg');
      expect(provider.fake.queries.last['collectionId'], isNull);
    });
  });

  group('no mirror', () {
    test('when the user declines the plan', () async {
      await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc'), _rom(2, 'Game B.sfc')];
      RommBulkSyncPlan? plan;

      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
        confirm: (p) async {
          plan = p;
          return false;
        },
      );

      expect(plan, isNotNull, reason: 'ROM 2 was queued, so the plan showed');
      expect(provider.bulkSync.declined, isTrue);
      expect(await collections(), isEmpty);
      expect(provider.lastCollectionMirror, isNull);
      expect(mirrored, 0);
    });

    test('for a platform sync', () async {
      await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc')];

      await provider.syncSource(
        platform: const RommPlatform(id: 1, name: 'SNES', slug: 'snes'),
        romFolders: romFolders,
      );

      expect(await collections(), isEmpty);
      expect(provider.lastCollectionMirror, isNull);
      expect(mirrored, 0);
    });
  });

  group('while downloading', () {
    test('the collection exists as soon as the plan is approved', () async {
      final a = await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc'), _rom(2, 'Game B.sfc')];
      provider.downloadGate = Completer<void>();

      // Not awaited: the sync is parked inside the gated download.
      final sync = provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
        confirm: (_) async => true,
      );
      // Let the enumeration, the approval and the early mirror run.
      for (var i = 0; i < 50 && (await collections()).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.downloaded, [2], reason: 'the transfer has started');
      final c = (await collections()).single;
      expect(await CollectionRepository.getMemberRomPaths(c.id), {
        a,
      }, reason: 'created on approval with the local ROM, before the download');

      provider.downloadGate!.complete();
      await sync;
      expect((await collections()).single.id, c.id);
      expect(mirrored, 1, reason: 'the approval-time run is the only one');
    });
  });

  group('after the settle', () {
    test('a downloaded ROM joins once indexed', () async {
      final a = await local('Game A.sfc');
      provider.fake.roms = [_rom(1, 'Game A.sfc'), _rom(2, 'Game B.sfc')];
      final settled = <List<SystemModel>>[];
      // The settle handler stands in for the rescan: it indexes the file the
      // "download" put on disk.
      String? b;
      provider.onDownloadsSettled = (systems) async {
        settled.add(systems);
        b ??= await local('Game B.sfc');
      };

      // The sync itself: ROM 1 is local, ROM 2 is "downloaded" — no
      // transfer, just the completion the download path records.
      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
        confirm: (_) async => true,
      );
      final c = (await collections()).single;
      expect(await CollectionRepository.getMemberRomPaths(c.id), {
        a,
      }, reason: 'right after the sync only the local ROM is a member');
      expect(provider.lastCollectionMirror!.unresolved, 1);
      expect(provider.downloaded, [2]);
      expect(mirrored, 1);

      await provider.settleNowForTesting();

      expect(settled, hasLength(1));
      expect(await CollectionRepository.getMemberRomPaths(c.id), {
        a,
        b,
      }, reason: 'the indexed download joined the same collection');
      expect((await collections()).single.id, c.id);
      expect(provider.lastCollectionMirror!.added, 1);
      expect(provider.lastCollectionMirror!.unresolved, 0);
      expect(mirrored, 2);

      // The index has caught up, so the collection is no longer pending:
      // another settle for unrelated downloads does not run it again.
      provider.debugRegisterCompletedDownload(
        _rom(3, 'Other.sfc'),
        _snes,
        'Other.sfc',
      );
      await provider.settleNowForTesting();
      expect(settled, hasLength(2));
      expect(mirrored, 2);
    });

    test('resolves the download by its indexed name', () async {
      // A multi-disc download is indexed under its .m3u, which the name
      // heuristics cannot reconstruct from the RomM ROM: the recorded
      // indexed name is what finds the row.
      provider.fake.roms = [_rom(2, 'Game B.zip')];
      provider.onDownloadsSettled = (_) async {};
      await provider.syncSource(
        collection: _bestOfSnes,
        romFolders: romFolders,
        confirm: (_) async => true,
      );
      final c = (await collections()).single;
      expect(await CollectionRepository.getMemberRomPaths(c.id), isEmpty);

      // The download path unpacked the zip and indexed the playlist.
      final playlist = await local('Game B.m3u');
      provider.debugRegisterCompletedDownload(
        _rom(2, 'Game B.zip'),
        _snes,
        'Game B.m3u',
      );
      await provider.settleNowForTesting();

      expect(await CollectionRepository.getMemberRomPaths(c.id), {playlist});
    });

    test('a settle with nothing pending mirrors nothing', () async {
      provider.onDownloadsSettled = (_) async {};
      provider.debugRegisterCompletedDownload(
        _rom(3, 'Other.sfc'),
        _snes,
        'Other.sfc',
      );
      await provider.settleNowForTesting();
      expect(await collections(), isEmpty);
      expect(mirrored, 0);
    });
  });
}
