import 'dart:io';

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
    Map<String, int?> ledger = const {},
  }) => ScreenshotCollector(
    loadConfig: () async => RetroArchConfig(
      configPath: '/cfg/retroarch.cfg',
      screenshotDirectory: directory ?? shotsDir.path,
      sortScreenshotsByContent: sortByContent,
    ),
    loadLedger: (_) async => ledger,
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
}
