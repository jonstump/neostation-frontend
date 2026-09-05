import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/services/esde_import_service.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'database_test_helper.dart';

/// An in-memory SAF tree behind the importer's four read-only overrides.
/// Records every call so a test can assert exactly how the tree was touched:
/// one listing per folder, whole-file reads for gamelists only, ranged reads
/// for mirrored media, and nothing that is not a list, read, or grant check.
class RecordingSaf {
  static const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3Aroms';

  /// Folder URI → its children, in the `listFiles` map shape.
  final Map<String, List<Map<String, dynamic>>> listings = {};

  /// Document URI → bytes (`null` models a read the provider refused).
  final Map<String, Uint8List?> documents = {};

  /// Folder URIs whose listing throws, standing in for a lost grant.
  final Set<String> failListing = {};

  /// Document URIs whose read throws rather than returning null.
  final Set<String> failRead = {};

  /// Tree URIs the fake reports no persisted grant for.
  final Set<String> noPermission = {};

  /// Free bytes the fake reports for the mirror volume (null: unmeasurable).
  int? freeSpace = 1 << 40;

  /// When set, every listing waits on it first, so a test can hold an import
  /// open while it starts another.
  Completer<void>? gate;

  /// Every call in order, as `op:uri`.
  final List<String> calls = [];

  /// URI of `<treeUri>/<relativePath>` in the SAF document form.
  static String uriOf(String relativePath) {
    if (relativePath.isEmpty) return treeUri;
    final encoded = Uri.encodeComponent('roms/$relativePath');
    return '$treeUri/document/primary%3A$encoded';
  }

  /// Adds a folder at [relativePath] to its parent's listing.
  String dir(String relativePath) {
    final uri = uriOf(relativePath);
    _addChild(relativePath, {
      'name': p.basename(relativePath),
      'uri': uri,
      'isDirectory': true,
      'size': 0,
      'lastModified': 0,
    });
    listings.putIfAbsent(uri, () => []);
    return uri;
  }

  /// Adds a document at [relativePath] holding [content].
  String file(String relativePath, String content) {
    final uri = uriOf(relativePath);
    final bytes = Uint8List.fromList(utf8.encode(content));
    _addChild(relativePath, {
      'name': p.basename(relativePath),
      'uri': uri,
      'isDirectory': false,
      'size': bytes.length,
      'lastModified': 0,
    });
    documents[uri] = bytes;
    return uri;
  }

  void _addChild(String relativePath, Map<String, dynamic> entry) {
    final parent = p.dirname(relativePath);
    final parentUri = uriOf(parent == '.' ? '' : parent);
    listings.putIfAbsent(parentUri, () => []).add(entry);
  }

  Future<List<Map<String, dynamic>>> listFiles(String uri) async {
    calls.add('list:$uri');
    final gate = this.gate;
    if (gate != null) await gate.future;
    if (failListing.contains(uri)) {
      throw StateError('listing refused for $uri');
    }
    return listings[uri] ?? const [];
  }

  Future<Uint8List?> readRange(String uri, int offset, int length) async {
    calls.add('range:$uri:$offset');
    if (failRead.contains(uri)) throw StateError('read refused for $uri');
    final data = documents[uri];
    if (data == null) return null;
    if (offset >= data.length) return Uint8List(0);
    final end = (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, offset, end);
  }

  Future<Uint8List?> readFile(String uri) async {
    calls.add('read:$uri');
    if (failRead.contains(uri)) throw StateError('read refused for $uri');
    return documents[uri];
  }

  Future<bool> hasPermission(String uri) async {
    calls.add('perm:$uri');
    return !noPermission.contains(uri);
  }

  Iterable<String> get listedUris =>
      calls.where((c) => c.startsWith('list:')).map((c) => c.substring(5));

  Iterable<String> get readUris =>
      calls.where((c) => c.startsWith('read:')).map((c) => c.substring(5));

  Iterable<String> get rangeCalls => calls.where((c) => c.startsWith('range:'));

  /// Routes the importer's SAF operations through this fake, with the media
  /// mirror rooted at [mirrorRoot]; the override slots are cleared again by
  /// [uninstall].
  void install({required String mirrorRoot}) {
    EsdeImportService.safListFilesOverride = listFiles;
    EsdeImportService.safReadFileOverride = readFile;
    EsdeImportService.safReadRangeOverride = readRange;
    EsdeImportService.safHasPermissionOverride = hasPermission;
    EsdeImportService.freeSpaceBytesOverride = (_) async => freeSpace;
    EsdeImportService.mirrorRootOverride = mirrorRoot;
    // A content:// tree with no real path is the SAF-branch trigger.
    EsdeImportService.safRomFolderResolverOverride = (_) async => null;
  }

  static void uninstall() {
    EsdeImportService.safListFilesOverride = null;
    EsdeImportService.safReadFileOverride = null;
    EsdeImportService.safReadRangeOverride = null;
    EsdeImportService.safHasPermissionOverride = null;
    EsdeImportService.freeSpaceBytesOverride = null;
    EsdeImportService.mirrorRootOverride = null;
    EsdeImportService.safRomFolderResolverOverride = null;
  }
}

