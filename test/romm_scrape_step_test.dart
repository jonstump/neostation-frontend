import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_scrape_step.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:path/path.dart' as p;

import 'database_test_helper.dart';

/// The RomM scrape step (SPEC-0006 "RomM Scrape Step", "Scrape Success
/// Rule", "Overwrite Mode Mapping"): the pure success rule over every
/// outcome shape, the overwrite-to-mode mapping, and the provider's two step
/// builders against the in-memory database, a scripted server, and a temp
/// media directory.
///
/// What is pinned: a disconnected provider has no step; an unlinked game is
/// "not linked" and costs no request; a linked game runs the writer keyed by
/// the row's stored filename, in replace mode when overwriting and fill-gaps
/// otherwise; a linked game RomM has nothing for is "empty"; a row that
/// already holds everything is "scraped"; the bulk step reads the link map
/// once and never queries per game.

// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "RomM Scrape Step"

const _coverUrl = '/assets/romm/resources/roms/1/42/cover/big.png';

/// A minimal PNG header, enough for the extension sniff to say `png`.
final Uint8List _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
]);

/// A populated entry with no media, so a fetch writes columns only.
Map<String, dynamic> _detail({int id = 42, String? cover}) => {
  'id': id,
  'name': 'Chrono Trigger',
  'fs_name': 'ct.sfc',
  'fs_name_no_ext': 'ct',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
  'summary': 'A time-travel RPG.',
  'metadatum': {
    'genres': ['RPG'],
  },
  'path_cover_large': ?cover,
};

/// An entry with a name and nothing else: RomM has nothing for this game.
Map<String, dynamic> _bareDetail() => {
  'id': 42,
  'name': 'Chrono Trigger',
  'fs_name': 'ct.sfc',
  'fs_name_no_ext': 'ct',
  'fs_extension': 'sfc',
  'platform_id': 1,
  'platform_slug': 'snes',
};

class _FakeRommService extends RommService {
  Map<String, dynamic>? detail;
  bool detailThrows = false;
  final List<int> detailRequests = [];

  @override
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    detailRequests.add(id);
    if (detailThrows) throw const SocketException('timeout');
    return detail;
  }

  @override
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
  }) async => pathOrUrl == _coverUrl ? _png : null;
}

class _TestProvider extends RommProvider {
  final RommService fake;
  bool connected = true;
  _TestProvider(this.fake);

  @override
  RommService get service => fake;

  @override
  bool get isConnected => connected;
}

/// Media paths rooted in a temp directory, the same shape the app writes.
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
    systemFolderName,
    imageType,
    '${p.basenameWithoutExtension(romName)}.$extension',
  );
}

RommMetadataOutcome _outcome(
  RommMetadataOutcomeKind kind, {
  int columns = 0,
  int written = 0,
  int skipped = 0,
  int failed = 0,
}) => RommMetadataOutcome(
  kind: kind,
  columnsWritten: columns,
  mediaWritten: written,
  mediaSkipped: skipped,
  mediaFailed: failed,
);

