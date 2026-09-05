import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_test_helper.dart';

/// ES-DE's `downloaded_media/` belongs to the user's ES-DE install: NeoStation
/// reads it as a fallback and must never write into it. Replacing artwork used
/// to write to whatever path the *read* resolver returned, which for an ES-DE
/// imported library is the ES-DE file itself — destroying the user's art.
///
/// Two layers guard that here: behavioural tests that every write destination
/// lands in NeoStation's own media folder, and a structural test that the ES-DE
/// path helpers gain no new consumers (the read resolvers are the only code
/// allowed to produce an ES-DE path at all).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every media type the artwork-replacement UI can write.
  const mediaTypes = ['screenshots', 'fanarts', 'wheels', 'box2d'];

  const game = GameModel(
    romname: 'sonic.smc',
    realname: 'Sonic',
    name: 'Sonic',
    year: '1991',
    developer: '',
    publisher: '',
    genre: '',
    players: '1',
    rating: 0,
    systemId: 'snes',
    systemFolderName: 'snes',
  );

  group('write destinations', () {
    final dbHelper = DatabaseTestHelper();
    late Directory tempDir;
    late Directory esdeRoot;
    late FileProvider provider;

    setUp(() async {
      final db = await dbHelper.setUp();
      tempDir = await Directory.systemTemp.createTemp('neostation_media_test');
      esdeRoot = Directory(path.join(tempDir.path, 'ES-DE'));
      await esdeRoot.create(recursive: true);

      // FileProvider resolves the media root through the custom user-data path.
      SharedPreferences.setMockInitialValues({
        'custom_user_data_path': tempDir.path,
      });

      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO user_config (id, esde_folder_path) VALUES (1, '${esdeRoot.path}')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) VALUES ('snes', 'snes')",
      );

      provider = FileProvider();
      await provider.initialize();
      expect(provider.isInitialized, isTrue);
    });

    tearDown(() async {
      await dbHelper.tearDown();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Writes an ES-DE asset in [category] for the test ROM and returns it.
    Future<File> writeEsdeAsset(String category) async {
      final file = File(
        path.join(
          esdeRoot.path,
          'downloaded_media',
          'snes',
          category,
          'sonic.png',
        ),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('es-de $category');
      return file;
    }

    /// The ES-DE category each NeoStation media type falls back to first.
    const esdeCategoryFor = {
      'screenshots': 'screenshots',
      'fanarts': 'fanart',
      'wheels': 'marquees',
      'box2d': 'covers',
    };

    test('reads ES-DE art when NeoStation has none of its own', () async {
      for (final type in mediaTypes) {
        final esdeFile = await writeEsdeAsset(esdeCategoryFor[type]!);

        expect(
          game.getImagePath('snes', type, provider),
          esdeFile.path,
          reason: '$type should fall back to ES-DE art',
        );
      }
    });

    test('never writes into ES-DE, for any media type', () async {
      final mediaRoot = path.join(tempDir.path, 'media');

      for (final type in mediaTypes) {
        final esdeFile = await writeEsdeAsset(esdeCategoryFor[type]!);
        final target = game.getWritableImagePath('snes', type, provider);

        expect(
          path.isWithin(mediaRoot, target),
          isTrue,
          reason: '$type write target must be inside NeoStation media: $target',
        );
        expect(
          path.isWithin(esdeRoot.path, target),
          isFalse,
          reason: '$type write target must be outside ES-DE: $target',
        );

        // Simulate the replacement the game settings dialog performs.
        await File(target).parent.create(recursive: true);
        await File(target).writeAsString('user picked art');

        // The ES-DE file survives untouched...
        expect(await esdeFile.readAsString(), 'es-de ${esdeCategoryFor[type]}');
        // ...and the NeoStation copy now shadows it everywhere.
        expect(game.getImagePath('snes', type, provider), target);
      }
    });

    test('the default destination is a NeoStation png', () async {
      expect(
        game.getWritableImagePath('snes', 'screenshots', provider),
        path.join(tempDir.path, 'media', 'snes', 'screenshots', 'sonic.png'),
      );
    });

    test('reuses an existing NeoStation file as the write target', () async {
      final existing = File(
        path.join(tempDir.path, 'media', 'snes', 'box2d', 'sonic.jpg'),
      );
      await existing.parent.create(recursive: true);
      await existing.writeAsString('old art');

      expect(
        game.getWritableImagePath('snes', 'box2d', provider),
        existing.path,
      );
    });

    test(
      'falls back to the default png destination without a file provider',
      () {
        expect(
          game.getWritableImagePath('snes', 'wheels'),
          path.join('media', 'snes', 'wheels', 'sonic.png'),
        );
      },
    );
  });

  group('import is read-only', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;
    late Directory tempDir;

    setUp(() async {
      db = await dbHelper.setUp();
      tempDir = await Directory.systemTemp.createTemp('neostation_ro_test');
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
      );
    });

    tearDown(() async {
      await dbHelper.tearDown();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Every entry under [root] (files with their contents, directories as
    /// markers), keyed by relative path, so a create, modify, or delete
    /// anywhere in the tree changes the snapshot.
    Map<String, String> snapshot(Directory root) {
      final out = <String, String>{};
      for (final entity in root.listSync(recursive: true)) {
        final rel = path.relative(entity.path, from: root.path);
        out[rel] = entity is File ? 'file:${entity.readAsStringSync()}' : 'dir';
      }
      return out;
    }

    // The platform folder is the user's ROM folder: the importer references
    // its media in place and never writes there.
    // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Read-Only Media Reference"
    test('in-folder import leaves the platform folder untouched', () async {
      final romFolder = Directory(path.join(tempDir.path, 'roms'));
      final snes = Directory(path.join(romFolder.path, 'snes'));
      await Directory(path.join(snes.path, 'covers')).create(recursive: true);
      await Directory(path.join(snes.path, 'screenshots')).create();
      await File(path.join(snes.path, 'sonic.smc')).writeAsString('rom');
      await File(path.join(snes.path, 'gamelist.xml')).writeAsString(
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name>'
        '<image>./screenshots/sonic.png</image></game></gameList>',
      );
      await File(
        path.join(snes.path, 'covers', 'sonic.png'),
      ).writeAsString('cover');
      await File(
        path.join(snes.path, 'screenshots', 'sonic.png'),
      ).writeAsString('shot');
      // A media-only sibling system is linked too, and must be as untouched.
      final nesCovers = Directory(path.join(romFolder.path, 'nes', 'covers'));
      await nesCovers.create(recursive: true);
      await File(path.join(nesCovers.path, 'mario.png')).writeAsString('art');

      final before = snapshot(romFolder);

      final result = await EsdeImportService.importInFolder([romFolder.path]);
      // The run must have done real work, or the assertion proves nothing.
      expect(result.gamesImported, 1);
      expect(result.mediaOnlyLinked, 1);

      expect(snapshot(romFolder), equals(before));
      final roots = await db.rawQuery(
        'SELECT app_system_id, esde_media_root FROM user_system_settings ORDER BY app_system_id',
      );
      expect(roots.map((r) => r['esde_media_root']), [
        path.join(romFolder.path, 'nes'),
        snes.path,
      ]);
    });

    test('ES-DE root import leaves the ES-DE folder untouched', () async {
      final esdeRoot = Directory(path.join(tempDir.path, 'ES-DE'));
      await Directory(
        path.join(esdeRoot.path, 'gamelists', 'snes'),
      ).create(recursive: true);
      await File(
        path.join(esdeRoot.path, 'gamelists', 'snes', 'gamelist.xml'),
      ).writeAsString(
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name></game></gameList>',
      );
      final covers = Directory(
        path.join(esdeRoot.path, 'downloaded_media', 'snes', 'covers'),
      );
      await covers.create(recursive: true);
      await File(path.join(covers.path, 'sonic.png')).writeAsString('cover');

      final before = snapshot(esdeRoot);

      final result = await EsdeImportService.import(esdeRoot.path);
      expect(result.gamesImported, 1);

      expect(snapshot(esdeRoot), equals(before));
    });
  });

  group('ES-DE paths cannot leak to new call sites', () {
    /// Only these files may mention the ES-DE path helpers: [FileProvider]
    /// defines them, and [GameModel]'s two *read* resolvers are the sole
    /// consumers. A new consumer anywhere else is how ES-DE art becomes
    /// writable again — the artwork-replacement bug was exactly that shape,
    /// a write target taken from a resolver that could return an ES-DE path.
    const allowedFiles = {
      'lib/providers/file_provider.dart',
      'lib/models/game_model.dart',
    };

    const esdeApis = ['getEsdeMediaCandidates(', 'getEsdeVideoCandidates('];

    test('only the read resolvers consume ES-DE path helpers', () {
      final offenders = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = path.relative(entity.path).replaceAll(r'\', '/');
        if (allowedFiles.contains(relative)) continue;

        final source = entity.readAsStringSync();
        for (final api in esdeApis) {
          if (source.contains(api)) offenders.add('$relative calls $api');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'ES-DE downloaded_media is read-only to NeoStation. If a new call '
            'site genuinely needs an ES-DE path it must be read-only too — add '
            'it to allowedFiles deliberately, never to silence this test.',
      );
    });
  });
}
