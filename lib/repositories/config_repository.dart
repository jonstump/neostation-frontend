import '../data/datasources/sqlite_service.dart';

/// Repository for user configuration data access.
class ConfigRepository {
  /// Returns the list of ROM folder paths configured by the user.
  static Future<List<String>> getUserRomFolders() =>
      SqliteService.getUserRomFolders();

  /// Returns the full user_config row, or null if not yet created.
  static Future<Map<String, dynamic>?> getUserConfig() =>
      SqliteService.getUserConfig();

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
