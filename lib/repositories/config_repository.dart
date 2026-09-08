import '../models/config_model.dart';
import '../data/datasources/sqlite_service.dart';

/// Repository for user configuration data access.
class ConfigRepository {
  /// Returns the list of ROM folder paths configured by the user.
  static Future<List<String>> getUserRomFolders() =>
      SqliteService.getUserRomFolders();

  /// Returns the full user_config row, or null if not yet created.
  static Future<Map<String, dynamic>?> getUserConfig() =>
      SqliteService.getUserConfig();

  /// Whether a finished session's RetroArch captures are pushed to RomM
  /// (`user_config.romm_upload_screenshots`, migration v163).
  ///
  /// Defaults to true when the row or the column is missing: the column is
  /// created with `DEFAULT 1`, and a database that has not reached v163 yet
  /// should behave like the feature's shipped default rather than silently
  /// off. Any read failure also reads as the default — the caller still
  /// checks the connection and the link before it uploads anything.
  ///
  /// Read through [ConfigModel.readBool] rather than an inline `!= 0`, so this
  /// repository, `SqliteConfigService.loadConfig` and [ConfigModel.fromJson]
  /// coerce the same column identically. The inline form this replaced read a
  /// stored `'false'` or `'off'` as **true**, because `int.tryParse` fails on
  /// them and fell through to the `?? 1` default.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload Toggle"
  static Future<bool> getRommUploadScreenshots() async {
    final row = await SqliteService.getUserConfig();
    return ConfigModel.readBool(
      row,
      'rommUploadScreenshots',
      'romm_upload_screenshots',
      true,
    );
  }

  /// Persists the "Upload screenshots to RomM" choice.
  ///
  /// A single-column update rather than a whole-config write: the row is
  /// shared with every other preference and [SqliteService.saveUserConfig]
  /// only touches the columns it is handed, so a concurrent settings save
  /// cannot revert this one from a stale read.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload Toggle"
  static Future<void> setRommUploadScreenshots(bool value) =>
      SqliteService.saveUserConfig(rommUploadScreenshots: value ? 1 : 0);

  /// Whether hide, favourite and last-played changes for RomM-linked games
  /// are pushed to the server (`user_config.romm_push_play_state`, migration
  /// v166).
  ///
  /// Defaults to true when the row or the column is missing, for the same
  /// reason as [getRommUploadScreenshots]: the column is created with
  /// `DEFAULT 1`, and a database that has not reached v166 yet should behave
  /// like the shipped default. The hooks that read this still require a link
  /// row before they queue anything, so the default never pushes for a game
  /// RomM does not know.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Push Toggle"
  static Future<bool> getRommPushPlayState() async {
    final row = await SqliteService.getUserConfig();
    return ConfigModel.readBool(
      row,
      'rommPushPlayState',
      'romm_push_play_state',
      true,
    );
  }

  /// Persists the "Push play state to RomM" choice as a single-column update,
  /// for the same concurrent-writer reason as [setRommUploadScreenshots].
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Push Toggle"
  static Future<void> setRommPushPlayState(bool value) =>
      SqliteService.saveUserConfig(rommPushPlayState: value ? 1 : 0);

  /// Whether the RomM server's library is shown inside the local systems
  /// (`user_config.romm_show_library`, migration v165).
  ///
  /// Defaults to false when the row or the column is missing: the feature is
  /// opt-in, and a database that has not reached v165 yet must behave exactly
  /// as it did before it existed.
  ///
  /// Read through [ConfigModel.readBool] for the same reason as
  /// [getRommUploadScreenshots]. The inline form this replaced read a stored
  /// `'true'` or `'on'` as **false** (`int.tryParse` fails, `?? 0` wins).
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Catalog Tables"
  static Future<bool> getRommShowLibrary() async {
    final row = await SqliteService.getUserConfig();
    return ConfigModel.readBool(
      row,
      'rommShowLibrary',
      'romm_show_library',
      false,
    );
  }

  /// The scope a game list opens in — `all` or `downloaded`
  /// (`user_config.romm_library_default_scope`, migration v165).
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Library Scope"
  static Future<String> getRommLibraryDefaultScope() async {
    final row = await SqliteService.getUserConfig();
    final raw = row?['romm_library_default_scope']?.toString();
    return (raw == null || raw.isEmpty) ? 'all' : raw;
  }

  /// Cap in megabytes on the on-disk RomM cover cache
  /// (`user_config.romm_cover_cache_mb`, migration v165).
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Cover Cache"
  static Future<int> getRommCoverCacheMb() async {
    final row = await SqliteService.getUserConfig();
    final raw = row?['romm_cover_cache_mb'];
    if (raw == null) return 200;
    return int.tryParse(raw.toString()) ?? 200;
  }

  // ── Theme settings ──────────────────────────────────────────────────────

  static Future<String> getThemeName() => SqliteService.getThemeName();

  static Future<void> updateThemeName(String name) =>
      SqliteService.updateThemeName(name);

  // ── Active asset theme ────────────────────────────────────────────────────

  static Future<String> getActiveTheme() => SqliteService.getActiveTheme();

  static Future<void> updateActiveTheme(String folder) =>
      SqliteService.updateActiveTheme(folder);

  // ── BIOS / firmware destination ───────────────────────────────────────────

  /// The folder the user picked for BIOS/firmware files, or null when none has
  /// been chosen. Second in the destination precedence, behind RetroArch's own
  /// `system_directory` — see `BiosDestinationService.resolve`.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  static Future<String?> getBiosDirectory() => SqliteService.getBiosDirectory();

  /// Persists the user-chosen BIOS/firmware folder, exactly as the picker
  /// returned it (a plain path, or an Android SAF tree URI).
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  static Future<void> setBiosDirectory(String directory) =>
      SqliteService.updateBiosDirectory(directory);

  // ── General user config (write) ───────────────────────────────────────────

  static Future<void> saveUserConfig({String? lastScan}) =>
      SqliteService.saveUserConfig(lastScan: lastScan);
}
