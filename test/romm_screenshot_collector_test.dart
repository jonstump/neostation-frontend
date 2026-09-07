import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/services/romm/screenshot_collector.dart';

/// [ScreenshotCollector] against a real directory: the stem filter, the
/// session window, the ledger exclusion, the per-content subdirectory, and
/// the missing-directory case.
///
/// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
/// "Collector"
void main() {
  late Directory shotsDir;

  /// Session start the tests measure everything from.
  final sessionStart = DateTime(2026, 9, 6, 10, 0, 0);

  setUp(() {
    shotsDir = Directory.systemTemp.createTempSync('romm_shots_test');
  });

  tearDown(() {
    if (shotsDir.existsSync()) shotsDir.deleteSync(recursive: true);
  });

  GameModel game({
    String romname = 'Game.zip',
    String? romPath,
    bool withPath = true,
  }) => GameModel(
    romname: romname,
    realname: romname,
    name: romname,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: withPath
        ? (romPath ?? '${shotsDir.path}${Platform.pathSeparator}$romname')
        : null,
  );

  /// Writes [name] with [bytes] bytes, stamped [offset] from [sessionStart].
  File write(
    String name, {
    required Duration offset,
    int bytes = 16,
    Directory? into,
  }) {
    final dir = into ?? shotsDir;
    dir.createSync(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(List<int>.filled(bytes, 0));
    file.setLastModifiedSync(sessionStart.add(offset));
    return file;
  }

  ScreenshotCollector collector({
    String? directory,
    bool sortByContent = false,
    bool inContentDir = false,
    Map<String, int?> ledger = const {},
    String? archiveStem,
  }) => ScreenshotCollector(
    loadConfig: () async => RetroArchConfig(
      configPath: '/cfg/retroarch.cfg',
      screenshotDirectory: directory ?? shotsDir.path,
      sortScreenshotsByContent: sortByContent,
      screenshotsInContentDir: inContentDir,
    ),
    loadLedger: (_) async => ledger,
    loadArchiveStem: (_) async => archiveStem,
  );

  group('collect', () {
    test('returns only this session\'s captures for this game', () async {
      write('Game-260906-101500.png', offset: const Duration(minutes: 15));
      write('Game-260906-101800.png', offset: const Duration(minutes: 18));
      write('Game-260905-220000.png', offset: const Duration(hours: -12));
      write('Other-260906-101500.png', offset: const Duration(minutes: 15));

      final found = await collector().collect(game(), sessionStart);

      expect(found.map((s) => s.fileName), [
        'Game-260906-101500.png',
        'Game-260906-101800.png',
      ]);
    });

    test(
      'accepts a capture stamped inside the five-second tolerance',
      () async {
        write('Game-early.png', offset: const Duration(seconds: -4));
        write('Game-late.png', offset: const Duration(seconds: -6));

        final found = await collector().collect(game(), sessionStart);

        expect(found.map((s) => s.fileName), ['Game-early.png']);
      },
    );

    test('keeps only files with an image extension', () async {
      write('Game-shot.png', offset: const Duration(minutes: 1));
      write('Game-shot.jpg', offset: const Duration(minutes: 2));
      write('Game-notes.txt', offset: const Duration(minutes: 3));
      write('Game-save.srm', offset: const Duration(minutes: 4));

      final found = await collector().collect(game(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-shot.png', 'Game-shot.jpg']);
    });

    test('skips a file already in the ledger at the same size', () async {
      write('Game-a.png', offset: const Duration(minutes: 1), bytes: 100);
      write('Game-b.png', offset: const Duration(minutes: 2), bytes: 200);

      final found = await collector(
        ledger: const {'Game-a.png': 100},
      ).collect(game(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-b.png']);
    });

    test('offers a ledger file again when its size changed', () async {
      write('Game-a.png', offset: const Duration(minutes: 1), bytes: 100);

      final found = await collector(
        ledger: const {'Game-a.png': 64},
      ).collect(game(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-a.png']);
    });

    test('never re-offers a 413-skipped file (null recorded size)', () async {
      write('Game-huge.png', offset: const Duration(minutes: 1), bytes: 500);

      final found = await collector(
        ledger: const {'Game-huge.png': null},
      ).collect(game(), sessionStart);

      expect(found, isEmpty);
    });

    test('also looks in the per-content subdirectory when enabled', () async {
      final romsDir = Directory(
        '${shotsDir.path}${Platform.pathSeparator}roms'
        '${Platform.pathSeparator}snes',
      )..createSync(recursive: true);
      final contentShots = Directory(
        '${shotsDir.path}${Platform.pathSeparator}snes',
      );

      write('Game-root.png', offset: const Duration(minutes: 1));
      write(
        'Game-sorted.png',
        offset: const Duration(minutes: 2),
        into: contentShots,
      );

      final found = await collector(sortByContent: true).collect(
        game(romPath: '${romsDir.path}${Platform.pathSeparator}Game.zip'),
        sessionStart,
      );

      expect(found.map((s) => s.fileName), [
        'Game-root.png',
        'Game-sorted.png',
      ]);
    });

    test('ignores the subdirectory when the flag is off', () async {
      final romsDir = Directory(
        '${shotsDir.path}${Platform.pathSeparator}roms'
        '${Platform.pathSeparator}snes',
      )..createSync(recursive: true);
      write(
        'Game-sorted.png',
        offset: const Duration(minutes: 2),
        into: Directory('${shotsDir.path}${Platform.pathSeparator}snes'),
      );

      final found = await collector().collect(
        game(romPath: '${romsDir.path}${Platform.pathSeparator}Game.zip'),
        sessionStart,
      );

      expect(found, isEmpty);
    });

    test(
      'returns empty when the screenshot directory does not exist',
      () async {
        final missing =
            '${shotsDir.path}${Platform.pathSeparator}no-such-directory';

        final found = await collector(
          directory: missing,
        ).collect(game(), sessionStart);

        expect(found, isEmpty);
      },
    );

    test('returns empty when no screenshot directory is configured', () async {
      final noDirectory = ScreenshotCollector(
        loadConfig: () async =>
            const RetroArchConfig(configPath: '/cfg/retroarch.cfg'),
        loadLedger: (_) async => const {},
      );

      expect(await noDirectory.collect(game(), sessionStart), isEmpty);
    });

    test('finds captures named after the ROM inside an archive', () async {
      // The regression: the stem came from the ROM file name only. RetroArch
      // loading `Set.zip` opens the member and names the capture after *it*,
      // so a set whose inner ROM has a different name collected nothing at all
      // and logged a zero count.
      // Governing: ADR-0016, SPEC-0016 REQ "Collector"
      write(
        'Inner Game (USA)-260906-101500.png',
        offset: const Duration(minutes: 15),
      );
      write('Other-260906-101500.png', offset: const Duration(minutes: 15));

      final found = await collector(
        archiveStem: 'Inner Game (USA)',
      ).collect(game(romname: 'Set.zip'), sessionStart);

      expect(found.map((s) => s.fileName), [
        'Inner Game (USA)-260906-101500.png',
      ]);
    });

    test('keeps the archive stem alongside the inner one', () async {
      // An arcade set is its own content, and a core that ignores the inner
      // name stamps the archive's, so the archive stem must not be replaced.
      write('Set-260906-101500.png', offset: const Duration(minutes: 15));
      write('Inner-260906-101800.png', offset: const Duration(minutes: 18));

      final found = await collector(
        archiveStem: 'Inner',
      ).collect(game(romname: 'Set.zip'), sessionStart);

      expect(found.map((s) => s.fileName), [
        'Set-260906-101500.png',
        'Inner-260906-101800.png',
      ]);
    });

    test('reports size and mtime without reading the file', () async {
      write('Game-a.png', offset: const Duration(minutes: 3), bytes: 77);

      final found = await collector().collect(game(), sessionStart);

      expect(found.single.sizeBytes, 77);
      expect(
        found.single.modifiedAt.millisecondsSinceEpoch,
        sessionStart.add(const Duration(minutes: 3)).millisecondsSinceEpoch,
      );
    });
  });

  group('romStemFor', () {
    test('strips the extension from a desktop path', () {
      expect(
        ScreenshotCollector.romStemFor(
          game(romPath: '/roms/snes/Super Game (USA).sfc'),
        ),
        'Super Game (USA)',
      );
    });

    test('decodes an Android SAF content URI', () {
      expect(
        ScreenshotCollector.romStemFor(
          game(
            romname: 'Game.zip',
            romPath:
                'content://com.android.externalstorage.documents/tree/'
                'primary%3Aemu/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip',
          ),
        ),
        'Game',
      );
    });

    test('falls back to romname when the game has no path', () {
      expect(
        ScreenshotCollector.romStemFor(
          game(romname: 'Tetris.gb', withPath: false),
        ),
        'Tetris',
      );
    });

    test('keeps a title whose own name contains a dot', () {
      expect(
        ScreenshotCollector.romStemFor(game(romPath: '/roms/nes/Mr. Do!.nes')),
        'Mr. Do!',
      );
    });
  });

  group('contentSubdirectoryFor', () {
    test('names the ROM\'s parent directory on desktop', () {
      expect(
        ScreenshotCollector.contentSubdirectoryFor(
          game(romPath: '/roms/snes/Game.sfc'),
        ),
        'snes',
      );
    });

    test('decodes the SAF document id before splitting', () {
      expect(
        ScreenshotCollector.contentSubdirectoryFor(
          game(
            romPath:
                'content://com.android.externalstorage.documents/tree/'
                'primary%3Aemu/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip',
          ),
        ),
        'nes',
      );
    });

    test('is null when the game has no path', () {
      expect(
        ScreenshotCollector.contentSubdirectoryFor(game(withPath: false)),
        isNull,
      );
    });
  });

  group('archiveContentStem', () {
    /// A zip whose largest member is [inner], written to [name].
    String writeZip(String name, String inner) {
      final archive = Archive()
        ..addFile(ArchiveFile('readme.txt', 4, List<int>.filled(4, 0x41)))
        ..addFile(ArchiveFile(inner, 4096, List<int>.filled(4096, 0x42)));
      final bytes = ZipEncoder().encode(archive);
      final path = '${shotsDir.path}${Platform.pathSeparator}$name';
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    test('reads the largest member out of the zip directory', () async {
      final zip = writeZip('Set.zip', 'Inner Game (USA).nes');

      expect(
        await ScreenshotCollector.archiveContentStem(zip),
        'Inner Game (USA)',
      );
    });

    test('strips a directory component', () async {
      final zip = writeZip('Nested.zip', 'roms/nes/Inner Game.nes');

      expect(await ScreenshotCollector.archiveContentStem(zip), 'Inner Game');
    });

    test('is null for a ROM that is not an archive', () async {
      expect(
        await ScreenshotCollector.archiveContentStem('/roms/nes/Game.nes'),
        isNull,
      );
    });

    test('is null for an unreadable archive rather than throwing', () async {
      final path = '${shotsDir.path}${Platform.pathSeparator}Broken.zip';
      File(path).writeAsBytesSync(List<int>.filled(64, 0));

      expect(await ScreenshotCollector.archiveContentStem(path), isNull);
    });
  });

  /// `screenshots_in_content_dir` — the mode where RetroArch ignores
  /// `screenshot_directory` outright and writes each capture beside the ROM.
  ///
  /// The directory fallback added earlier could not see this: it filled in a
  /// guessed `screenshots/` folder, the collector walked it, found nothing,
  /// and the upload stayed silently inert on exactly the installs the
  /// fallback was meant to rescue.
  ///
  /// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
  /// "Collector"
  group('screenshots_in_content_dir', () {
    late Directory romsDir;

    setUp(() {
      romsDir = Directory.systemTemp.createTempSync('romm_content_test');
    });

    tearDown(() {
      if (romsDir.existsSync()) romsDir.deleteSync(recursive: true);
    });

    /// A game whose ROM lives in [romsDir] rather than beside the captures.
    GameModel contentGame() =>
        game(romPath: '${romsDir.path}${Platform.pathSeparator}Game.zip');

    test('collects beside the ROM instead of the configured folder', () async {
      write(
        'Game-in-content-dir.png',
        offset: const Duration(minutes: 5),
        into: romsDir,
      );
      // Same stem, same window, in the folder the config names: RetroArch
      // cannot have written it in this mode, so it must not be offered.
      write('Game-in-configured-dir.png', offset: const Duration(minutes: 6));

      final found = await collector(
        inContentDir: true,
      ).collect(contentGame(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-in-content-dir.png']);
    });

    test('overrides the sort-by-content subfolder too', () async {
      // RetroArch builds the subfolder path first and then overwrites it, so
      // enabling both flags must not resurrect the configured tree.
      final sub = Directory(
        '${shotsDir.path}${Platform.pathSeparator}${romsDir.path.split(Platform.pathSeparator).last}',
      )..createSync(recursive: true);
      write('Game-sorted.png', offset: const Duration(minutes: 5), into: sub);
      write(
        'Game-beside-rom.png',
        offset: const Duration(minutes: 5),
        into: romsDir,
      );

      final found = await collector(
        inContentDir: true,
        sortByContent: true,
      ).collect(contentGame(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-beside-rom.png']);
    });

    test(
      'falls back to the configured folder when no content directory resolves',
      () async {
        // A game with no ROM path names no directory. Collecting nothing here
        // would be a regression on where this stood before the flag was read.
        write('Game-in-configured-dir.png', offset: const Duration(minutes: 5));

        final found = await collector(
          inContentDir: true,
        ).collect(game(withPath: false), sessionStart);

        expect(found.map((s) => s.fileName), ['Game-in-configured-dir.png']);
      },
    );

    test(
      'also looks beside the ROM when the guessed folder is not on disk',
      () async {
        // RetroArch falls back to the content directory whenever it ends up with
        // no screenshot directory at all. That case is invisible from here
        // because the fallback fills a *guess* in, so a guess that is not on
        // disk is treated as one.
        write(
          'Game-beside-rom.png',
          offset: const Duration(minutes: 5),
          into: romsDir,
        );

        final found = await collector(
          directory: '${shotsDir.path}${Platform.pathSeparator}nonexistent',
        ).collect(contentGame(), sessionStart);

        expect(found.map((s) => s.fileName), ['Game-beside-rom.png']);
      },
    );

    test('leaves a real configured folder as the only source', () async {
      write('Game-in-configured-dir.png', offset: const Duration(minutes: 5));
      write(
        'Game-beside-rom.png',
        offset: const Duration(minutes: 6),
        into: romsDir,
      );

      final found = await collector().collect(contentGame(), sessionStart);

      expect(found.map((s) => s.fileName), ['Game-in-configured-dir.png']);
    });
  });

  /// Resolving the *absolute* directory the ROM sits in.
  ///
  /// The Android cases are the reason this is not `dirname`: a SAF document
  /// URI decodes to a volume-relative path, which no `Directory` can open.
  ///
  /// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
  /// "Collector"
  group('contentDirectoryFor', () {
    test('is the ROM\'s parent directory on desktop', () {
      expect(
        ScreenshotCollector.contentDirectoryFor(
          game(romPath: '/roms/snes/Game.sfc'),
        ),
        '/roms/snes',
      );
    });

    test('maps a SAF document URI onto primary storage', () {
      // normalizeRomPath would yield `emu/roms/nes/Game.zip` — the volume
      // stripped off — which resolves to nothing.
      expect(
        ScreenshotCollector.contentDirectoryFor(
          game(
            romPath:
                'content://com.android.externalstorage.documents/tree/'
                'primary%3Aemu/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip',
          ),
        ),
        '/storage/emulated/0/emu/roms/nes',
      );
    });

    test('maps a removable-volume document URI onto /storage/<id>', () {
      expect(
        ScreenshotCollector.contentDirectoryFor(
          game(
            romPath:
                'content://com.android.externalstorage.documents/tree/'
                '1A2B-3C4D%3Aroms/document/1A2B-3C4D%3Aroms%2Fpsx%2FGame.chd',
          ),
        ),
        '/storage/1A2B-3C4D/roms/psx',
      );
    });

    test('is null for a provider with no filesystem form', () {
      // Guessing a path for a downloads-style provider would point the
      // collector at a directory that does not exist; the caller then keeps
      // the configured folder.
      expect(
        ScreenshotCollector.contentDirectoryFor(
          game(
            romPath:
                'content://com.android.providers.downloads.documents/'
                'document/msf%3A1234',
          ),
        ),
        isNull,
      );
    });

    test('is null when the game has no path', () {
      expect(
        ScreenshotCollector.contentDirectoryFor(game(withPath: false)),
        isNull,
      );
    });
  });
}
