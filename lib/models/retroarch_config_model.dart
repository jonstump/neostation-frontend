/// Represents the configuration and directory structure for a RetroArch installation.
///
/// Stores paths for critical RetroArch directories such as system (BIOS),
/// save files, and save states.
class RetroArchConfig {
  /// Unique identifier for the configuration entry in the local database.
  final int? id;

  /// Absolute filesystem path to the `retroarch.cfg` configuration file.
  final String configPath;

  /// Directory used for system-specific files such as BIOS and firmware.
  final String? systemDirectory;

  /// Directory where game save data (SRAM, Battery) is stored.
  final String? savefileDirectory;

  /// Directory where save state snapshots are stored.
  final String? savestateDirectory;

  /// Whether RetroArch files save data into a per-core subfolder
  /// (`sort_savefiles_enable`). When true a `.srm` lands in
  /// `<savefileDirectory>/<Core Name>/` rather than the directory root.
  final bool sortSavefilesByCore;

  /// Whether RetroArch files save states into a per-core subfolder
  /// (`sort_savestates_enable`). Tracked separately from
  /// [sortSavefilesByCore] because RetroArch exposes the two as independent
  /// settings and users do enable just one.
  final bool sortSavestatesByCore;

  /// Directory RetroArch writes its in-game captures to
  /// (`screenshot_directory`). Null when the setting is `default` or absent,
  /// in which case RetroArch decides at runtime and there is no folder we can
  /// name — the screenshot collector treats that as "nothing to collect".
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Screenshot Directory From RetroArch Config"
  final String? screenshotDirectory;

  /// Whether RetroArch files captures into a per-content subfolder
  /// (`sort_screenshots_by_content_enable`). When true a capture lands in
  /// `<screenshotDirectory>/<content directory name>/` rather than the
  /// directory root, so the collector has to look in both.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Screenshot Directory From RetroArch Config"
  final bool sortScreenshotsByContent;

  const RetroArchConfig({
    this.id,
    required this.configPath,
    this.systemDirectory,
    this.savefileDirectory,
    this.savestateDirectory,
    this.sortSavefilesByCore = false,
    this.sortSavestatesByCore = false,
    this.screenshotDirectory,
    this.sortScreenshotsByContent = false,
  });

  /// Creates a [RetroArchConfig] instance from a JSON-compatible map.
  factory RetroArchConfig.fromJson(Map<String, dynamic> json) {
    return RetroArchConfig(
      id: int.tryParse((json['id'] ?? '').toString()),
      configPath: (json['config_path'] ?? json['configPath'] ?? '').toString(),
      systemDirectory: (json['system_directory'] ?? json['systemDirectory'])
          ?.toString(),
      savefileDirectory:
          (json['savefile_directory'] ?? json['savefileDirectory'])?.toString(),
      savestateDirectory:
          (json['savestate_directory'] ?? json['savestateDirectory'])
              ?.toString(),
      sortSavefilesByCore:
          json['sort_savefiles_by_core'] == true ||
          json['sortSavefilesByCore'] == true,
      sortSavestatesByCore:
          json['sort_savestates_by_core'] == true ||
          json['sortSavestatesByCore'] == true,
      screenshotDirectory:
          (json['screenshot_directory'] ?? json['screenshotDirectory'])
              ?.toString(),
      sortScreenshotsByContent: _asBool(
        json['sort_screenshots_by_content_enable'] ??
            json['sort_screenshots_by_content'] ??
            json['sortScreenshotsByContent'],
      ),
    );
  }

  /// Reads a flag that may arrive as a bool (from [toJson]) or as SQLite's
  /// `0`/`1` integer (from the `user_retroarch_config` row).
  static bool _asBool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final s = raw?.toString().toLowerCase();
    return s == 'true' || s == '1';
  }

  /// Converts the configuration instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'config_path': configPath,
      'system_directory': systemDirectory,
      'savefile_directory': savefileDirectory,
      'savestate_directory': savestateDirectory,
      'sort_savefiles_by_core': sortSavefilesByCore,
      'sort_savestates_by_core': sortSavestatesByCore,
      'screenshot_directory': screenshotDirectory,
      'sort_screenshots_by_content_enable': sortScreenshotsByContent,
    };
  }

  /// Returns a copy of the configuration with the specified fields updated.
  RetroArchConfig copyWith({
    int? id,
    String? configPath,
    String? systemDirectory,
    String? savefileDirectory,
    String? savestateDirectory,
    bool? sortSavefilesByCore,
    bool? sortSavestatesByCore,
    String? screenshotDirectory,
    bool? sortScreenshotsByContent,
  }) {
    return RetroArchConfig(
      id: id ?? this.id,
      configPath: configPath ?? this.configPath,
      systemDirectory: systemDirectory ?? this.systemDirectory,
      savefileDirectory: savefileDirectory ?? this.savefileDirectory,
      savestateDirectory: savestateDirectory ?? this.savestateDirectory,
      sortSavefilesByCore: sortSavefilesByCore ?? this.sortSavefilesByCore,
      sortSavestatesByCore: sortSavestatesByCore ?? this.sortSavestatesByCore,
      screenshotDirectory: screenshotDirectory ?? this.screenshotDirectory,
      sortScreenshotsByContent:
          sortScreenshotsByContent ?? this.sortScreenshotsByContent,
    );
  }

  @override
  String toString() {
    return 'RetroArchConfig(id: $id, path: $configPath, system: $systemDirectory, saves: $savefileDirectory, states: $savestateDirectory)';
  }
}
