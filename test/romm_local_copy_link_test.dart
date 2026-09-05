import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// The link paths for ROMs that were already on disk before RomM was
/// connected (SPEC-0001 "Link on Already Downloaded"): finding the local copy
/// by the shared filename rule, writing its mapping row exactly once, and the
/// browser confirm's metadata fetch filling the gaps of whatever row the game
/// already has (SPEC-0005 "Fill Gaps On Link Confirm") instead of skipping it.
///
/// [RommProvider.resolveSystem] is the only server-facing step in the probe,
/// so a subclass pins it to a fixed system and the rest runs against a real
/// temp directory and an in-memory database — the same filesystem the
/// "downloaded" badge probes, which is what makes the two agree. The metadata
/// fetch substitutes the server the same way.

// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Link on Already Downloaded"
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Fill Gaps On Link Confirm"

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
  folders: ['snes', 'sfc'],
);

/// A server that answers one ROM detail and one cover, and counts.
class _FakeRommService extends RommService {
  Map<String, dynamic>? detail;
  int detailCalls = 0;
  final List<String> fetched = [];

  @override
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    detailCalls++;
    return detail;
  }

  @override
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
  }) async {
    fetched.add(pathOrUrl);
    return pathOrUrl.endsWith('cover.png')
        ? Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        : null;
  }
}

class _PinnedSystem extends RommProvider {
  final SystemModel? system;
  final _FakeRommService fake = _FakeRommService();
  _PinnedSystem(this.system);

  @override
  Future<SystemModel?> resolveSystem(RommRom rom) async => system;

  @override
  RommService get service => fake;
}

/// Media paths rooted in the test's temp directory.
class _TempMedia extends FileProvider {
  final String root;
  _TempMedia(this.root);

  @override
  String getMediaPath(
    String systemFolderName,
    String imageType,
    String romName,
    String extension,
  ) => p.join(
    root,
    'media',
    systemFolderName,
    imageType,
    '${p.basenameWithoutExtension(romName)}.$extension',
  );
}

