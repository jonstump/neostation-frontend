import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/config_model.dart';

/// Regression cover for issue #131: every boolean on [ConfigModel] must coerce
/// the same way regardless of which shape it arrives in — a camelCase JSON
/// `bool` from [ConfigModel.toJson], or a snake_case `0`/`1` integer in the
/// shape `SqliteService.getUserConfig()` returns for the `user_config` row.
void main() {
  /// Every boolean field, paired with its database column and the value it must
  /// take when neither key is present.
  const fields = <String, ({String column, bool fallback})>{
    'showGameInfo': (column: 'show_game_info', fallback: false),
    'isFullscreen': (column: 'is_fullscreen', fallback: true),
    'bartopExitPoweroff': (column: 'bartop_exit_poweroff', fallback: false),
    'scanOnStartup': (column: 'scan_on_startup', fallback: true),
    'ignoreHiddenFiles': (column: 'ignore_hidden_files', fallback: true),
    'setupCompleted': (column: 'setup_completed', fallback: false),
    'hideBottomScreen': (column: 'hide_bottom_screen', fallback: false),
    'videoSound': (column: 'video_sound', fallback: false),
    'sfxEnabled': (column: 'sfx_enabled', fallback: true),
    'use12HourClock': (column: 'use_12_hour_clock', fallback: false),
    'hideRecentCard': (column: 'hide_recent_card', fallback: false),
    'hideTabSync': (column: 'hide_tab_sync', fallback: false),
    'hideTabAchievements': (column: 'hide_tab_achievements', fallback: false),
    'hideTabScraper': (column: 'hide_tab_scraper', fallback: false),
    'hideTabRomm': (column: 'hide_tab_romm', fallback: false),
    'hideTabSearch': (column: 'hide_tab_search', fallback: false),
    'autoUpdateApp': (column: 'auto_update_app', fallback: true),
    'autoUpdateSystems': (column: 'auto_update_systems', fallback: true),
    'dockEnabled': (column: 'dock_enabled', fallback: true),
    'showAchievementsBadge': (
      column: 'show_achievements_badge',
      fallback: false,
    ),
    'showCloudSyncIcon': (column: 'show_cloud_sync_icon', fallback: true),
    'raMatchOnStartup': (column: 'ra_match_on_startup', fallback: false),
    'subfolderViewAll': (column: 'subfolder_view_all', fallback: false),
    'rommUploadScreenshots': (
      column: 'romm_upload_screenshots',
      fallback: true,
    ),
    'rommShowLibrary': (column: 'romm_show_library', fallback: false),
  };

  /// Reads [field] off a [ConfigModel] without reflection.
  bool read(ConfigModel c, String field) => switch (field) {
    'showGameInfo' => c.showGameInfo,
    'isFullscreen' => c.isFullscreen,
    'bartopExitPoweroff' => c.bartopExitPoweroff,
    'scanOnStartup' => c.scanOnStartup,
    'ignoreHiddenFiles' => c.ignoreHiddenFiles,
    'setupCompleted' => c.setupCompleted,
    'hideBottomScreen' => c.hideBottomScreen,
    'videoSound' => c.videoSound,
    'sfxEnabled' => c.sfxEnabled,
    'use12HourClock' => c.use12HourClock,
    'hideRecentCard' => c.hideRecentCard,
    'hideTabSync' => c.hideTabSync,
    'hideTabAchievements' => c.hideTabAchievements,
    'hideTabScraper' => c.hideTabScraper,
    'hideTabRomm' => c.hideTabRomm,
    'hideTabSearch' => c.hideTabSearch,
    'autoUpdateApp' => c.autoUpdateApp,
    'autoUpdateSystems' => c.autoUpdateSystems,
    'dockEnabled' => c.dockEnabled,
    'showAchievementsBadge' => c.showAchievementsBadge,
    'showCloudSyncIcon' => c.showCloudSyncIcon,
    'raMatchOnStartup' => c.raMatchOnStartup,
    'subfolderViewAll' => c.subfolderViewAll,
    'rommUploadScreenshots' => c.rommUploadScreenshots,
    'rommShowLibrary' => c.rommShowLibrary,
    _ => throw ArgumentError('unmapped field $field'),
  };

  group('ConfigModel.fromJson boolean coercion', () {
    test('a snake_case row of integer 0/1 parses to the stored value', () {
      for (final entry in fields.entries) {
        for (final stored in [true, false]) {
          final parsed = ConfigModel.fromJson({
            entry.value.column: stored ? 1 : 0,
          });
          expect(
            read(parsed, entry.key),
            stored,
            reason:
                '{${entry.value.column}: ${stored ? 1 : 0}} '
                'must parse to $stored',
          );
        }
      }
    });

    test('a snake_case row of JSON booleans parses to the stored value', () {
      for (final entry in fields.entries) {
        for (final stored in [true, false]) {
          final parsed = ConfigModel.fromJson({entry.value.column: stored});
          expect(
            read(parsed, entry.key),
            stored,
            reason: '{${entry.value.column}: $stored} must parse to $stored',
          );
        }
      }
    });

    test('a camelCase JSON bool parses to the stored value', () {
      for (final entry in fields.entries) {
        for (final stored in [true, false]) {
          final parsed = ConfigModel.fromJson({entry.key: stored});
          expect(
            read(parsed, entry.key),
            stored,
            reason: '{${entry.key}: $stored} must parse to $stored',
          );
        }
      }
    });

    test('stringified integers parse to the stored value', () {
      for (final entry in fields.entries) {
        for (final stored in [true, false]) {
          final parsed = ConfigModel.fromJson({
            entry.value.column: stored ? '1' : '0',
          });
          expect(read(parsed, entry.key), stored, reason: entry.key);
        }
      }
    });

    test('an absent key keeps the field default', () {
      final empty = ConfigModel.fromJson(const {});
      for (final entry in fields.entries) {
        expect(read(empty, entry.key), entry.value.fallback, reason: entry.key);
        // A null value must behave exactly like a missing key.
        final nulled = ConfigModel.fromJson({entry.value.column: null});
        expect(
          read(nulled, entry.key),
          entry.value.fallback,
          reason: '${entry.key} (explicit null)',
        );
      }
    });

    test('an unrecognised value falls back to the field default', () {
      for (final entry in fields.entries) {
        final parsed = ConfigModel.fromJson({entry.value.column: 'maybe'});
        expect(
          read(parsed, entry.key),
          entry.value.fallback,
          reason: entry.key,
        );
      }
    });

    test('every boolean survives a toJson/fromJson round trip', () {
      // Flip every flag away from its default, then round-trip through the
      // on-disk shape. `sfxEnabled: false` and `dockEnabled: false` used to
      // come back as `true` here.
      for (final entry in fields.entries) {
        for (final stored in [true, false]) {
          final written = ConfigModel.fromJson({entry.key: stored}).toJson();
          expect(
            read(ConfigModel.fromJson(written), entry.key),
            stored,
            reason: '${entry.key} must round-trip as $stored',
          );
        }
      }
    });

    test('camelCase wins over the snake_case column when both are present', () {
      final parsed = ConfigModel.fromJson(const {
        'sfxEnabled': false,
        'sfx_enabled': 1,
      });
      expect(parsed.sfxEnabled, isFalse);
    });
  });

  group('ConfigModel.readBool', () {
    test('accepts every shape the two config sources produce', () {
      bool call(Object? value, {bool fallback = false}) =>
          ConfigModel.readBool({'k': value}, 'k', 'k', fallback);

      expect(call(true), isTrue);
      expect(call(false, fallback: true), isFalse);
      expect(call(1), isTrue);
      expect(call(0, fallback: true), isFalse);
      expect(call('1'), isTrue);
      expect(call('0', fallback: true), isFalse);
      expect(call('true'), isTrue);
      expect(call('False', fallback: true), isFalse);
      expect(call(' TRUE '), isTrue);
      // Legacy `video_sound` text, normalised to INTEGER by migration v24.
      expect(call('on'), isTrue);
      expect(call('off', fallback: true), isFalse);
      // Null, missing and unrecognised all yield the fallback.
      expect(call(null, fallback: true), isTrue);
      expect(ConfigModel.readBool(const {}, 'k', 'k', true), isTrue);
      expect(call('yes', fallback: true), isTrue);
      expect(call(2), isFalse);
    });

    test('a null map yields the fallback for every key', () {
      expect(ConfigModel.readBool(null, 'k', 'k', true), isTrue);
      expect(ConfigModel.readBool(null, 'k', 'k', false), isFalse);
    });

    test('falls back to the snake_case key when camelCase is absent', () {
      expect(
        ConfigModel.readBool(
          const {'dock_enabled': 0},
          'dockEnabled',
          'dock_enabled',
          true,
        ),
        isFalse,
      );
    });
  });
}
