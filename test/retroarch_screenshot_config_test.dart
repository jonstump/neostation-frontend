import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/services/retroarch_config_service.dart';

/// `retroarch.cfg` parsing for the two settings the screenshot collector
/// depends on: where RetroArch writes captures, and whether it files them into
/// a per-content subfolder.
///
/// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
/// "Screenshot Directory From RetroArch Config"
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('retroarch_cfg_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<RetroArchConfig> parse(String contents) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}retroarch.cfg');
    file.writeAsStringSync(contents);
    return RetroArchConfigService().parseConfig(file.path);
  }

  group('withScreenshotFallback', () {
    // The regression: `screenshot_directory` ships as "default", and
    // getMergedConfig's no-config path filled in savefile/savestate defaults
    // but no screenshot default. Either way the field stayed null, the
    // collector had nothing to walk, and the whole upload feature was inert
    // with nothing on screen or in the log explaining why.
    // Governing: ADR-0016, SPEC-0016 REQ "Screenshot Directory From RetroArch
    // Config"
    test('leaves a configured directory alone', () {
      final config = RetroArchConfigService.withScreenshotFallback(
        const RetroArchConfig(
          configPath: '/cfg/retroarch.cfg',
          screenshotDirectory: '/shots',
        ),
      );

      expect(config.screenshotDirectory, '/shots');
    });

    test('prefers the screenshots folder beside retroarch.cfg', () {
      final beside = Directory(
        '${tempDir.path}${Platform.pathSeparator}screenshots',
      )..createSync(recursive: true);

      final config = RetroArchConfigService.withScreenshotFallback(
        RetroArchConfig(
          configPath: '${tempDir.path}${Platform.pathSeparator}retroarch.cfg',
        ),
      );

      expect(config.screenshotDirectory, beside.path);
    });

    test('still names a directory when none of the candidates exist', () {
      // A named directory that happens not to exist is what lets the collector
      // log "nothing found in <path>"; a null one is indistinguishable from
      // "nothing was captured".
      final config = RetroArchConfigService.withScreenshotFallback(
        RetroArchConfig(
          configPath: '${tempDir.path}${Platform.pathSeparator}retroarch.cfg',
        ),
      );

      expect(config.screenshotDirectory, isNotNull);
      expect(config.screenshotDirectory, isNotEmpty);
    });

    test('offers candidates for a config that was never found', () {
      final candidates = RetroArchConfigService.defaultScreenshotDirectories();

      expect(candidates, isNotEmpty);
      expect(candidates.toSet(), hasLength(candidates.length));
      for (final candidate in candidates) {
        expect(candidate.toLowerCase(), contains('screenshots'));
      }
    });
  });

  group('parseConfig', () {
    test('exposes the configured screenshot directory', () async {
      final config = await parse('''
savefile_directory = "/storage/emulated/0/RetroArch/saves"
screenshot_directory = "/storage/emulated/0/RetroArch/screenshots"
''');

      expect(
        config.screenshotDirectory,
        '/storage/emulated/0/RetroArch/screenshots',
      );
      expect(config.sortScreenshotsByContent, isFalse);
    });

    test('reads sort_screenshots_by_content_enable as a quoted bool', () async {
      final config = await parse('''
screenshot_directory = "/shots"
sort_screenshots_by_content_enable = "true"
''');

      expect(config.sortScreenshotsByContent, isTrue);
    });

    test('a "default" or missing directory reads as null', () async {
      final withDefault = await parse('screenshot_directory = "default"\n');
      expect(withDefault.screenshotDirectory, isNull);

      final absent = await parse('savefile_directory = "/saves"\n');
      expect(absent.screenshotDirectory, isNull);
      expect(absent.sortScreenshotsByContent, isFalse);
    });

    test('does not disturb the save/state settings it sits beside', () async {
      final config = await parse('''
system_directory = "/system"
savefile_directory = "/saves"
savestate_directory = "/states"
screenshot_directory = "/shots"
sort_savefiles_enable = "true"
sort_savestates_enable = "false"
sort_screenshots_by_content_enable = "true"
''');

      expect(config.systemDirectory, '/system');
      expect(config.savefileDirectory, '/saves');
      expect(config.savestateDirectory, '/states');
      expect(config.screenshotDirectory, '/shots');
      expect(config.sortSavefilesByCore, isTrue);
      expect(config.sortSavestatesByCore, isFalse);
      expect(config.sortScreenshotsByContent, isTrue);
    });
  });

  group('RetroArchConfig round-trip', () {
    test('toJson/fromJson keep both screenshot fields', () {
      const config = RetroArchConfig(
        configPath: '/cfg/retroarch.cfg',
        screenshotDirectory: '/shots',
        sortScreenshotsByContent: true,
      );

      final restored = RetroArchConfig.fromJson(config.toJson());

      expect(restored.screenshotDirectory, '/shots');
      expect(restored.sortScreenshotsByContent, isTrue);
    });

    test('reads the flag back from SQLite\'s 0/1 integer', () {
      final on = RetroArchConfig.fromJson(const {
        'config_path': '/cfg',
        'screenshot_directory': '/shots',
        'sort_screenshots_by_content_enable': 1,
      });
      final off = RetroArchConfig.fromJson(const {
        'config_path': '/cfg',
        'sort_screenshots_by_content_enable': 0,
      });

      expect(on.sortScreenshotsByContent, isTrue);
      expect(off.sortScreenshotsByContent, isFalse);
    });

    test('copyWith carries the screenshot fields forward', () {
      const config = RetroArchConfig(
        configPath: '/cfg',
        screenshotDirectory: '/shots',
        sortScreenshotsByContent: true,
      );

      final copy = config.copyWith(savefileDirectory: '/saves');

      expect(copy.screenshotDirectory, '/shots');
      expect(copy.sortScreenshotsByContent, isTrue);
    });
  });

  /// `screenshots_in_content_dir` — the setting that decides the whole
  /// question of *where* on an install that has it on.
  ///
  /// RetroArch's `screenshot_dump` builds a directory from
  /// `screenshot_directory` (plus the sort-by-content subfolder) and then
  /// throws it away:
  ///
  /// ```c
  /// if (     !*new_screenshot_dir
  ///       || settings->bools.screenshots_in_content_dir)
  ///    fill_pathname_basedir(new_screenshot_dir, name_base, ...);
  /// ```
  ///
  /// The fallback added for the "no directory configured" case therefore had
  /// no way to know it was naming a folder nothing writes to.
  ///
  /// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
  /// "Screenshot Directory From RetroArch Config"
  group('screenshots_in_content_dir', () {
    test('is parsed as a quoted bool', () async {
      final on = await parse('screenshots_in_content_dir = "true"\n');
      expect(on.screenshotsInContentDir, isTrue);

      final off = await parse('screenshots_in_content_dir = "false"\n');
      expect(off.screenshotsInContentDir, isFalse);
    });

    test('defaults to false when the config never names it', () async {
      final config = await parse('screenshot_directory = "/shots"\n');
      expect(config.screenshotsInContentDir, isFalse);
    });

    test('does not collide with screenshot_directory', () async {
      // Neither key is a prefix of the other, but they share one, and the
      // parser dispatches on startsWith.
      final config = await parse('''
screenshot_directory = "/shots"
screenshots_in_content_dir = "true"
sort_screenshots_by_content_enable = "true"
''');

      expect(config.screenshotDirectory, '/shots');
      expect(config.screenshotsInContentDir, isTrue);
      expect(config.sortScreenshotsByContent, isTrue);
    });

    test('suppresses the screenshot directory guess', () {
      // Guessing a folder here would put a path in the log that RetroArch
      // never writes to; the collector resolves the content directory per
      // game instead.
      final config = RetroArchConfigService.withScreenshotFallback(
        const RetroArchConfig(
          configPath: '/cfg/retroarch.cfg',
          screenshotsInContentDir: true,
        ),
      );

      expect(config.screenshotDirectory, isNull);
    });

    test('survives the JSON round trip and copyWith', () {
      const config = RetroArchConfig(
        configPath: '/cfg',
        screenshotsInContentDir: true,
      );

      expect(
        RetroArchConfig.fromJson(config.toJson()).screenshotsInContentDir,
        isTrue,
      );
      expect(
        config.copyWith(savefileDirectory: '/saves').screenshotsInContentDir,
        isTrue,
      );
      expect(
        RetroArchConfig.fromJson(const {
          'config_path': '/cfg',
          'screenshots_in_content_dir': 1,
        }).screenshotsInContentDir,
        isTrue,
      );
    });
  });
}