RommRom _rom(int id, String fsName, {bool multiFile = false}) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: fsName,
  fsNameNoExt: p.basenameWithoutExtension(fsName),
  fsExtension: p.extension(fsName).replaceFirst('.', ''),
  fsSizeBytes: 0,
  hasMultipleFiles: multiFile,
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory root;
  late List<String> romFolders;

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    root = await Directory.systemTemp.createTemp('romm_link_');
    romFolders = [root.path];
  });

  tearDown(() async {
    await helper.tearDown();
    await root.delete(recursive: true);
  });

  Future<File> put(String folder, String name) async {
    final f = File(p.join(root.path, folder, name));
    await f.create(recursive: true);
    return f;
  }

  group('findLocalCopy', () {
    test('returns the directory and on-disk name of a matching file', () async {
      await put('snes', 'Chrono Trigger (USA).sfc');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(
        _rom(7, 'Chrono Trigger (USA).sfc'),
        romFolders,
      );

      expect(copy, isNotNull);
      expect(copy!.system.folderName, 'snes');
      expect(copy.directory, p.join(root.path, 'snes'));
      expect(copy.filename, 'Chrono Trigger (USA).sfc');
      expect(copy.romname, 'Chrono Trigger (USA)');
    });

    test('agrees with isDownloaded', () async {
      await put('snes', 'a.sfc');
      final provider = _PinnedSystem(_snes);
      final present = _rom(1, 'a.sfc');
      final absent = _rom(2, 'b.sfc');

      expect(await provider.isDownloaded(present, romFolders), isTrue);
      expect(await provider.findLocalCopy(present, romFolders), isNotNull);
      expect(await provider.isDownloaded(absent, romFolders), isFalse);
      expect(await provider.findLocalCopy(absent, romFolders), isNull);
    });

    test('finds a copy under a folder alias', () async {
      await put('sfc', 'a.sfc');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(_rom(1, 'a.sfc'), romFolders);

      expect(copy?.directory, p.join(root.path, 'sfc'));
      expect(
        copy?.system.folderName,
        'snes',
        reason: 'the mapping is keyed by the canonical folder, not the alias',
      );
    });

    test('finds a multi-disc game by its playlist', () async {
      await put('snes', 'Game (USA).m3u');
      final provider = _PinnedSystem(_snes);

      final copy = await provider.findLocalCopy(
        _rom(1, 'Game (USA)', multiFile: true),
        romFolders,
      );

      expect(copy?.filename, 'Game (USA).m3u');
    });

    test('a copy the badge probe found is not probed for again', () async {
      // The disk is the witness: once isDownloadedCached has looked, deleting
      // the file must not change what findLocalCopy hands the link path —
      // a second probe would notice, a memoised copy does not.
      final file = await put('snes', 'a.sfc');
      final provider = _PinnedSystem(_snes);
      final rom = _rom(1, 'a.sfc');

      expect(await provider.isDownloadedCached(rom, romFolders), isTrue);
      await file.delete();

      final copy = await provider.findLocalCopy(rom, romFolders);
      expect(copy, isNotNull, reason: 'served from the memo, not the disk');
      expect(copy!.filename, 'a.sfc');
      expect(await provider.isDownloadedCached(rom, romFolders), isTrue);

      provider.invalidateDownloadedCache();
      expect(
        await provider.findLocalCopy(rom, romFolders),
        isNull,
        reason: 'invalidation drops the copy along with the flag',
      );
      expect(await provider.isDownloadedCached(rom, romFolders), isFalse);
    });

    test('a miss is not memoised as a copy', () async {
      final provider = _PinnedSystem(_snes);
      final rom = _rom(1, 'a.sfc');

      expect(await provider.isDownloadedCached(rom, romFolders), isFalse);
      await put('snes', 'a.sfc');

      expect(
        await provider.findLocalCopy(rom, romFolders),
        isNotNull,
        reason: 'only hits are memoised; a miss probes again',
      );
    });

    test('is null when the platform resolves to no local system', () async {
      await put('snes', 'a.sfc');
      final provider = _PinnedSystem(null);

      expect(
        await provider.findLocalCopy(_rom(1, 'a.sfc'), romFolders),
        isNull,
      );
    });
  });

  group('linkLocalCopy', () {
    test(
      'writes one row keyed by the on-disk name, then never again',
      () async {
        await put('snes', 'a.sfc');
        final provider = _PinnedSystem(_snes);
        final rom = _rom(42, 'a.sfc');
        final copy = (await provider.findLocalCopy(rom, romFolders))!;

        expect(await provider.linkLocalCopy(rom, copy), isTrue);
        expect(await RommSaveMapRepository.getRommRomId('a.sfc', 'snes'), 42);
        expect(
          await RommSaveMapRepository.getRommRomId('a', 'snes'),
          42,
          reason:
              'resolvable from the extension-stripped GameModel.romname too',
        );

        expect(
          await provider.linkLocalCopy(rom, copy),
          isFalse,
          reason: 'a second confirm is "already downloaded", not a rewrite',
        );
      },
    );

    test('never overwrites a row that points elsewhere', () async {
      await put('snes', 'a.sfc');
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'a.sfc',
        systemFolder: 'snes',
        rommRomId: 1,
      );
      final provider = _PinnedSystem(_snes);
      final rom = _rom(2, 'a.sfc');
      final copy = (await provider.findLocalCopy(rom, romFolders))!;

      expect(await provider.linkLocalCopy(rom, copy), isFalse);
      expect(await RommSaveMapRepository.getRommRomId('a.sfc', 'snes'), 1);
    });
  });

  group('fillMetadataGaps', () {
    Map<String, dynamic> detail() => {
      'id': 1,
      'name': 'Game 1',
      'fs_name': 'a.sfc',
      'fs_name_no_ext': 'a',
      'fs_extension': 'sfc',
      'platform_id': 1,
      'platform_slug': 'snes',
      'summary': 'RomM says',
      'metadatum': {
        'genres': ['Platformer'],
      },
      'path_cover_large': '/assets/romm/resources/roms/1/1/cover.png',
    };

    test('fills an ES-DE row\'s gaps instead of skipping it', () async {
      await put('snes', 'a.sfc');
      await ScraperRepository.mergeFillGapsMetadata('snes', 'a.sfc', {
        'real_name': 'Curated by hand',
        'description_en': 'ES-DE says',
      }, source: MetadataSource.esde);
      final provider = _PinnedSystem(_snes)..fake.detail = detail();
      final rom = _rom(1, 'a.sfc');
      final copy = (await provider.findLocalCopy(rom, romFolders))!;
      final media = _TempMedia(root.path);

      final outcome = await provider.fillMetadataGaps(rom, copy, media);

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      expect(provider.fake.detailCalls, 1, reason: 'exactly one fetch');
      final row = (await ScraperRepository.getGameMetadata('snes', 'a.sfc'))!;
      expect(row['real_name'], 'Curated by hand');
      expect(row['description_en'], 'ES-DE says', reason: 'never replaced');
      expect(row['genre'], 'Platformer', reason: 'the gap is filled');
      expect(row['metadata_source'], 'esde');
      expect(row['is_fully_scraped'], 0);
      expect(
        await File(
          media.getMediaPath('snes', 'box2d', 'a.sfc', 'png'),
        ).exists(),
        isTrue,
        reason: 'missing art is written under the on-disk key',
      );
    });

    test('a row with nothing missing is left alone, art still fills', () async {
      await put('snes', 'a.sfc');
      await ScraperRepository.saveGameMetadata(
        {
          'filename': 'a.sfc',
          'real_name': 'Mine',
          'description_en': 'Mine',
          'genre': 'Mine',
        },
        'snes',
        source: MetadataSource.manual,
        isFullyScraped: true,
      );
      final provider = _PinnedSystem(_snes)..fake.detail = detail();
      final rom = _rom(1, 'a.sfc');
      final copy = (await provider.findLocalCopy(rom, romFolders))!;

      final outcome = await provider.fillMetadataGaps(
        rom,
        copy,
        _TempMedia(root.path),
      );

      expect(outcome.kind, RommMetadataOutcomeKind.filled);
      expect(outcome.columnsWritten, 0);
      final row = (await ScraperRepository.getGameMetadata('snes', 'a.sfc'))!;
      expect(row['real_name'], 'Mine');
      expect(row['description_en'], 'Mine');
      expect(row['genre'], 'Mine');
      expect(row['metadata_source'], 'manual');
      expect(row['is_fully_scraped'], 1);
      expect(outcome.mediaWritten, greaterThan(0));
    });
  });
}
