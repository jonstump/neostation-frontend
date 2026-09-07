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
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload Toggle"
  static Future<bool> getRommUploadScreenshots() async {
    final row = await SqliteService.getUserConfig();
    final raw = row?['romm_upload_screenshots'];
    if (raw == null) return true;
    if (raw is bool) return raw;
    return (int.tryParse(raw.toString()) ?? 1) != 0;
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
