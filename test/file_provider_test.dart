import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/file_provider.dart';

import 'database_test_helper.dart';

void main() {
  group('FileProvider.stripRomExtension', () {
    test('strips known common ROM extensions', () {
      expect(FileProvider.stripRomExtension('game.zip'), 'game');
      expect(FileProvider.stripRomExtension('Sonic.md'), 'Sonic');
      expect(FileProvider.stripRomExtension('Mega Man X4.chd'), 'Mega Man X4');
    });

    test('preserves version-like suffixes', () {
      expect(FileProvider.stripRomExtension('game.v1'), 'game.v1');
      expect(FileProvider.stripRomExtension('game.123'), 'game.123');
    });

    test('leaves names without an extension untouched', () {
      expect(FileProvider.stripRomExtension('noext'), 'noext');
    });

    test('strips against a system-specific extension whitelist', () {
      expect(FileProvider.stripRomExtension('game.zip', {'zip'}), 'game');
    });

    test('does not strip a long non-whitelisted suffix', () {
      // 'foobar' is 6 chars, not a common ROM ext, and not whitelisted.
      expect(
        FileProvider.stripRomExtension('game.foobar', {'zip'}),
        'game.foobar',
      );
    });
  });

  group('FileProvider.getEsdeMediaCandidates', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;
    late FileProvider provider;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO user_config (esde_folder_path) VALUES ('/esde')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) VALUES ('snes', 'snes')",
      );
      provider = FileProvider();
      await provider.refreshEsde();
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    test('covers every mapped ES-DE category and extension', () {
      final candidates = provider.getEsdeMediaCandidates(
        'snes',
        'box2d',
        'sonic.smc',
      );
      expect(candidates, [
        '/esde/downloaded_media/snes/covers/sonic.png',
        '/esde/downloaded_media/snes/covers/sonic.jpg',
        '/esde/downloaded_media/snes/covers/sonic.webp',
        '/esde/downloaded_media/snes/3dboxes/sonic.png',
        '/esde/downloaded_media/snes/3dboxes/sonic.jpg',
        '/esde/downloaded_media/snes/3dboxes/sonic.webp',
      ]);
    });

    test(
      'falls back to the category root after the recorded subfolder',
      () async {
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, esde_media_subdir) VALUES ('snes', 'sonic.smc', 'Hacks')",
        );
        await provider.refreshEsde();

        final candidates = provider.getEsdeMediaCandidates(
          'snes',
          'wheels',
          'sonic.smc',
        );
        expect(candidates, [
          '/esde/downloaded_media/snes/marquees/Hacks/sonic.png',
          '/esde/downloaded_media/snes/marquees/Hacks/sonic.jpg',
          '/esde/downloaded_media/snes/marquees/Hacks/sonic.webp',
          '/esde/downloaded_media/snes/marquees/sonic.png',
          '/esde/downloaded_media/snes/marquees/sonic.jpg',
          '/esde/downloaded_media/snes/marquees/sonic.webp',
        ]);
      },
    );

    test('follows a relocated ES-DE MediaDirectory', () async {
      // ES-DE lets the user move the media folder; the choice lives in
      // es_settings.xml and replaces `downloaded_media` outright (issue #456).
      final esdeRoot = Directory.systemTemp.createTempSync('esde_root_');
      addTearDown(() => esdeRoot.deleteSync(recursive: true));
      final mediaDir = Directory.systemTemp.createTempSync('esde_media_');
      addTearDown(() => mediaDir.deleteSync(recursive: true));

      Directory('${esdeRoot.path}/settings').createSync(recursive: true);
      File('${esdeRoot.path}/settings/es_settings.xml').writeAsStringSync(
        '<string name="MediaDirectory" value="${mediaDir.path}" />',
      );

      await db.update('user_config', {'esde_folder_path': esdeRoot.path});
      await provider.refreshEsde();

      expect(provider.getEsdeMediaCandidates('snes', 'fanarts', 'sonic.smc'), [
        '${mediaDir.path}/snes/fanart/sonic.png',
        '${mediaDir.path}/snes/fanart/sonic.jpg',
        '${mediaDir.path}/snes/fanart/sonic.webp',
      ]);
    });

    test('returns nothing for a system with no recorded ES-DE media dir', () {
      expect(
        provider.getEsdeMediaCandidates('nes', 'box2d', 'mario.nes'),
        isEmpty,
      );
    });

    test('never offers a miximage for any media type', () {
      // Miximages are composites (screenshot + box + marquee baked together),
      // so they misrepresent every slot NeoStation renders — worst of all the
      // fanart background, over which the wheel is drawn a second time.
      for (final type in const [
        'box2d',
        'wheels',
        'screenshots',
        'fanarts',
        'videos',
      ]) {
        expect(
          provider.getEsdeMediaCandidates('snes', type, 'sonic.smc'),
          isNot(contains(contains('miximages'))),
          reason: '$type must not fall back to an ES-DE miximage',
        );
      }
    });

    test('screenshots fall back to titlescreens only', () {
      expect(
        provider.getEsdeMediaCandidates('snes', 'screenshots', 'sonic.smc'),
        [
          '/esde/downloaded_media/snes/screenshots/sonic.png',
          '/esde/downloaded_media/snes/screenshots/sonic.jpg',
          '/esde/downloaded_media/snes/screenshots/sonic.webp',
          '/esde/downloaded_media/snes/titlescreens/sonic.png',
          '/esde/downloaded_media/snes/titlescreens/sonic.jpg',
          '/esde/downloaded_media/snes/titlescreens/sonic.webp',
        ],
      );
    });

    test('fanarts resolve from the fanart category alone', () {
      expect(provider.getEsdeMediaCandidates('snes', 'fanarts', 'sonic.smc'), [
        '/esde/downloaded_media/snes/fanart/sonic.png',
        '/esde/downloaded_media/snes/fanart/sonic.jpg',
        '/esde/downloaded_media/snes/fanart/sonic.webp',
      ]);
    });
  });
  group('FileProvider per-system media root', () {
    // In-folder (RomM / Batocera) imports record the platform folder itself as
    // the system's absolute media root; ES-DE imports keep recording a folder
    // name under the global ES-DE root. Both must resolve side by side, and
    // an absolute root must not depend on the ES-DE root path setting.
    //
    // Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ
    // "Per-System Media Root", REQ "Media Category Mapping"
    final dbHelper = DatabaseTestHelper();
    late dynamic db;
    late FileProvider provider;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('gba', 'GBA', 'gba', 12)",
      );
      provider = FileProvider();
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    test('resolves an in-folder system with no ES-DE root configured', () async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
      );
      await provider.refreshEsde();

      expect(
        provider.getEsdeMediaCandidates('snes', 'box2d', 'Chrono Trigger.sfc'),
        [
          '/roms/snes/covers/Chrono Trigger.png',
          '/roms/snes/covers/Chrono Trigger.jpg',
          '/roms/snes/covers/Chrono Trigger.webp',
          '/roms/snes/3dboxes/Chrono Trigger.png',
          '/roms/snes/3dboxes/Chrono Trigger.jpg',
          '/roms/snes/3dboxes/Chrono Trigger.webp',
          '/roms/snes/thumbnails/Chrono Trigger.png',
          '/roms/snes/thumbnails/Chrono Trigger.jpg',
          '/roms/snes/thumbnails/Chrono Trigger.webp',
        ],
      );
    });

    test('resolves an in-folder system when the ES-DE root is blank', () async {
      await db.execute(
        "INSERT INTO user_config (esde_folder_path) VALUES ('')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
      );
      await provider.refreshEsde();

      expect(provider.getEsdeMediaCandidates('snes', 'wheels', 'Game.sfc'), [
        '/roms/snes/marquees/Game.png',
        '/roms/snes/marquees/Game.jpg',
        '/roms/snes/marquees/Game.webp',
      ]);
    });

    test('an ES-DE folder name alone still needs the ES-DE root', () async {
      // Name-only rows are meaningless without the global root to join them
      // under, so the pre-existing gate stays for them.
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) VALUES ('snes', 'snes')",
      );
      await provider.refreshEsde();

      expect(
        provider.getEsdeMediaCandidates('snes', 'box2d', 'sonic.smc'),
        isEmpty,
      );
    });

    test('ES-DE and in-folder systems resolve side by side', () async {
      await db.execute(
        "INSERT INTO user_config (esde_folder_path) VALUES ('/esde')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) VALUES ('snes', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('nes', '/roms/nes')",
      );
      await provider.refreshEsde();

      expect(provider.getEsdeMediaCandidates('snes', 'fanarts', 'sonic.smc'), [
        '/esde/downloaded_media/snes/fanart/sonic.png',
        '/esde/downloaded_media/snes/fanart/sonic.jpg',
        '/esde/downloaded_media/snes/fanart/sonic.webp',
      ]);
      expect(provider.getEsdeMediaCandidates('nes', 'fanarts', 'mario.nes'), [
        '/roms/nes/fanart/mario.png',
        '/roms/nes/fanart/mario.jpg',
        '/roms/nes/fanart/mario.webp',
      ]);
      expect(
        provider.getEsdeMediaCandidates('gba', 'fanarts', 'zelda.gba'),
        isEmpty,
        reason: 'a system with neither location recorded yields nothing',
      );
    });

    test('an absolute root wins over an ES-DE folder name', () async {
      await db.execute(
        "INSERT INTO user_config (esde_folder_path) VALUES ('/esde')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir, esde_media_root) VALUES ('snes', 'snes', '/roms/snes')",
      );
      await provider.refreshEsde();

      expect(provider.getEsdeMediaCandidates('snes', 'wheels', 'sonic.smc'), [
        '/roms/snes/marquees/sonic.png',
        '/roms/snes/marquees/sonic.jpg',
        '/roms/snes/marquees/sonic.webp',
      ]);
    });

    // A SAF import records `<user data>/imported_media/<system>` as the
    // absolute root; resolution is the unchanged absolute-root path.
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
    test('resolves a mirrored SAF system from its imported_media root', () async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/data/user-data/imported_media/snes')",
      );
      await provider.refreshEsde();

      expect(
        provider.getEsdeMediaCandidates('snes', 'box2d', 'Chrono Trigger.sfc'),
        contains(
          '/data/user-data/imported_media/snes/covers/Chrono Trigger.png',
        ),
      );
      expect(
        provider.getEsdeVideoCandidates('snes', 'Chrono Trigger.sfc'),
        contains(
          '/data/user-data/imported_media/snes/videos/Chrono Trigger.mp4',
        ),
      );
    });

    test('screenshots fall back to RomM images after titlescreens', () async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
      );
      await provider.refreshEsde();

      expect(
        provider.getEsdeMediaCandidates('snes', 'screenshots', 'sonic.smc'),
        [
          '/roms/snes/screenshots/sonic.png',
          '/roms/snes/screenshots/sonic.jpg',
          '/roms/snes/screenshots/sonic.webp',
          '/roms/snes/titlescreens/sonic.png',
          '/roms/snes/titlescreens/sonic.jpg',
          '/roms/snes/titlescreens/sonic.webp',
          '/roms/snes/images/sonic.png',
          '/roms/snes/images/sonic.jpg',
          '/roms/snes/images/sonic.webp',
        ],
      );
    });

    test('unmapped folders never produce candidates', () async {
      // A platform folder holding only manuals/, miximages/, backcovers/,
      // bezels/ or physicalmedia/ contributes nothing to any slot.
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
      );
      await provider.refreshEsde();

      const unmapped = [
        'manuals',
        'miximages',
        'backcovers',
        'bezels',
        'physicalmedia',
      ];
      for (final type in const [
        'box2d',
        'wheels',
        'screenshots',
        'fanarts',
        'videos',
      ]) {
        final candidates = provider.getEsdeMediaCandidates(
          'snes',
          type,
          'sonic.smc',
        );
        for (final folder in unmapped) {
          expect(
            candidates,
            isNot(contains(contains('/roms/snes/$folder/'))),
            reason: '$type must not look in $folder',
          );
        }
      }
      expect(
        provider.getEsdeMediaCandidates('snes', 'manuals', 'sonic.smc'),
        isEmpty,
        reason: 'an unmapped media type is not a slot at all',
      );
    });

    test('honours the recorded subfolder under an absolute root', () async {
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
      );
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, esde_media_subdir) VALUES ('snes', 'sonic.smc', 'Hacks')",
      );
      await provider.refreshEsde();

      expect(provider.getEsdeMediaCandidates('snes', 'wheels', 'sonic.smc'), [
        '/roms/snes/marquees/Hacks/sonic.png',
        '/roms/snes/marquees/Hacks/sonic.jpg',
        '/roms/snes/marquees/Hacks/sonic.webp',
        '/roms/snes/marquees/sonic.png',
        '/roms/snes/marquees/sonic.jpg',
        '/roms/snes/marquees/sonic.webp',
      ]);
    });

    test(
      'videos under an absolute root keep the ES-DE extension order',
      () async {
        await db.execute(
          "INSERT INTO user_system_settings (app_system_id, esde_media_root) VALUES ('snes', '/roms/snes')",
        );
        await provider.refreshEsde();

        expect(provider.getEsdeVideoCandidates('snes', 'sonic.smc'), [
          '/roms/snes/videos/sonic.mp4',
          '/roms/snes/videos/sonic.webm',
          '/roms/snes/videos/sonic.mkv',
          '/roms/snes/videos/sonic.avi',
          '/roms/snes/videos/sonic.wmv',
          '/roms/snes/videos/sonic.mov',
          '/roms/snes/videos/sonic.m4v',
        ]);
      },
    );
  });

  group('FileProvider.getEsdeVideoCandidates', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;
    late FileProvider provider;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO user_config (esde_folder_path) VALUES ('/esde')",
      );
      await db.execute(
        "INSERT INTO user_system_settings (app_system_id, esde_media_dir) VALUES ('snes', 'snes')",
      );
      provider = FileProvider();
      await provider.refreshEsde();
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    test('covers every video extension ES-DE writes, mp4 first', () {
      expect(provider.getEsdeVideoCandidates('snes', 'sonic.smc'), [
        '/esde/downloaded_media/snes/videos/sonic.mp4',
        '/esde/downloaded_media/snes/videos/sonic.webm',
        '/esde/downloaded_media/snes/videos/sonic.mkv',
        '/esde/downloaded_media/snes/videos/sonic.avi',
        '/esde/downloaded_media/snes/videos/sonic.wmv',
        '/esde/downloaded_media/snes/videos/sonic.mov',
        '/esde/downloaded_media/snes/videos/sonic.m4v',
      ]);
    });

    test(
      'falls back to the category root after the recorded subfolder',
      () async {
        // The subfolder recorded at import time is only ever one of the folders
        // ES-DE listed this ROM in, so a video sitting at the category root has
        // to stay reachable — images already behave this way.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, esde_media_subdir) VALUES ('snes', 'sonic.smc', 'Hacks')",
        );
        await provider.refreshEsde();

        expect(provider.getEsdeVideoCandidates('snes', 'sonic.smc'), [
          '/esde/downloaded_media/snes/videos/Hacks/sonic.mp4',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.webm',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.mkv',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.avi',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.wmv',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.mov',
          '/esde/downloaded_media/snes/videos/Hacks/sonic.m4v',
          '/esde/downloaded_media/snes/videos/sonic.mp4',
          '/esde/downloaded_media/snes/videos/sonic.webm',
          '/esde/downloaded_media/snes/videos/sonic.mkv',
          '/esde/downloaded_media/snes/videos/sonic.avi',
          '/esde/downloaded_media/snes/videos/sonic.wmv',
          '/esde/downloaded_media/snes/videos/sonic.mov',
          '/esde/downloaded_media/snes/videos/sonic.m4v',
        ]);
      },
    );

    test('returns nothing for a system with no recorded ES-DE media dir', () {
      // getVideoPath keys on this to skip the existence checks entirely, so an
      // empty list is the contract, not just an absence of candidates.
      expect(provider.getEsdeVideoCandidates('nes', 'mario.nes'), isEmpty);
    });
  });
}
