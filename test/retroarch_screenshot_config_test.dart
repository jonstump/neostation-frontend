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
}