void main() {
  group('classifyOutcome', () {
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Scrape Success Rule"
    const classify = RommScrapeStepResult.classifyOutcome;

    test('a column written is scraped, in every completed kind', () {
      for (final kind in [
        RommMetadataOutcomeKind.filled,
        RommMetadataOutcomeKind.replaced,
        RommMetadataOutcomeKind.partial,
      ]) {
        expect(
          classify(_outcome(kind, columns: 1)),
          RommScrapeStepStatus.scraped,
          reason: kind.name,
        );
      }
    });

    test('a media file written is scraped even with nothing skipped', () {
      expect(
        classify(_outcome(RommMetadataOutcomeKind.filled, written: 1)),
        RommScrapeStepStatus.scraped,
      );
    });

    test('a partial that wrote columns is scraped despite the failure', () {
      expect(
        classify(
          _outcome(RommMetadataOutcomeKind.partial, columns: 3, failed: 1),
        ),
        RommScrapeStepStatus.scraped,
      );
    });

    test('nothing written, only skips, nothing failed: already complete', () {
      expect(
        classify(_outcome(RommMetadataOutcomeKind.filled, skipped: 2)),
        RommScrapeStepStatus.scraped,
      );
    });

    test('nothing written, a skip and a failure: empty', () {
      expect(
        classify(
          _outcome(RommMetadataOutcomeKind.partial, skipped: 1, failed: 1),
        ),
        RommScrapeStepStatus.empty,
      );
    });

    test('nothing written, nothing skipped: empty', () {
      expect(
        classify(_outcome(RommMetadataOutcomeKind.filled)),
        RommScrapeStepStatus.empty,
      );
      expect(
        classify(_outcome(RommMetadataOutcomeKind.replaced)),
        RommScrapeStepStatus.empty,
      );
    });

    test('not found and failed keep their own status', () {
      expect(
        classify(const RommMetadataOutcome.notFound()),
        RommScrapeStepStatus.notFound,
      );
      expect(
        classify(RommMetadataOutcome.failed(StateError('x'))),
        RommScrapeStepStatus.failed,
      );
    });

    test('fromOutcome carries the outcome and its error', () {
      final error = StateError('boom');
      final result = RommScrapeStepResult.fromOutcome(
        RommMetadataOutcome.failed(error),
      );
      expect(result.status, RommScrapeStepStatus.failed);
      expect(result.scraped, isFalse);
      expect(result.error, same(error));
      expect(result.outcome?.kind, RommMetadataOutcomeKind.failed);

      final ok = RommScrapeStepResult.fromOutcome(
        _outcome(RommMetadataOutcomeKind.filled, columns: 1),
      );
      expect(ok.scraped, isTrue);
      expect(ok.error, isNull);
    });
  });

  group('modeFor', () {
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Overwrite Mode Mapping"
    test('overwrite replaces, otherwise fills gaps', () {
      expect(RommScrapeStepResult.modeFor(true), RommMetadataMode.replace);
      expect(RommScrapeStepResult.modeFor(false), RommMetadataMode.fillGaps);
    });
  });

  group('RommScrapeTarget', () {
    test('value equality', () {
      const a = RommScrapeTarget(
        appSystemId: 'snes',
        filename: 'ct.sfc',
        systemFolder: 'snes',
      );
      const b = RommScrapeTarget(
        appSystemId: 'snes',
        filename: 'ct.sfc',
        systemFolder: 'snes',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.forceOverwrite, isFalse);
      expect(
        a,
        isNot(
          const RommScrapeTarget(
            appSystemId: 'snes',
            filename: 'ct.sfc',
            systemFolder: 'snes',
            forceOverwrite: true,
          ),
        ),
      );
      expect(a.toString(), contains('snes/ct.sfc'));
    });
  });

  group('provider steps', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory root;
    late _FakeRommService svc;
    late _TestProvider provider;
    late _TempMedia media;

    const target = RommScrapeTarget(
      appSystemId: 'snes',
      filename: 'ct.sfc',
      systemFolder: 'snes',
    );
    const overwrite = RommScrapeTarget(
      appSystemId: 'snes',
      filename: 'ct.sfc',
      systemFolder: 'snes',
      forceOverwrite: true,
    );

    Future<Map<String, dynamic>?> row([String filename = 'ct.sfc']) =>
        ScraperRepository.getGameMetadata('snes', filename);

    Future<void> link({
      int romId = 42,
      String romname = 'ct.sfc',
      String folder = 'snes',
    }) async {
      await RommSaveMapRepository.putMapping(
        romname: romname,
        systemFolder: folder,
        rommRomId: romId,
        source: RommLinkSource.download,
        fsName: romname,
      );
    }

    /// A ScreenScraper row with a description already in it.
    Future<void> scrapedRow() => ScraperRepository.saveGameMetadata(
      {
        'filename': 'ct.sfc',
        'real_name': 'Chrono Trigger (SS)',
        'description_en': 'SS English',
      },
      'snes',
      source: MetadataSource.screenscraper,
    );

    setUp(() async {
      db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(
        "INSERT INTO app_systems (id, folder_name, real_name) "
        "VALUES ('snes', 'snes', 'Super Nintendo')",
      );
      root = await Directory.systemTemp.createTemp('romm_scrape_step_');
      media = _TempMedia(root.path);
      svc = _FakeRommService()..detail = _detail();
      provider = _TestProvider(svc);
      LoggerService.instance.startCapture();
    });

    tearDown(() async {
      LoggerService.instance.takeCapture();
      await helper.tearDown();
      await root.delete(recursive: true);
    });

    group('scrapeStep', () {
      test('absent when not connected', () async {
        provider.connected = false;
        expect(provider.scrapeStep(media), isNull);
        expect(await provider.bulkScrapeStep(media), isNull);
      });

      test('not linked: no request, nothing written', () async {
        final step = provider.scrapeStep(media)!;

        final result = await step(target);

        expect(result.status, RommScrapeStepStatus.notLinked);
        expect(result.scraped, isFalse);
        expect(result.outcome, isNull);
        expect(svc.detailRequests, isEmpty);
        expect(await row(), isNull);
      });

      test('linked, not overwriting: fills gaps, keyed by the row', () async {
        await link();
        await scrapedRow();
        final step = provider.scrapeStep(media)!;

        final result = await step(target);

        expect(result.status, RommScrapeStepStatus.scraped);
        expect(result.scraped, isTrue);
        expect(result.outcome?.kind, RommMetadataOutcomeKind.filled);
        expect(svc.detailRequests, [42]);
        final r = (await row())!;
        // Fill-gaps: the existing description is kept, the genre is filled.
        expect(r['description_en'], 'SS English');
        expect(r['genre'], 'RPG');
      });

      test('linked, overwriting: replaces', () async {
        await link();
        await scrapedRow();
        final step = provider.scrapeStep(media)!;

        final result = await step(overwrite);

        expect(result.status, RommScrapeStepStatus.scraped);
        expect(result.outcome?.kind, RommMetadataOutcomeKind.replaced);
        final r = (await row())!;
        expect(r['description_en'], 'A time-travel RPG.');
        expect(r['real_name'], 'Chrono Trigger');
        expect(r['metadata_source'], 'romm');
      });

      test('resolves a row stored without the extension', () async {
        // A legacy row keyed by the stem: the target names the file on disk.
        await link(romname: 'ct');
        final step = provider.scrapeStep(media)!;

        final result = await step(
          const RommScrapeTarget(
            appSystemId: 'snes',
            filename: 'ct',
            systemFolder: 'snes',
          ),
        );

        expect(result.status, RommScrapeStepStatus.scraped);
        expect(svc.detailRequests, [42]);
        // Keyed by the row's stored name, not re-derived.
        expect(await row('ct'), isNotNull);
      });

      test('linked but RomM has nothing: empty, falls through', () async {
        await link();
        await scrapedRow();
        svc.detail = _bareDetail();
        final step = provider.scrapeStep(media)!;

        final result = await step(target);

        expect(result.status, RommScrapeStepStatus.empty);
        expect(result.scraped, isFalse);
        expect(result.outcome?.columnsWritten, 0);
        expect(result.outcome?.mediaWritten, 0);
        expect(svc.detailRequests, [42]);
      });

      test('a row that already holds everything counts as scraped', () async {
        await link();
        svc.detail = _detail(cover: _coverUrl);
        final cover = File(
          media.getMediaPath('snes', 'box2d', 'ct.sfc', 'png'),
        );
        await cover.create(recursive: true);
        await cover.writeAsString('OLD');
        // Populate the row fully once (replace), then fill gaps again.
        final step = provider.scrapeStep(media)!;
        expect((await step(overwrite)).scraped, isTrue);

        final result = await step(target);

        expect(result.outcome?.kind, RommMetadataOutcomeKind.filled);
        expect(result.outcome?.columnsWritten, 0);
        expect(result.outcome?.mediaWritten, 0);
        expect(result.outcome?.mediaSkipped, greaterThan(0));
        expect(result.outcome?.mediaFailed, 0);
        expect(result.status, RommScrapeStepStatus.scraped);
      });

      test('no detail on the server: not found', () async {
        await link();
        svc.detail = null;
        final step = provider.scrapeStep(media)!;

        final result = await step(target);

        expect(result.status, RommScrapeStepStatus.notFound);
        expect(result.scraped, isFalse);
        expect(await row(), isNull);
      });

      test('a failing request is failed, never thrown, and logged', () async {
        await link();
        svc.detailThrows = true;
        final step = provider.scrapeStep(media)!;

        final result = await step(target);

        expect(result.status, RommScrapeStepStatus.failed);
        expect(result.error, isA<RommMetadataFetchException>());
        expect(await row(), isNull);
      });

      test('an unresolvable system is failed with the rom id logged', () async {
        await link(folder: 'nope');
        final step = provider.scrapeStep(media)!;

        final result = await step(
          const RommScrapeTarget(
            appSystemId: 'nope',
            filename: 'ct.sfc',
            systemFolder: 'nope',
          ),
        );

        expect(result.status, RommScrapeStepStatus.failed);
        final error = result.error as RommMetadataFetchException;
        expect(error.stage, 'system');
        expect(error.romId, 42);
        expect(
          svc.detailRequests,
          isEmpty,
          reason: 'no request without a system',
        );
        final logged = LoggerService.instance
            .takeCapture()
            .where((l) => l.contains('RomM scrape step failed'))
            .toList();
        expect(logged, hasLength(1));
        expect(logged.single, contains('rom=42'));
        expect(logged.single, contains('filename=ct.sfc'));
        expect(logged.single, contains('error='));
      });
    });

    group('bulkScrapeStep', () {
      test(
        'reads the link map once and resolves every target from it',
        () async {
          await link(romId: 1, romname: 'a.sfc');
          await link(romId: 2, romname: 'b.sfc');
          await link(romId: 3, romname: 'c');
          final step = (await provider.bulkScrapeStep(media))!;
          // A row written after the index was read is invisible to the step:
          // proof that it never goes back to the table per game.
          await link(romId: 4, romname: 'd.sfc');

          final results = <String, RommScrapeStepResult>{};
          for (final name in ['a.sfc', 'b.sfc', 'c.sfc', 'd.sfc', 'e.sfc']) {
            results[name] = await step(
              RommScrapeTarget(
                appSystemId: 'snes',
                filename: name,
                systemFolder: 'snes',
              ),
            );
          }

          expect(results['a.sfc']!.status, RommScrapeStepStatus.scraped);
          expect(results['b.sfc']!.status, RommScrapeStepStatus.scraped);
          expect(
            results['c.sfc']!.status,
            RommScrapeStepStatus.scraped,
            reason: 'the stem spelling resolves like the fetch pass',
          );
          expect(results['d.sfc']!.status, RommScrapeStepStatus.notLinked);
          expect(results['e.sfc']!.status, RommScrapeStepStatus.notLinked);
          expect(svc.detailRequests, [1, 2, 3]);
          // The bulk step keys the row by the target's filename.
          expect(await row('a.sfc'), isNotNull);
          expect(await row('c.sfc'), isNotNull);
        },
      );

      test('a per-game step sees the row the bulk step missed', () async {
        final bulk = (await provider.bulkScrapeStep(media))!;
        await link();

        expect((await bulk(target)).status, RommScrapeStepStatus.notLinked);
        expect(
          (await provider.scrapeStep(media)!(target)).status,
          RommScrapeStepStatus.scraped,
        );
      });

      test('maps the overwrite flag onto the mode', () async {
        await link();
        await scrapedRow();
        final step = (await provider.bulkScrapeStep(media))!;

        await step(target);
        expect((await row())!['description_en'], 'SS English');

        await step(overwrite);
        expect((await row())!['description_en'], 'A time-travel RPG.');
      });
    });
  });
}