void main() {
  group('EsdeImportService pure helpers', () {
    group('parseRating', () {
      test('scales ES-DE 0..1 rating up to the 0..20 scale', () {
        expect(EsdeImportService.parseRatingForTest('0.5'), 10.0);
        expect(EsdeImportService.parseRatingForTest('1'), 20.0);
        expect(EsdeImportService.parseRatingForTest('0'), 0.0);
      });

      test('clamps out-of-range values into 0..1 before scaling', () {
        expect(EsdeImportService.parseRatingForTest('2'), 20.0);
        expect(EsdeImportService.parseRatingForTest('-1'), 0.0);
      });

      test('returns null for null / blank / non-numeric input', () {
        expect(EsdeImportService.parseRatingForTest(null), isNull);
        expect(EsdeImportService.parseRatingForTest('   '), isNull);
        expect(EsdeImportService.parseRatingForTest('abc'), isNull);
      });
    });

    group('parseEsdeDateTime', () {
      test('parses a full ES-DE datetime', () {
        expect(
          EsdeImportService.parseEsdeDateTimeForTest('19950311T000000'),
          DateTime(1995, 3, 11),
        );
      });

      test('parses a date-only value (no time component)', () {
        expect(
          EsdeImportService.parseEsdeDateTimeForTest('20010921'),
          DateTime(2001, 9, 21),
        );
      });

      test('rejects placeholder / zero / malformed dates', () {
        expect(EsdeImportService.parseEsdeDateTimeForTest('00000000'), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest('1995'), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest(''), isNull);
        expect(EsdeImportService.parseEsdeDateTimeForTest(null), isNull);
      });
    });

    group('mediaSubdir', () {
      test('returns empty for a ROM directly in the system folder', () {
        expect(EsdeImportService.mediaSubdirForTest('./Sonic.md'), '');
        expect(EsdeImportService.mediaSubdirForTest('Sonic.md'), '');
      });

      test('returns the ROM subfolder relative to the system folder', () {
        expect(
          EsdeImportService.mediaSubdirForTest('./Hacks/Sonic.md'),
          'Hacks',
        );
        expect(EsdeImportService.mediaSubdirForTest('./A/B/Sonic.md'), 'A/B');
      });
    });

    group('selectGames', () {
      test('de-duplicates entries sharing a ROM filename', () {
        final doc = XmlDocument.parse('''
          <gameList>
            <game><path>./Sonic.md</path><name>Base</name></game>
            <game><path>./Hacks/Sonic.md</path><name>Hack</name></game>
          </gameList>
        ''');
        // esdeRoot doesn't exist, so _esdeMediaExists is false for both and the
        // first-seen entry is kept.
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'megadrive',
        );
        expect(chosen.length, 1);
      });

      test('keeps distinct filenames', () {
        final doc = XmlDocument.parse('''
          <gameList>
            <game><path>./Sonic.md</path></game>
            <game><path>./Streets.md</path></game>
          </gameList>
        ''');
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'megadrive',
        );
        expect(chosen.length, 2);
      });

      test('reads a gamelist with a second <alternativeEmulator> root', () {
        // ES-DE writes the per-system emulator override as a SECOND root
        // element ahead of <gameList>, which is invalid XML that only a
        // lenient parser accepts. Parsing as a fragment must still see the
        // games.
        final doc = XmlDocumentFragment.parse('''<?xml version="1.0"?>
<alternativeEmulator>
    <label>FinalBurn Neo</label>
</alternativeEmulator>
<gameList>
    <game><path>./fbneo/sonicwi2.zip</path><name>Aero Fighters 2</name></game>
    <game><path>./mame/dkong.zip</path><name>Donkey Kong</name></game>
</gameList>
''');
        final chosen = EsdeImportService.selectGamesForTest(
          doc,
          '/no/such/root',
          'arcade',
        );
        expect(chosen.length, 2);
      });
    });
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
  group('isUnderMirrorRoot', () {
    final root = p.join(p.separator, 'data', 'imported_media');

    test('a system directory under the root is inside', () {
      expect(
        EsdeImportService.isUnderMirrorRoot(p.join(root, 'snes'), root),
        isTrue,
      );
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(root, 'snes', 'covers'),
          root,
        ),
        isTrue,
      );
    });

    test('the root itself and a trailing separator are not inside', () {
      expect(EsdeImportService.isUnderMirrorRoot(root, root), isFalse);
      expect(
        EsdeImportService.isUnderMirrorRoot('$root${p.separator}', root),
        isFalse,
      );
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(root, 'snes'),
          '$root${p.separator}',
        ),
        isTrue,
      );
    });

    test('a prefix look-alike sibling is outside', () {
      expect(
        EsdeImportService.isUnderMirrorRoot(p.join('${root}2', 'snes'), root),
        isFalse,
      );
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(p.separator, 'data', 'imported_media_old', 'snes'),
          root,
        ),
        isFalse,
      );
    });

    test('a real platform folder and a content URI are outside', () {
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(p.separator, 'storage', 'roms', 'snes'),
          root,
        ),
        isFalse,
      );
      expect(
        EsdeImportService.isUnderMirrorRoot('content://tree/snes', root),
        isFalse,
      );
    });

    test('a dot-dot escape is normalized before the check', () {
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(root, 'snes', '..', '..', 'media'),
          root,
        ),
        isFalse,
      );
      expect(
        EsdeImportService.isUnderMirrorRoot(
          p.join(root, 'snes', '..', 'nes'),
          root,
        ),
        isTrue,
      );
    });
  });

  group('resolveMediaRoot', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('esde_settings_');
    });

    tearDown(() => root.deleteSync(recursive: true));

    void writeSettings(String body) {
      Directory('${root.path}/settings').createSync(recursive: true);
      File('${root.path}/settings/es_settings.xml').writeAsStringSync(body);
    }

    test('defaults to downloaded_media when there is no settings file', () {
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('defaults when MediaDirectory is absent or blank', () {
      writeSettings(
        '<?xml version="1.0"?>\n<string name="ROMDirectory" value="/roms" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );

      writeSettings('<string name="MediaDirectory" value="" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('uses a custom MediaDirectory that exists', () {
      final custom = Directory('${root.path}/elsewhere/media')
        ..createSync(recursive: true);
      writeSettings('<string name="MediaDirectory" value="${custom.path}" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('ignores a trailing separator on the value', () {
      final custom = Directory('${root.path}/elsewhere/media')
        ..createSync(recursive: true);
      writeSettings('<string name="MediaDirectory" value="${custom.path}/" />');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('expands %ESPATH% against the ES-DE folder and its parent', () {
      // Portable layout: the binary sits next to the data folder, so
      // %ESPATH% is the PARENT of the folder the user picked.
      final custom = Directory('${root.parent.path}/media_espath')
        ..createSync(recursive: true);
      addTearDown(() => custom.deleteSync(recursive: true));
      writeSettings(
        '<string name="MediaDirectory" value="%ESPATH%/media_espath" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.normalize(custom.path),
      );
    });

    test('falls back to downloaded_media when the custom folder is gone', () {
      writeSettings(
        '<string name="MediaDirectory" value="${root.path}/not_there" />',
      );
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });

    test('survives a malformed settings file', () {
      writeSettings('<string name="MediaDirectory" value="/x" ');
      expect(
        EsdeImportService.resolveMediaRoot(root.path),
        p.join(root.path, 'downloaded_media'),
      );
    });
  });

  group('EsdeImportService DB behavior', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
    });

    tearDown(() async {
      await dbHelper.tearDown();
    });

    test(
      'reset deletes only ES-DE-created rows, not NeoStation partial scrapes',
      () async {
        // An ES-DE-created row (mergeEsdeMetadata sets esde_imported = 1).
        await ScraperRepository.mergeEsdeMetadata('snes', 'esde.smc', {
          'real_name': 'ES-DE Game',
        });
        // A NeoStation partial-scrape row: also is_fully_scraped = 0, but NOT
        // ES-DE-imported. reset() must leave this one untouched.
        await db.execute(
          "INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name, is_fully_scraped, esde_imported) VALUES ('snes', 'neo.smc', 'Neo Game', 0, 0)",
        );

        final deleted = await EsdeImportService.reset();
        expect(deleted, 1);

        final rows = await db.rawQuery(
          'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
        );
        expect(rows.length, 1);
        expect(rows.first['filename'], 'neo.smc');
      },
    );

    test(
      'import keys metadata on the scanned ROM filename, not the gamelist casing',
      () async {
        // Scanned ROM is lowercase; the gamelist lists it title-cased.
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
        );

        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));
        final systemDir = Directory('${tempRoot.path}/gamelists/snes')
          ..createSync(recursive: true);
        File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
          <gameList>
            <game>
              <path>./Sonic.smc</path>
              <name>Sonic the Hedgehog</name>
              <rating>0.8</rating>
            </game>
          </gameList>
        ''');

        final result = await EsdeImportService.import(tempRoot.path);
        expect(result.gamesImported, 1);

        final rows = await db.rawQuery(
          'SELECT filename, real_name FROM user_screenscraper_metadata',
        );
        expect(rows.length, 1);
        // Keyed on the scanned casing so the case-sensitive display join
        // (user_roms.filename = metadata.filename) resolves.
        expect(rows.first['filename'], 'sonic.smc');
        expect(rows.first['real_name'], 'Sonic the Hedgehog');
      },
    );

    test(
      'import handles a gamelist with an <alternativeEmulator> root',
      () async {
        await db.execute(
          "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
        );

        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));
        final systemDir = Directory('${tempRoot.path}/gamelists/snes')
          ..createSync(recursive: true);
        // Exactly what ES-DE writes once the user picks a non-default emulator
        // for the system: two root elements in one file.
        File('${systemDir.path}/gamelist.xml').writeAsStringSync(
          '''<?xml version="1.0"?>
<alternativeEmulator>
    <label>Snes9x - Current</label>
</alternativeEmulator>
<gameList>
    <game>
        <path>./sonic.smc</path>
        <name>Sonic the Hedgehog</name>
        <altemulator>Snes9x - Current</altemulator>
    </game>
</gameList>
''',
        );

        final result = await EsdeImportService.import(tempRoot.path);
        expect(result.systemsSkipped, 0);
        expect(result.systemsMatched, 1);
        expect(result.gamesImported, 1);
      },
    );

    test('import reads media from a relocated ES-DE MediaDirectory', () async {
      // A second system whose art exists but that has no gamelist.xml, so the
      // only thing that can wire it up is the media walk (issue #456).
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('megadrive', 'Mega Drive', 'megadrive', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));

      // The media lives OUTSIDE the ES-DE folder, exactly as it does once the
      // user moves it: `<tempRoot>/downloaded_media` never exists.
      final mediaDir = Directory.systemTemp.createTempSync('esde_media_');
      addTearDown(() => mediaDir.deleteSync(recursive: true));
      Directory(
        '${mediaDir.path}/megadrive/covers',
      ).createSync(recursive: true);
      File(
        '${mediaDir.path}/megadrive/covers/sonic.png',
      ).writeAsStringSync('x');

      Directory('${tempRoot.path}/settings').createSync(recursive: true);
      File('${tempRoot.path}/settings/es_settings.xml').writeAsStringSync(
        '<?xml version="1.0"?>\n'
        '<string name="MediaDirectory" value="${mediaDir.path}" />\n',
      );

      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync(
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name></game></gameList>',
      );

      await EsdeImportService.import(tempRoot.path);

      final rows = await db.rawQuery(
        "SELECT esde_media_dir FROM user_system_settings WHERE app_system_id = 'megadrive'",
      );
      expect(rows.length, 1);
      expect(rows.first['esde_media_dir'], 'megadrive');
    });

    test('import does not skip games ES-DE marks hidden', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('secret.smc', '/roms/snes/secret.smc', 'snes')",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
        <gameList>
          <game>
            <path>./sonic.smc</path>
            <name>Sonic the Hedgehog</name>
          </game>
          <game>
            <path>./secret.smc</path>
            <name>Hidden Game</name>
            <hidden>true</hidden>
            <favorite>true</favorite>
          </game>
        </gameList>
      ''');

      final result = await EsdeImportService.import(tempRoot.path);
      expect(result.gamesImported, 2);

      // Hiding a game in ES-DE must not withhold its metadata or stats here:
      // the user may well have forgotten they hid it.
      final rows = await db.rawQuery(
        'SELECT filename FROM user_screenscraper_metadata ORDER BY filename',
      );
      expect(rows.map((r) => r['filename']), ['secret.smc', 'sonic.smc']);
      final hiddenRom = await db.rawQuery(
        "SELECT is_favorite FROM user_roms WHERE filename = 'secret.smc'",
      );
      expect(hiddenRom.first['is_favorite'], 1);
    });

    test('import fills play_time only when NeoStation has none', () async {
      // sonic has never been played here; streets already has local playtime
      // that the import must not clobber.
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) VALUES ('sonic.smc', '/roms/snes/sonic.smc', 'snes', 0)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, play_time) VALUES ('streets.smc', '/roms/snes/streets.smc', 'snes', 900)",
      );

      final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      final systemDir = Directory('${tempRoot.path}/gamelists/snes')
        ..createSync(recursive: true);
      File('${systemDir.path}/gamelist.xml').writeAsStringSync('''
        <gameList>
          <game>
            <path>./sonic.smc</path>
            <name>Sonic the Hedgehog</name>
            <playcount>3</playcount>
            <playtime>47</playtime>
          </game>
          <game>
            <path>./streets.smc</path>
            <name>Streets of Rage</name>
            <playtime>12</playtime>
          </game>
        </gameList>
      ''');

      await EsdeImportService.import(tempRoot.path);

      final rows = await db.rawQuery(
        'SELECT filename, play_time FROM user_roms ORDER BY filename',
      );
      expect(rows[0]['filename'], 'sonic.smc');
      expect(rows[0]['play_time'], 47);
      expect(rows[1]['filename'], 'streets.smc');
      expect(rows[1]['play_time'], 900);
    });

    test(
      'import links art for a system that has downloaded_media but no gamelist',
      () async {
        final tempRoot = Directory.systemTemp.createTempSync('esde_test_');
        addTearDown(() => tempRoot.deleteSync(recursive: true));

        // snes has a gamelist; nes has artwork only. ES-DE leaves systems in
        // this state whenever media outlives (or precedes) a gamelist.
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
        );
        Directory(
          '${tempRoot.path}/gamelists/snes',
        ).createSync(recursive: true);
        File(
          '${tempRoot.path}/gamelists/snes/gamelist.xml',
        ).writeAsStringSync('<gameList></gameList>');
        Directory(
          '${tempRoot.path}/downloaded_media/nes/covers',
        ).createSync(recursive: true);

        await EsdeImportService.import(tempRoot.path);

        final rows = await db.rawQuery(
          "SELECT app_system_id, esde_media_dir FROM user_system_settings WHERE esde_media_dir IS NOT NULL ORDER BY app_system_id",
        );
        expect(rows.map((r) => r['app_system_id']).toList(), ['nes', 'snes']);
        expect(rows.first['esde_media_dir'], 'nes');
      },
    );
  });

  group('EsdeImportService in-folder mode', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;

    setUp(() async {
      // Pin the mirror root to a temp dir so no test in this group can ever
      // reach the real user-data path through _resolveMirrorRoot().
      EsdeImportService.mirrorRootOverride = Directory.systemTemp
          .createTempSync('esde_infolder_mirror_')
          .path;
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
      );
    });

    tearDown(() async {
      final pinned = EsdeImportService.mirrorRootOverride;
      EsdeImportService.mirrorRootOverride = null;
      if (pinned != null) Directory(pinned).deleteSync(recursive: true);
      EsdeImportService.safRomFolderResolverOverride = null;
      await dbHelper.tearDown();
    });

    /// A fresh ROM folder, removed after the test.
    Directory romFolder() {
      final dir = Directory.systemTemp.createTempSync('esde_infolder_');
      addTearDown(() => dir.deleteSync(recursive: true));
      return dir;
    }

    /// Writes `<romFolder>/<system>/gamelist.xml` and returns the system dir.
    Directory writeGamelist(Directory romFolder, String system, String xml) {
      final systemDir = Directory(p.join(romFolder.path, system))
        ..createSync(recursive: true);
      File(p.join(systemDir.path, 'gamelist.xml')).writeAsStringSync(xml);
      return systemDir;
    }

    Future<void> seedRom(String filename, String systemId) => db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('$filename', '/roms/$systemId/$filename', '$systemId')",
    );

    Future<Map<String, Object?>> mediaLocation(String systemId) async {
      final rows = await db.rawQuery(
        "SELECT esde_media_dir, esde_media_root FROM user_system_settings WHERE app_system_id = '$systemId'",
      );
      return rows.isEmpty ? const {} : rows.first;
    }

    const sonicGamelist =
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name></game></gameList>';
    const marioGamelist =
        '<gameList><game><path>./mario.nes</path><name>Mario</name></game></gameList>';

    test('imports systems from two ROM folders and records the platform folder '
        'as each media root', () async {
      await seedRom('sonic.smc', 'snes');
      await seedRom('mario.nes', 'nes');
      final romA = romFolder();
      final romB = romFolder();
      final snesDir = writeGamelist(romA, 'snes', sonicGamelist);
      Directory(p.join(snesDir.path, 'covers')).createSync();
      Directory(p.join(snesDir.path, 'screenshots')).createSync();
      final nesDir = writeGamelist(romB, 'nes', marioGamelist);

      final result = await EsdeImportService.importInFolder([
        romA.path,
        romB.path,
      ]);

      expect(result.mode, GamelistSourceMode.inFolder);
      expect(result.systemsFound, 2);
      expect(result.systemsMatched, 2);
      expect(result.systemsUnmatched, 0);
      expect(result.systemsSkipped, 0);
      expect(result.gamesImported, 2);
      expect(result.foldersSkippedSaf, 0);
      expect(result.noInFolderGamelistsFound, isFalse);
      // The ES-DE outcome flag keeps its default: in-folder mode never
      // looked for a gamelists/ dir.
      expect(result.gamelistsDirFound, isTrue);

      final snes = await mediaLocation('snes');
      expect(snes['esde_media_root'], snesDir.path);
      expect(snes['esde_media_dir'], isNull);
      final nes = await mediaLocation('nes');
      expect(nes['esde_media_root'], nesDir.path);

      final rows = await db.rawQuery(
        'SELECT app_system_id, filename, esde_imported FROM user_screenscraper_metadata ORDER BY filename',
      );
      expect(rows.map((r) => r['filename']), ['mario.nes', 'sonic.smc']);
      expect(rows.every((r) => r['esde_imported'] == 1), isTrue);
    });

    test('resolves an alias subfolder to the canonical system', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('scd', 'Sega CD', 'scd', 20)",
      );
      await db.execute(
        "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('scd', 'segacd')",
      );
      await seedRom('sonic.chd', 'scd');
      final romA = romFolder();
      final segacdDir = writeGamelist(
        romA,
        'segacd',
        '<gameList><game><path>./sonic.chd</path><name>Sonic CD</name></game></gameList>',
      );

      final result = await EsdeImportService.importInFolder([romA.path]);

      expect(result.systemsMatched, 1);
      expect(result.gamesImported, 1);
      final rows = await db.rawQuery(
        'SELECT app_system_id, real_name FROM user_screenscraper_metadata',
      );
      expect(rows.single['app_system_id'], 'scd');
      expect(rows.single['real_name'], 'Sonic CD');
      expect((await mediaLocation('scd'))['esde_media_root'], segacdDir.path);
    });

    test(
      'counts a subfolder that resolves to no system as unmatched',
      () async {
        final romA = romFolder();
        writeGamelist(romA, 'foo', sonicGamelist);

        final result = await EsdeImportService.importInFolder([romA.path]);

        expect(result.systemsFound, 1);
        expect(result.systemsUnmatched, 1);
        expect(result.systemsMatched, 0);
        expect(result.systemsSkipped, 0);
        expect(result.noInFolderGamelistsFound, isFalse);
        final rows = await db.rawQuery('SELECT * FROM user_system_settings');
        expect(rows, isEmpty);
      },
    );

    test(
      'reports no in-folder gamelists distinctly from the ES-DE outcome',
      () async {
        final romA = romFolder();
        Directory(p.join(romA.path, 'snes')).createSync();
        File(p.join(romA.path, 'snes', 'sonic.smc')).writeAsStringSync('rom');

        final inFolder = await EsdeImportService.importInFolder([romA.path]);
        expect(inFolder.mode, GamelistSourceMode.inFolder);
        expect(inFolder.noInFolderGamelistsFound, isTrue);
        expect(inFolder.gamelistsDirFound, isTrue);
        expect(inFolder.systemsFound, 0);

        // The same folder through the ES-DE entry point is "not an ES-DE
        // folder" — a different flag, so the UI can word the two apart.
        final esde = await EsdeImportService.import(romA.path);
        expect(esde.mode, GamelistSourceMode.esdeRoot);
        expect(esde.gamelistsDirFound, isFalse);
        expect(esde.noInFolderGamelistsFound, isFalse);
      },
    );

    test(
      'links a media-only system when a mapped category folder holds a file',
      () async {
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('gb', 'Game Boy', 'gb', 9)",
        );
        await seedRom('sonic.smc', 'snes');
        final romA = romFolder();
        writeGamelist(romA, 'snes', sonicGamelist);
        // nes: art, no gamelist → linked.
        final nesCovers = Directory(p.join(romA.path, 'nes', 'covers'))
          ..createSync(recursive: true);
        File(p.join(nesCovers.path, 'mario.png')).writeAsStringSync('png');
        // gb: only an unmapped folder → not media evidence.
        final gbManuals = Directory(p.join(romA.path, 'gb', 'manuals'))
          ..createSync(recursive: true);
        File(p.join(gbManuals.path, 'x.pdf')).writeAsStringSync('pdf');
        // A folder that resolves to no system is ignored even with art.
        final fooCovers = Directory(p.join(romA.path, 'foo', 'covers'))
          ..createSync(recursive: true);
        File(p.join(fooCovers.path, 'y.png')).writeAsStringSync('png');

        final result = await EsdeImportService.importInFolder([romA.path]);

        expect(result.systemsMatched, 1);
        expect(result.mediaOnlyLinked, 1);
        expect(
          (await mediaLocation('nes'))['esde_media_root'],
          p.join(romA.path, 'nes'),
        );
        expect(await mediaLocation('gb'), isEmpty);
        final rows = await db.rawQuery(
          'SELECT app_system_id FROM user_system_settings ORDER BY app_system_id',
        );
        expect(rows.map((r) => r['app_system_id']), ['nes', 'snes']);
      },
    );

    test('does not link an empty media category folder', () async {
      final romA = romFolder();
      Directory(p.join(romA.path, 'nes', 'covers')).createSync(recursive: true);

      final result = await EsdeImportService.importInFolder([romA.path]);

      expect(result.mediaOnlyLinked, 0);
      expect(await mediaLocation('nes'), isEmpty);
    });

    test('keeps an existing description and fills empty columns', () async {
      await seedRom('sonic.smc', 'snes');
      await db.execute(
        "INSERT INTO user_screenscraper_metadata (app_system_id, filename, real_name, description_en, is_fully_scraped, esde_imported) VALUES ('snes', 'sonic.smc', 'Sonic', 'NeoStation text', 0, 0)",
      );
      final romA = romFolder();
      writeGamelist(
        romA,
        'snes',
        '<gameList><game>'
            '<path>./sonic.smc</path>'
            '<name>Sonic the Hedgehog</name>'
            '<desc>Gamelist text</desc>'
            '<developer>Sonic Team</developer>'
            '</game></gameList>',
      );

      final result = await EsdeImportService.importInFolder([romA.path]);

      expect(result.gamesImported, 1);
      final row = (await db.rawQuery(
        'SELECT real_name, description_en, developer FROM user_screenscraper_metadata',
      )).single;
      expect(row['real_name'], 'Sonic');
      expect(row['description_en'], 'NeoStation text');
      expect(row['developer'], 'Sonic Team');
    });

    test('reset clears in-folder rows and media roots', () async {
      await seedRom('sonic.smc', 'snes');
      final romA = romFolder();
      writeGamelist(romA, 'snes', sonicGamelist);
      final nesCovers = Directory(p.join(romA.path, 'nes', 'covers'))
        ..createSync(recursive: true);
      File(p.join(nesCovers.path, 'mario.png')).writeAsStringSync('png');
      await EsdeImportService.importInFolder([romA.path]);
      expect((await mediaLocation('snes'))['esde_media_root'], isNotNull);
      expect((await mediaLocation('nes'))['esde_media_root'], isNotNull);

      final filesBefore =
          romA
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path)
              .toList()
            ..sort();

      final outcome = await EsdeImportService.resetDetailed();

      expect(outcome.metadataRowsDeleted, 1);
      expect(outcome.mediaRootsCleared, 2);
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
      // Both roots point at real platform folders, outside the mirror
      // prefix: the column is cleared but nothing on disk is touched.
      expect(outcome.mirrorsRemoved, 0);
      final filesAfter =
          romA
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path)
              .toList()
            ..sort();
      expect(filesAfter, filesBefore);
      expect(File(p.join(nesCovers.path, 'mario.png')).existsSync(), isTrue);
      final roots = await db.rawQuery(
        'SELECT app_system_id FROM user_system_settings WHERE esde_media_root IS NOT NULL',
      );
      expect(roots, isEmpty);
      final meta = await db.rawQuery(
        'SELECT * FROM user_screenscraper_metadata',
      );
      expect(meta, isEmpty);
      expect(await EsdeImportService.reset(), 0);
    });

    test(
      'skips and counts an unresolvable SAF folder, scans a resolvable one',
      () async {
        await seedRom('sonic.smc', 'snes');
        await seedRom('mario.nes', 'nes');
        final romA = romFolder();
        final romB = romFolder();
        writeGamelist(romA, 'snes', sonicGamelist);
        writeGamelist(romB, 'nes', marioGamelist);

        // Off-device there is no SAF; the override stands in for the resolver
        // so both outcomes are exercised: one tree resolves, one does not.
        const resolvable =
            'content://com.android.externalstorage.documents/tree/primary%3Aroms';
        const unresolvable =
            'content://com.android.externalstorage.documents/tree/1234-5678%3Aroms';
        EsdeImportService.safRomFolderResolverOverride = (uri) async =>
            uri == resolvable ? romB.path : null;

        final result = await EsdeImportService.importInFolder([
          romA.path,
          unresolvable,
          resolvable,
        ]);

        expect(result.foldersSkippedSaf, 1);
        expect(result.systemsMatched, 2);
        expect(result.gamesImported, 2);
        expect(
          (await mediaLocation('nes'))['esde_media_root'],
          p.join(romB.path, 'nes'),
        );
      },
    );

    test(
      'isolates a malformed gamelist as skipped and imports the rest',
      () async {
        await seedRom('sonic.smc', 'snes');
        await seedRom('mario.nes', 'nes');
        final romA = romFolder();
        writeGamelist(
          romA,
          'snes',
          '<gameList><game><path>./sonic.smc</path></gameList>',
        );
        writeGamelist(romA, 'nes', marioGamelist);

        final result = await EsdeImportService.importInFolder([romA.path]);

        expect(result.systemsFound, 2);
        expect(result.systemsSkipped, 1);
        expect(result.systemsMatched, 1);
        expect(result.gamesImported, 1);
        // A skipped system gets no media root: there is nothing to back it.
        expect(await mediaLocation('snes'), isEmpty);
        expect((await mediaLocation('nes'))['esde_media_root'], isNotNull);
      },
    );
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "SAF Discovery"
  group('EsdeImportService in-folder mode over SAF', () {
    final dbHelper = DatabaseTestHelper();
    late dynamic db;
    late RecordingSaf saf;
    late Directory userData;
    late String mirrorRoot;

    setUp(() async {
      db = await dbHelper.setUp();
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('snes', 'SNES', 'snes', 4)",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('nes', 'NES', 'nes', 3)",
      );
      userData = Directory.systemTemp.createTempSync('esde_saf_userdata_');
      mirrorRoot = p.join(userData.path, 'imported_media');
      saf = RecordingSaf()..install(mirrorRoot: mirrorRoot);
    });

    tearDown(() async {
      RecordingSaf.uninstall();
      await dbHelper.tearDown();
      userData.deleteSync(recursive: true);
    });

    /// Relative paths of every file under the mirror root, sorted.
    List<String> mirrored() {
      final dir = Directory(mirrorRoot);
      if (!dir.existsSync()) return const [];
      return dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => p.relative(f.path, from: mirrorRoot))
          .toList()
        ..sort();
    }

    Future<void> seedRom(String filename, String systemId) => db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('$filename', 'content://roms/$systemId/$filename', '$systemId')",
    );

    Future<Map<String, Object?>> mediaLocation(String systemId) async {
      final rows = await db.rawQuery(
        "SELECT esde_media_dir, esde_media_root FROM user_system_settings WHERE app_system_id = '$systemId'",
      );
      return rows.isEmpty ? const {} : rows.first;
    }

    // The same fixture bytes the real-path group parses, so the SAF read is
    // proven to land in the same parser with the same outcome.
    const sonicGamelist =
        '<gameList><game><path>./sonic.smc</path><name>Sonic</name></game></gameList>';
    const marioGamelist =
        '<gameList><game><path>./mario.nes</path><name>Mario</name></game></gameList>';

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Gamelist Read Over SAF"
    test(
      'imports a SAF folder from gamelist bytes with one listing per subfolder',
      () async {
        await seedRom('sonic.smc', 'snes');
        final snesUri = saf.dir('snes');
        final gamelistUri = saf.file('snes/gamelist.xml', sonicGamelist);
        saf.file('snes/sonic.smc', 'rom');
        final coversUri = saf.dir('snes/covers');
        saf.file('snes/covers/sonic.png', 'png');
        final shotsUri = saf.dir('snes/screenshots');
        saf.file('snes/screenshots/sonic.png', 'png');
        // An unmapped folder is not media evidence and is never listed.
        saf.dir('snes/manuals');

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.mode, GamelistSourceMode.inFolder);
        expect(result.foldersSkippedSaf, 0);
        expect(result.systemsFound, 1);
        expect(result.systemsMatched, 1);
        expect(result.systemsImportedViaSaf, 1);
        expect(result.systemsSkipped, 0);
        expect(result.gamesImported, 1);
        expect(result.noInFolderGamelistsFound, isFalse);
        expect(result.folderOutcomes.map((o) => o.kind), [
          EsdeImportPathKind.saf,
        ]);
        expect(result.folderOutcomes.single.folder, RecordingSaf.treeUri);

        // Exactly one listing of the root, one of the system folder, and
        // one per mapped category for the mirror; no per-document probe.
        expect(saf.listedUris, [
          RecordingSaf.treeUri,
          snesUri,
          coversUri,
          shotsUri,
        ]);
        expect(saf.readUris, [gamelistUri]);

        // Metadata lands exactly as the real-path import writes it.
        final rows = await db.rawQuery(
          'SELECT app_system_id, filename, real_name, esde_imported FROM user_screenscraper_metadata',
        );
        expect(rows.single['app_system_id'], 'snes');
        expect(rows.single['filename'], 'sonic.smc');
        expect(rows.single['real_name'], 'Sonic');
        expect(rows.single['esde_imported'], 1);

        // The category folders were mirrored into user data and the mirror
        // directory, not the content:// folder, is the system's media root.
        // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
        expect(mirrored(), [
          p.join('snes', 'covers', 'sonic.png'),
          p.join('snes', 'screenshots', 'sonic.png'),
        ]);
        expect(
          (await mediaLocation('snes'))['esde_media_root'],
          p.join(mirrorRoot, 'snes'),
        );
        expect(result.safSystemsMirrored, 1);
        expect(result.safFilesCopied, 2);
        expect(result.safFilesSkippedUnchanged, 0);
        expect(result.safFilesFailed, 0);
        expect(result.safBytesCopied, 6);
        expect(result.safBudgetRefused, isFalse);
        expect(result.cancelled, isFalse);
        expect(result.refusedAlreadyRunning, isFalse);
      },
    );

    test('a second run skips the mirrored files by size', () async {
      await seedRom('sonic.smc', 'snes');
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.dir('snes/covers');
      saf.file('snes/covers/sonic.png', 'png');
      await EsdeImportService.importInFolder([RecordingSaf.treeUri]);
      saf.calls.clear();

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.safFilesCopied, 0);
      expect(result.safFilesSkippedUnchanged, 1);
      expect(result.safBytesCopied, 0);
      expect(result.safSystemsMirrored, 1);
      expect(saf.rangeCalls, isEmpty);
      expect(
        (await mediaLocation('snes'))['esde_media_root'],
        p.join(mirrorRoot, 'snes'),
      );
    });

    test('records no media root when the mirror ends up empty', () async {
      await seedRom('sonic.smc', 'snes');
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      final coversUri = saf.dir('snes/covers'); // present but empty

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.gamesImported, 1);
      expect(result.safSystemsMirrored, 0);
      expect(result.safFilesCopied, 0);
      expect(saf.listedUris, contains(coversUri));
      expect(mirrored(), isEmpty);
      expect(await mediaLocation('snes'), isEmpty);
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Mirror Media Root"
    test('a SAF source points its media dir at the mirror directory', () async {
      final snesUri = saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.dir('snes/covers');

      final withMirror = await EsdeImportService.discoverSafSourcesForTest(
        RecordingSaf.treeUri,
        mirrorRoot: mirrorRoot,
      );
      final withoutMirror = await EsdeImportService.discoverSafSourcesForTest(
        RecordingSaf.treeUri,
      );

      expect(withMirror.single.safMirrorDir, p.join(mirrorRoot, 'snes'));
      expect(withMirror.single.systemMediaDir, p.join(mirrorRoot, 'snes'));
      expect(withMirror.single.mediaRoot, snesUri);
      expect(withoutMirror.single.safMirrorDir, isNull);
      expect(withoutMirror.single.systemMediaDir, snesUri);
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Storage Budget Guard"
    test('still imports metadata when the mirror budget is refused', () async {
      await seedRom('sonic.smc', 'snes');
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.dir('snes/covers');
      saf.file('snes/covers/sonic.png', 'png');
      saf.freeSpace = 1;

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.gamesImported, 1);
      expect(result.systemsImportedViaSaf, 1);
      expect(result.safBudgetRefused, isTrue);
      expect(result.safBudgetRequiredBytes, 3);
      expect(result.safBudgetAvailableBytes, 1);
      expect(result.safFilesCopied, 0);
      expect(result.safSystemsMirrored, 0);
      expect(saf.rangeCalls, isEmpty);
      expect(mirrored(), isEmpty);
      expect(await mediaLocation('snes'), isEmpty);
      final rows = await db.rawQuery(
        'SELECT filename FROM user_screenscraper_metadata',
      );
      expect(rows.single['filename'], 'sonic.smc');
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
    test('stops the mirror between files and reports cancellation', () async {
      await seedRom('sonic.smc', 'snes');
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.dir('snes/covers');
      saf.file('snes/covers/a.png', 'aaa');
      saf.file('snes/covers/b.png', 'bbb');
      saf.file('snes/covers/c.png', 'ccc');
      final progress = <(String, int, int)>[];

      final result = await EsdeImportService.importInFolder(
        [RecordingSaf.treeUri],
        shouldStop: () => mirrored().isNotEmpty,
        onMirrorProgress: (system, copied, total) =>
            progress.add((system, copied, total)),
      );

      expect(result.cancelled, isTrue);
      expect(result.gamesImported, 1);
      expect(result.safFilesCopied, 1);
      expect(mirrored(), [p.join('snes', 'covers', 'a.png')]);
      // The copied file is kept and is enough to record the media root.
      expect(result.safSystemsMirrored, 1);
      expect(
        (await mediaLocation('snes'))['esde_media_root'],
        p.join(mirrorRoot, 'snes'),
      );
      expect(progress, [('snes', 0, 3), ('snes', 1, 3)]);
    });

    test('refuses a second start while an import is running', () async {
      await seedRom('sonic.smc', 'snes');
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.gate = Completer<void>();

      final first = EsdeImportService.importInFolder([RecordingSaf.treeUri]);
      expect(EsdeImportService.isRunning, isTrue);

      final second = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);
      expect(second.refusedAlreadyRunning, isTrue);
      expect(second.mode, GamelistSourceMode.inFolder);
      expect(second.systemsFound, 0);
      final esde = await EsdeImportService.import('/nowhere');
      expect(esde.refusedAlreadyRunning, isTrue);
      await expectLater(
        EsdeImportService.reset(),
        throwsA(isA<EsdeImportBusyException>()),
      );

      saf.gate!.complete();
      final result = await first;
      expect(result.refusedAlreadyRunning, isFalse);
      expect(result.gamesImported, 1);
      expect(EsdeImportService.isRunning, isFalse);

      // The guard is released: the next run proceeds.
      final again = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);
      expect(again.refusedAlreadyRunning, isFalse);
      expect(again.systemsMatched, 1);
    });

    test(
      'discovers the mapped category folders from the one subfolder listing',
      () async {
        final snesUri = saf.dir('snes');
        final gamelistUri = saf.file('snes/gamelist.xml', sonicGamelist);
        final coversUri = saf.dir('snes/covers');
        final shotsUri = saf.dir('snes/screenshots');
        saf.dir('snes/manuals');
        saf.dir('snes/Hacks');

        final sources = await EsdeImportService.discoverSafSourcesForTest(
          RecordingSaf.treeUri,
        );

        final source = sources.single;
        expect(source.mode, GamelistSourceMode.saf);
        expect(source.systemFolderName, 'snes');
        expect(source.gamelistUri, gamelistUri);
        expect(source.gamelistFile, isNull);
        expect(source.mediaRoot, snesUri);
        expect(source.safCategoryDirs, {
          'covers': coversUri,
          'screenshots': shotsUri,
        });
        expect(saf.listedUris, [RecordingSaf.treeUri, snesUri]);
      },
    );

    test('resolves an alias SAF subfolder to the canonical system', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('scd', 'Sega CD', 'scd', 20)",
      );
      await db.execute(
        "INSERT INTO app_system_folders (system_id, folder_name) VALUES ('scd', 'segacd')",
      );
      await seedRom('sonic.chd', 'scd');
      saf.dir('segacd');
      saf.file(
        'segacd/gamelist.xml',
        '<gameList><game><path>./sonic.chd</path><name>Sonic CD</name></game></gameList>',
      );

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.systemsMatched, 1);
      expect(result.systemsImportedViaSaf, 1);
      expect(result.gamesImported, 1);
      final rows = await db.rawQuery(
        'SELECT app_system_id, real_name FROM user_screenscraper_metadata',
      );
      expect(rows.single['app_system_id'], 'scd');
      expect(rows.single['real_name'], 'Sonic CD');
    });

    test('reports an empty SAF tree as no gamelists, not as skipped', () async {
      saf.dir('snes');
      saf.file('snes/sonic.smc', 'rom');
      saf.dir('nes');

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.foldersSkippedSaf, 0);
      expect(result.noInFolderGamelistsFound, isTrue);
      expect(result.systemsFound, 0);
      expect(result.safMediaOnlyPending, 0);
      expect(result.folderOutcomes.single.kind, EsdeImportPathKind.saf);
      expect(saf.listedUris, [
        RecordingSaf.treeUri,
        RecordingSaf.uriOf('nes'),
        RecordingSaf.uriOf('snes'),
      ]);
      expect(saf.readUris, isEmpty);
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
    test(
      'isolates an unreadable SAF gamelist as skipped and imports the rest',
      () async {
        await seedRom('sonic.smc', 'snes');
        await seedRom('mario.nes', 'nes');
        saf.dir('snes');
        final snesGamelist = saf.file('snes/gamelist.xml', sonicGamelist);
        saf.documents[snesGamelist] = null; // provider returned nothing
        saf.dir('nes');
        saf.file('nes/gamelist.xml', marioGamelist);

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.systemsFound, 2);
        expect(result.systemsSkipped, 1);
        expect(result.systemsMatched, 1);
        expect(result.systemsImportedViaSaf, 1);
        expect(result.gamesImported, 1);
        expect(result.foldersSkippedSaf, 0);
        final rows = await db.rawQuery(
          'SELECT filename FROM user_screenscraper_metadata',
        );
        expect(rows.single['filename'], 'mario.nes');
      },
    );

    test('isolates a SAF read that throws the same way', () async {
      await seedRom('sonic.smc', 'snes');
      await seedRom('mario.nes', 'nes');
      saf.dir('snes');
      saf.failRead.add(saf.file('snes/gamelist.xml', sonicGamelist));
      saf.dir('nes');
      saf.file('nes/gamelist.xml', marioGamelist);

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.systemsSkipped, 1);
      expect(result.systemsMatched, 1);
      expect(result.gamesImported, 1);
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Real-Path Precedence"
    test(
      'imports a real-path folder per SPEC-0002 and a SAF folder over SAF',
      () async {
        await seedRom('sonic.smc', 'snes');
        await seedRom('mario.nes', 'nes');
        final realFolder = Directory.systemTemp.createTempSync('esde_mixed_');
        addTearDown(() => realFolder.deleteSync(recursive: true));
        final nesDir = Directory(p.join(realFolder.path, 'nes'))
          ..createSync(recursive: true);
        File(
          p.join(nesDir.path, 'gamelist.xml'),
        ).writeAsStringSync(marioGamelist);
        saf.dir('snes');
        saf.file('snes/gamelist.xml', sonicGamelist);

        final result = await EsdeImportService.importInFolder([
          realFolder.path,
          RecordingSaf.treeUri,
        ]);

        expect(result.systemsMatched, 2);
        expect(result.systemsImportedViaSaf, 1);
        expect(result.gamesImported, 2);
        expect(result.foldersSkippedSaf, 0);
        expect(result.folderOutcomes.map((o) => (o.folder, o.kind)).toList(), [
          (realFolder.path, EsdeImportPathKind.real),
          (RecordingSaf.treeUri, EsdeImportPathKind.saf),
        ]);
        // The real-path system records its platform folder; the SAF system
        // records nothing until the mirror exists.
        expect((await mediaLocation('nes'))['esde_media_root'], nesDir.path);
        expect(await mediaLocation('snes'), isEmpty);
        // The real-path folder never went near SAF.
        expect(saf.listedUris, [
          RecordingSaf.treeUri,
          RecordingSaf.uriOf('snes'),
        ]);
      },
    );

    test(
      'counts a SAF folder whose root cannot be listed as skipped',
      () async {
        await seedRom('sonic.smc', 'snes');
        saf.dir('snes');
        saf.file('snes/gamelist.xml', sonicGamelist);
        saf.failListing.add(RecordingSaf.treeUri);

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.foldersSkippedSaf, 1);
        expect(result.systemsFound, 0);
        expect(result.noInFolderGamelistsFound, isTrue);
        expect(
          result.folderOutcomes.single.kind,
          EsdeImportPathKind.skippedSaf,
        );
        expect(saf.readUris, isEmpty);
      },
    );

    test('counts a SAF folder with no persisted grant as skipped', () async {
      saf.dir('snes');
      saf.file('snes/gamelist.xml', sonicGamelist);
      saf.noPermission.add(RecordingSaf.treeUri);

      final result = await EsdeImportService.importInFolder([
        RecordingSaf.treeUri,
      ]);

      expect(result.foldersSkippedSaf, 1);
      expect(result.folderOutcomes.single.kind, EsdeImportPathKind.skippedSaf);
      // Nothing was listed: the grant check comes first.
      expect(saf.listedUris, isEmpty);
    });

    test(
      'leaves a lost-grant subfolder out and imports its siblings',
      () async {
        await seedRom('mario.nes', 'nes');
        saf.dir('snes');
        saf.file('snes/gamelist.xml', sonicGamelist);
        saf.failListing.add(RecordingSaf.uriOf('snes'));
        saf.dir('nes');
        saf.file('nes/gamelist.xml', marioGamelist);

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.foldersSkippedSaf, 0);
        expect(result.systemsFound, 1);
        expect(result.systemsMatched, 1);
        expect(result.gamesImported, 1);
        // The unreadable subfolder is counted, not just logged.
        expect(result.safSystemsListingFailed, 1);
      },
    );

    test(
      'mirrors a media-only SAF subfolder and links it to its system',
      () async {
        await seedRom('sonic.smc', 'snes');
        saf.dir('snes');
        saf.file('snes/gamelist.xml', sonicGamelist);
        // nes: mapped art folder with a file, no gamelist → mirrored + linked.
        saf.dir('nes');
        final nesCoversUri = saf.dir('nes/covers');
        saf.file('nes/covers/mario.png', 'png');
        // gb: unmapped folder only → not media evidence.
        await db.execute(
          "INSERT INTO app_systems (id, real_name, folder_name, screenscraper_id) VALUES ('gb', 'Game Boy', 'gb', 9)",
        );
        saf.dir('gb');
        saf.dir('gb/manuals');
        // foo: resolves to no system → ignored even with art.
        saf.dir('foo');
        saf.dir('foo/covers');

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.systemsMatched, 1);
        expect(result.mediaOnlyLinked, 1);
        expect(result.safMediaOnlyPending, 0);
        expect(result.safSystemsMirrored, 1);
        expect(result.safFilesCopied, 1);
        expect(mirrored(), [p.join('nes', 'covers', 'mario.png')]);
        expect(
          (await mediaLocation('nes'))['esde_media_root'],
          p.join(mirrorRoot, 'nes'),
        );
        // snes had no category folders, so it gets no root.
        final rows = await db.rawQuery(
          'SELECT app_system_id FROM user_system_settings',
        );
        expect(rows.map((r) => r['app_system_id']), ['nes']);
        // One listing per system subfolder, then the mirror's one listing of
        // the linked system's category folder; foo resolves to no system and
        // its art folder is never listed.
        expect(saf.listedUris, [
          RecordingSaf.treeUri,
          RecordingSaf.uriOf('foo'),
          RecordingSaf.uriOf('gb'),
          RecordingSaf.uriOf('nes'),
          RecordingSaf.uriOf('snes'),
          nesCoversUri,
        ]);
      },
    );

    test(
      'does not link a media-only SAF subfolder whose folders are empty',
      () async {
        saf.dir('nes');
        final coversUri = saf.dir('nes/covers');

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.mediaOnlyLinked, 0);
        expect(result.safSystemsMirrored, 0);
        expect(saf.listedUris, contains(coversUri));
        expect(await mediaLocation('nes'), isEmpty);
      },
    );

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Reset and Re-import"
    group('reset', () {
      Future<void> seedSnesMirror() async {
        await seedRom('sonic.smc', 'snes');
        saf.dir('snes');
        saf.file('snes/gamelist.xml', sonicGamelist);
        saf.dir('snes/covers');
        saf.file('snes/covers/sonic.png', 'png');
      }

      test('removes the mirror directory and clears the column', () async {
        await seedSnesMirror();
        final first = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);
        expect(first.safFilesCopied, 1);
        expect(mirrored(), [p.join('snes', 'covers', 'sonic.png')]);
        final safListingsBefore = Map.of(saf.listings);
        final safDocsBefore = Map.of(saf.documents);
        saf.calls.clear();

        final outcome = await EsdeImportService.resetDetailed();

        expect(outcome.mirrorsRemoved, 1);
        expect(outcome.mediaRootsCleared, 1);
        expect(outcome.metadataRowsDeleted, 1);
        expect(Directory(p.join(mirrorRoot, 'snes')).existsSync(), isFalse);
        expect(mirrored(), isEmpty);
        expect((await mediaLocation('snes'))['esde_media_root'], isNull);
        // The SAF tree was neither read nor written: no call of any kind.
        expect(saf.calls, isEmpty);
        expect(saf.listings, safListingsBefore);
        expect(saf.documents, safDocsBefore);
      });

      test('deletes only roots under the mirror prefix', () async {
        await seedSnesMirror();
        await seedRom('mario.nes', 'nes');
        await EsdeImportService.importInFolder([RecordingSaf.treeUri]);
        // A sibling of the mirror root that shares its name as a prefix,
        // and a real platform folder recorded per SPEC-0002: neither may go.
        final lookalike = Directory('${mirrorRoot}2')..createSync();
        File(p.join(lookalike.path, 'keep.png')).writeAsStringSync('x');
        final realRoot = Directory(p.join(userData.path, 'platform', 'nes'))
          ..createSync(recursive: true);
        File(p.join(realRoot.path, 'mario.png')).writeAsStringSync('x');
        await ScraperRepository.recordEsdeMediaRoot('nes', realRoot.path);
        // A stray directory under the mirror root that no system points at
        // is left alone too: deletion is by recorded root, not by sweep.
        final stray = Directory(p.join(mirrorRoot, 'gb'))..createSync();
        File(p.join(stray.path, 'stray.png')).writeAsStringSync('x');

        final outcome = await EsdeImportService.resetDetailed();

        expect(outcome.mirrorsRemoved, 1);
        expect(Directory(p.join(mirrorRoot, 'snes')).existsSync(), isFalse);
        expect(File(p.join(lookalike.path, 'keep.png')).existsSync(), isTrue);
        expect(File(p.join(realRoot.path, 'mario.png')).existsSync(), isTrue);
        expect(File(p.join(stray.path, 'stray.png')).existsSync(), isTrue);
        expect(Directory(mirrorRoot).existsSync(), isTrue);
        expect((await mediaLocation('nes'))['esde_media_root'], isNull);
        expect((await mediaLocation('snes'))['esde_media_root'], isNull);
      });

      test('never deletes the mirror root itself', () async {
        await seedSnesMirror();
        await EsdeImportService.importInFolder([RecordingSaf.treeUri]);
        // A root recorded as the mirror root exactly, or as a content://
        // URI, is a column value to clear, not a directory to remove.
        await ScraperRepository.recordEsdeMediaRoot('snes', mirrorRoot);
        await ScraperRepository.recordEsdeMediaRoot(
          'nes',
          RecordingSaf.uriOf('nes'),
        );
        saf.calls.clear();

        final outcome = await EsdeImportService.resetDetailed();

        expect(outcome.mirrorsRemoved, 0);
        expect(Directory(mirrorRoot).existsSync(), isTrue);
        expect(mirrored(), [p.join('snes', 'covers', 'sonic.png')]);
        expect(saf.calls, isEmpty);
        expect((await mediaLocation('snes'))['esde_media_root'], isNull);
        expect((await mediaLocation('nes'))['esde_media_root'], isNull);
      });

      test('a re-import after reset rebuilds the mirror', () async {
        await seedSnesMirror();
        await EsdeImportService.importInFolder([RecordingSaf.treeUri]);
        await EsdeImportService.reset();
        expect(mirrored(), isEmpty);
        saf.calls.clear();

        final again = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        // Copied afresh, not size-skipped: the mirror really was gone.
        expect(again.safFilesCopied, 1);
        expect(again.safFilesSkippedUnchanged, 0);
        expect(again.safSystemsMirrored, 1);
        expect(again.gamesImported, 1);
        expect(saf.rangeCalls, isNotEmpty);
        expect(mirrored(), [p.join('snes', 'covers', 'sonic.png')]);
        expect(
          (await mediaLocation('snes'))['esde_media_root'],
          p.join(mirrorRoot, 'snes'),
        );
      });

      test('reset with nothing recorded removes nothing', () async {
        final outcome = await EsdeImportService.resetDetailed();
        expect(outcome, isA<EsdeResetResult>());
        expect(outcome.mirrorsRemoved, 0);
        expect(outcome.mediaRootsCleared, 0);
        expect(outcome.metadataRowsDeleted, 0);
        expect(saf.calls, isEmpty);
      });
    });

    test(
      'off-device with no SAF fake a content:// folder is skipped',
      () async {
        // The default wrappers refuse SAF off Android rather than reading an
        // empty listing as an empty tree, so the SPEC-0002 skip outcome holds.
        RecordingSaf.uninstall();
        EsdeImportService.safRomFolderResolverOverride = (_) async => null;
        EsdeImportService.mirrorRootOverride = mirrorRoot;

        final result = await EsdeImportService.importInFolder([
          RecordingSaf.treeUri,
        ]);

        expect(result.foldersSkippedSaf, 1);
        expect(
          result.folderOutcomes.single.kind,
          EsdeImportPathKind.skippedSaf,
        );
      },
    );
  });
}
