import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';

/// The whole upgrade a database takes when an upstream build left it at
/// version 160 and this fork's binary then opens it: v161 to v172, in order.
///
/// `upstream_database_backfill_migration_test.dart` covers v172 on its own.
/// This pins the path around it: the fork's v161 to v168 must run on a schema
/// that never saw the fork's v157 to v160, upstream's renumbered v169 to v171
/// must be no-ops on a schema that already has their columns, and v172 must
/// then add what was skipped.
///
/// The tables below are upstream's own `CREATE TABLE` statements at
/// `_databaseVersion = 160` (upstream commit 0eb9b23), limited to the tables
/// v157 to v172 read or alter.
void main() {
  const upstreamV160Schema = <String>[
    '''
    CREATE TABLE user_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      last_scan TEXT,
      game_view_mode TEXT DEFAULT 'list',
      system_view_mode TEXT DEFAULT 'grid',
      theme_name TEXT DEFAULT 'system',
      video_sound INTEGER DEFAULT 1,
      ra_user TEXT,
      show_game_info INTEGER DEFAULT 0,
      is_fullscreen INTEGER DEFAULT 1,
      bartop_exit_poweroff INTEGER DEFAULT 0,
      scan_on_startup INTEGER DEFAULT 1,
      ignore_hidden_files INTEGER DEFAULT 1,
      setup_completed INTEGER DEFAULT 0,
      hide_bottom_screen INTEGER DEFAULT 0,
      sfx_enabled INTEGER DEFAULT 1,
      sfx_volume REAL DEFAULT 0.75,
      system_sort_by TEXT DEFAULT 'alphabetical',
      collection_sort_by TEXT DEFAULT 'name',
      collection_sort_order TEXT DEFAULT 'asc',
      system_sort_order TEXT DEFAULT 'asc',
      app_language TEXT DEFAULT 'en',
      active_theme TEXT DEFAULT '',
      hide_recent_card INTEGER DEFAULT 0,
      recent_card_size TEXT DEFAULT 'default',
      legend_hidden INTEGER DEFAULT 0,
      game_details_tab TEXT DEFAULT 'wheel',
      hide_tab_sync INTEGER DEFAULT 0,
      hide_tab_achievements INTEGER DEFAULT 0,
      hide_tab_scraper INTEGER DEFAULT 0,
      hide_tab_romm INTEGER DEFAULT 0,
      hide_tab_search INTEGER DEFAULT 0,
      hide_search_card INTEGER DEFAULT 1,
      active_sync_provider TEXT DEFAULT 'neosync',
      systems_version TEXT DEFAULT '',
      ra_seed_stamp TEXT DEFAULT '',
      neostation_app_version TEXT DEFAULT '',
      auto_update_app INTEGER DEFAULT 1,
      auto_update_systems INTEGER DEFAULT 1,
      system_grid_columns TEXT DEFAULT 'M',
      game_grid_columns TEXT DEFAULT 'M',
      game_carousel_card_style TEXT DEFAULT 'fanart',
      use_12_hour_clock INTEGER DEFAULT 0,
      dock_apps TEXT,
      dock_enabled INTEGER DEFAULT 1,
      dock_slot_count INTEGER DEFAULT 3,
      now_playing_dim_delay INTEGER DEFAULT 3,
      now_playing_dim_level INTEGER DEFAULT 100,
      fanart_dim_level INTEGER DEFAULT 25,
      esde_folder_path TEXT DEFAULT '',
      show_achievements_badge INTEGER DEFAULT 0,
      show_cloud_sync_icon INTEGER DEFAULT 1,
      ra_match_on_startup INTEGER DEFAULT 0,
      subfolder_view_all INTEGER DEFAULT 0,
      hide_system_logos INTEGER DEFAULT 0,
      neoglass_blur INTEGER DEFAULT 0,
      neoglass_transparency INTEGER DEFAULT 10,
      neoglass_border_width REAL DEFAULT 2
    )
    ''',
    '''
    CREATE TABLE user_collections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      image_path TEXT,
      color1 TEXT,
      color2 TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
    ''',
    '''
    CREATE TABLE user_retroarch_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      config_path TEXT NOT NULL,
      system_directory TEXT,
      savefile_directory TEXT,
      savestate_directory TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
    ''',
    '''
    CREATE TABLE user_screenscraper_metadata (
      app_system_id TEXT NOT NULL,
      filename TEXT NOT NULL,
      id_ra INTEGER,
      real_name TEXT,
      description_en TEXT,
      description_es TEXT,
      description_fr TEXT,
      description_de TEXT,
      description_it TEXT,
      description_pt TEXT,
      rating REAL,
      release_date TEXT,
      developer TEXT,
      publisher TEXT,
      genre TEXT,
      players TEXT,
      is_fully_scraped INTEGER DEFAULT 0,
      esde_media_subdir TEXT,
      esde_imported INTEGER DEFAULT 0,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(app_system_id, filename)
    )
    ''',
    '''
    CREATE TABLE user_system_settings (
      app_system_id TEXT NOT NULL,
      recursive_scan INTEGER DEFAULT 1,
      hide_extension INTEGER DEFAULT 1,
      hide_parentheses INTEGER DEFAULT 1,
      hide_brackets INTEGER DEFAULT 1,
      custom_background_path TEXT,
      custom_logo_path TEXT,
      hide_logo INTEGER DEFAULT 0,
      prefer_file_name INTEGER DEFAULT 0,
      subfolder_view INTEGER DEFAULT 0,
      esde_media_dir TEXT,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(app_system_id)
    )
    ''',
    '''
    CREATE TABLE user_romm_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      server_url TEXT,
      username TEXT,
      password TEXT,
      api_key TEXT,
      access_token TEXT,
      refresh_token TEXT,
      token_expires INTEGER,
      last_verified TEXT,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
    ''',
    '''
    CREATE TABLE app_romm_rom_map (
      romname TEXT NOT NULL,
      system_folder TEXT NOT NULL,
      romm_rom_id INTEGER NOT NULL,
      romm_fs_name TEXT,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (romname, system_folder)
    )
    ''',
  ];

  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    for (final statement in upstreamV160Schema) {
      db.execute(statement);
    }
  });

  tearDown(() {
    db.close();
  });

  Future<void> upgradeFrom160() async {
    for (var version = 161; version <= 172; version++) {
      await SqliteMigrations.migrateToVersion(db, version);
    }
  }

  List<String> columns(String table) => db
      .select('PRAGMA table_info($table)')
      .map((c) => c['name'].toString())
      .toList();

  Map<String, List<String>> schema() => {
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ))
      row['name'].toString(): columns(row['name'].toString()),
  };

  group('an upstream database at v160 upgraded through v172', () {
    test("gains every column the fork's v157 to v168 add", () async {
      await upgradeFrom160();

      // v157 to v160, skipped on this database and backfilled by v172.
      expect(columns('user_system_settings'), contains('esde_media_root'));
      expect(columns('app_romm_rom_map'), contains('link_source'));
      expect(
        columns('user_screenscraper_metadata'),
        containsAll(['metadata_source', 'field_sources']),
      );
      expect(
        columns('user_romm_config'),
        containsAll(['romm_token_name', 'romm_token_expires_at']),
      );

      // v161 to v168, which run in their own slots.
      expect(
        columns('user_collections'),
        containsAll([
          ...SqliteMigrations.rommCollectionProvenanceColumns,
          SqliteMigrations.rommCollectionOriginColumn,
        ]),
      );
      expect(
        columns('user_retroarch_config'),
        containsAll(SqliteMigrations.retroArchScreenshotColumns.keys),
      );
      expect(
        columns('user_config'),
        containsAll([
          'bios_directory',
          'romm_upload_screenshots',
          ...SqliteMigrations.rommLibraryConfigColumns.keys,
          SqliteMigrations.rommPushPlayStateColumn,
        ]),
      );
    });

    test("leaves upstream's own columns alone in v169 to v171", () async {
      final before = columns('user_config');

      await upgradeFrom160();

      final after = columns('user_config');
      // Every upstream column is still there, once.
      expect(after, containsAll(before));
      for (final column in const [
        'neoglass_blur',
        'neoglass_transparency',
        'neoglass_border_width',
        'hide_system_logos',
        'hide_search_card',
      ]) {
        expect(after.where((c) => c == column), hasLength(1), reason: column);
      }
    });

    test('keeps the rows upstream wrote', () async {
      db.execute(
        'INSERT INTO user_config (id, hide_search_card, neoglass_blur) '
        'VALUES (1, 0, 1)',
      );
      db.execute(
        "INSERT INTO user_collections (id, name) VALUES ('c1', 'Favourites')",
      );
      db.execute(
        'INSERT INTO app_romm_rom_map (romname, system_folder, romm_rom_id) '
        "VALUES ('game.sfc', 'snes', 42)",
      );

      await upgradeFrom160();

      final config = db.select('SELECT * FROM user_config').single;
      expect(config['hide_search_card'], 0);
      expect(config['neoglass_blur'], 1);
      expect(config['romm_show_library'], 0);

      // A collection upstream created was never mirrored from RomM, so the
      // v167 origin backfill must not claim it.
      final collection = db.select('SELECT * FROM user_collections').single;
      expect(collection['name'], 'Favourites');
      expect(collection[SqliteMigrations.rommCollectionOriginColumn], isNull);

      final link = db.select('SELECT * FROM app_romm_rom_map').single;
      expect(link['romm_rom_id'], 42);
      expect(link['link_source'], isNull);
    });

    test('is a no-op when run a second time', () async {
      await upgradeFrom160();
      final before = schema();

      await upgradeFrom160();

      expect(schema(), before);
    });
  });
}
