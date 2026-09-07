import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_config_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/repositories/config_repository.dart';

import 'database_test_helper.dart';

/// Cover for the *live* half of the boolean-parsing convergence (issue #150).
///
/// `test/config_model_bool_parsing_test.dart` is exhaustive but runs entirely
/// through [ConfigModel.fromJson], which the app never reaches at runtime
/// (issue #144). [SqliteConfigService.loadConfig] is the reader on the real
/// startup path, and it had no parsing test at all — so these exercise it
/// against an actual `user_config` row, plus the two [ConfigRepository]
/// helpers that read single columns straight out of the same row.
void main() {
  final dbHelper = DatabaseTestHelper();
  late DatabaseAdapter db;

  setUp(() async {
    db = await dbHelper.setUp();
  });
  tearDown(() async => dbHelper.tearDown());

  /// A value only this test writes, so an assertion can prove the row was
  /// really read. [SqliteConfigService.loadConfig] swallows every exception and
  /// returns [ConfigModel.empty], whose booleans happen to look like defaults —
  /// without this check a thrown query would pass as a satisfied fallback.
  const sentinelLanguage = 'zz';

  /// Writes the single `user_config` row with [values] bound verbatim.
  ///
  /// Values are bound, not interpolated, so a Dart [String] lands in an
  /// INTEGER-affinity column as TEXT unless SQLite can read it as an integer
  /// literal — which is exactly how a pre-migration-v24 `video_sound` ('on' /
  /// 'off') or a hand-edited database looks to the reader.
  Future<void> plantConfigRow(Map<String, Object?> values) async {
    final columns = ['id', 'app_language', ...values.keys].join(', ');
    final marks = List.filled(values.length + 2, '?').join(', ');
    await db.execute('DELETE FROM user_config');
    await db.execute('INSERT INTO user_config ($columns) VALUES ($marks)', [
      1,
      sentinelLanguage,
      ...values.values,
    ]);
  }

  group('SqliteConfigService.loadConfig boolean coercion', () {
    test('no row at all yields every column default', () async {
      // Deliberately no row: getUserConfig() returns null and every flag has to
      // fall back to its own migration default. videoSound is the discriminator
      // between this path and the catch block — ConfigModel.empty has it false,
      // a real read of a missing row has it true.
      await db.execute('DELETE FROM user_config');

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.videoSound, isTrue, reason: 'video_sound DEFAULT 1');
      expect(loaded.isFullscreen, isTrue);
      expect(loaded.scanOnStartup, isTrue);
      expect(loaded.ignoreHiddenFiles, isTrue);
      expect(loaded.sfxEnabled, isTrue);
      expect(loaded.autoUpdateApp, isTrue);
      expect(loaded.autoUpdateSystems, isTrue);
      expect(loaded.dockEnabled, isTrue);
      expect(loaded.showCloudSyncIcon, isTrue);
      expect(loaded.rommUploadScreenshots, isTrue);
      expect(loaded.showGameInfo, isFalse);
      expect(loaded.setupCompleted, isFalse);
      expect(loaded.use12HourClock, isFalse);
      expect(loaded.hideBottomScreen, isFalse);
      expect(loaded.subfolderViewAll, isFalse);
      expect(loaded.rommShowLibrary, isFalse);
    });

    test('the 0/1 integers SQLite actually stores read literally', () async {
      // The shape every production write produces: saveUserConfig binds ints.
      await plantConfigRow({
        'video_sound': 0,
        'sfx_enabled': 0,
        'is_fullscreen': 0,
        'scan_on_startup': 0,
        'ignore_hidden_files': 0,
        'auto_update_app': 0,
        'auto_update_systems': 0,
        'dock_enabled': 0,
        'show_cloud_sync_icon': 0,
        'romm_upload_screenshots': 0,
        'show_game_info': 1,
        'setup_completed': 1,
        'use_12_hour_clock': 1,
        'hide_bottom_screen': 1,
        'subfolder_view_all': 1,
        'romm_show_library': 1,
      });

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.appLanguage, sentinelLanguage, reason: 'row was read');
      expect(loaded.videoSound, isFalse);
      expect(loaded.sfxEnabled, isFalse);
      expect(loaded.isFullscreen, isFalse);
      expect(loaded.scanOnStartup, isFalse);
      expect(loaded.ignoreHiddenFiles, isFalse);
      expect(loaded.autoUpdateApp, isFalse);
      expect(loaded.autoUpdateSystems, isFalse);
      expect(loaded.dockEnabled, isFalse);
      expect(loaded.showCloudSyncIcon, isFalse);
      expect(loaded.rommUploadScreenshots, isFalse);
      expect(loaded.showGameInfo, isTrue);
      expect(loaded.setupCompleted, isTrue);
      expect(loaded.use12HourClock, isTrue);
      expect(loaded.hideBottomScreen, isTrue);
      expect(loaded.subfolderViewAll, isTrue);
      expect(loaded.rommShowLibrary, isTrue);
    });

    test("legacy text 'on'/'off' still reads as on/off", () async {
      // `video_sound` held this text before migration v24 turned the column
      // into an INTEGER, and the downgrade path recreates the database rather
      // than un-migrating, so a v23-era row can still reach a newer build.
      await plantConfigRow({'video_sound': 'off'});
      expect((await SqliteConfigService.loadConfig()).videoSound, isFalse);

      await plantConfigRow({'video_sound': 'on'});
      expect((await SqliteConfigService.loadConfig()).videoSound, isTrue);
    });

    test(
      "text 'true'/'false' reads as true/false, not as the default",
      () async {
        // Neither is an integer literal, so both survive in an INTEGER-affinity
        // column as TEXT — and both used to be misread by the inline
        // `int.tryParse(...) ?? default` forms this converged.
        await plantConfigRow({
          'sfx_enabled': 'false',
          'romm_show_library': 'true',
          'use_12_hour_clock': 'TRUE',
        });

        final loaded = await SqliteConfigService.loadConfig();

        expect(loaded.appLanguage, sentinelLanguage, reason: 'row was read');
        expect(loaded.sfxEnabled, isFalse);
        expect(loaded.rommShowLibrary, isTrue);
        expect(loaded.use12HourClock, isTrue);
      },
    );

    test('an unrecognised value falls back to the column default', () async {
      await plantConfigRow({
        'video_sound': 'yes',
        'show_game_info': 'maybe',
        'sfx_enabled': 7,
      });

      final loaded = await SqliteConfigService.loadConfig();

      expect(loaded.appLanguage, sentinelLanguage, reason: 'row was read');
      expect(loaded.videoSound, isTrue, reason: 'DEFAULT 1');
      expect(loaded.showGameInfo, isFalse, reason: 'DEFAULT 0');
      expect(loaded.sfxEnabled, isTrue, reason: 'DEFAULT 1');
    });

    test('loadConfig and fromJson agree on the same stored row', () async {
      // The convergence property itself: both readers now run every flag
      // through ConfigModel.readBool, so the same row can no longer parse
      // differently depending on which half of the app looked at it.
      // `null` here means the row is inserted without those columns, so each
      // takes its schema DEFAULT — the case that pins the code fallbacks to
      // the column defaults.
      const shapes = <Object?>[null, 0, 1, '0', '1', 'on', 'off', 'nope'];
      for (final stored in shapes) {
        final row = stored == null
            ? <String, Object?>{}
            : <String, Object?>{'video_sound': stored, 'sfx_enabled': stored};
        await plantConfigRow(row);

        final loaded = await SqliteConfigService.loadConfig();
        final parsed = ConfigModel.fromJson(Map<String, dynamic>.from(row));

        expect(
          loaded.videoSound,
          parsed.videoSound,
          reason: 'video_sound disagreed for ${stored ?? 'the column default'}',
        );
        expect(
          loaded.sfxEnabled,
          parsed.sfxEnabled,
          reason: 'sfx_enabled disagreed for ${stored ?? 'the column default'}',
        );
      }
    });
  });

  group('ConfigRepository single-column reads use the same rule', () {
    test('integers read literally', () async {
      await plantConfigRow({
        'romm_upload_screenshots': 0,
        'romm_show_library': 1,
      });

      expect(await ConfigRepository.getRommUploadScreenshots(), isFalse);
      expect(await ConfigRepository.getRommShowLibrary(), isTrue);
    });

    test('text booleans no longer invert', () async {
      // Regression for the inline forms these replaced: `(int.tryParse(raw) ??
      // 1) != 0` read 'false' as **true**, and `(int.tryParse(raw) ?? 0) != 0`
      // read 'true' as **false**. Both now go through ConfigModel.readBool.
      await plantConfigRow({
        'romm_upload_screenshots': 'false',
        'romm_show_library': 'true',
      });

      expect(await ConfigRepository.getRommUploadScreenshots(), isFalse);
      expect(await ConfigRepository.getRommShowLibrary(), isTrue);
    });

    test('the repository agrees with loadConfig on every shape', () async {
      for (final stored in <Object?>['0', '1', 'off', 'on', 'false', 'true']) {
        await plantConfigRow({
          'romm_upload_screenshots': stored,
          'romm_show_library': stored,
        });

        final loaded = await SqliteConfigService.loadConfig();

        expect(
          await ConfigRepository.getRommUploadScreenshots(),
          loaded.rommUploadScreenshots,
          reason: 'romm_upload_screenshots disagreed for $stored',
        );
        expect(
          await ConfigRepository.getRommShowLibrary(),
          loaded.rommShowLibrary,
          reason: 'romm_show_library disagreed for $stored',
        );
      }
    });

    test('a missing row reads as the column defaults', () async {
      await db.execute('DELETE FROM user_config');

      expect(await ConfigRepository.getRommUploadScreenshots(), isTrue);
      expect(await ConfigRepository.getRommShowLibrary(), isFalse);
    });
  });
}
