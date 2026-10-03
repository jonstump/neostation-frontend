import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/datasources/sqlite_service.dart';
import '../widgets/permission_check_wrapper.dart';
import 'config_service.dart';
import 'credential_store.dart';
import 'game_session_persistence.dart';
import 'logger_service.dart';
import 'saf_directory_service.dart';
import 'startup_theme_cache.dart';
import 'user_data_location_service.dart';

/// Where the user data lives and whether the user chose it.
///
/// [path] is the resolved user-data folder; [isCustom] distinguishes a folder
/// the user picked (which may hold foreign files such as ROMs) from the app's
/// own default location.
class ResetUserDataLocation {
  const ResetUserDataLocation({
    required this.path,
    required this.isCustom,
    required this.mediaPath,
    required this.logFilePath,
    required this.databasePath,
  });

  final String path;
  final bool isCustom;
  final String mediaPath;
  final String logFilePath;
  final String databasePath;
}

/// One store a reset clears, paired with the code that clears it.
class ResetStep {
  const ResetStep(this.store, this.clearer);

  /// Store name used in the summary and the log lines.
  final String store;

  final Future<void> Function() clearer;
}

/// Outcome of [ResetService.resetAll]: which stores were cleared and, for the
/// ones that failed, why.
class ResetSummary {
  ResetSummary();

  /// Stores that were cleared, in the order they ran.
  final List<String> cleared = [];

  /// Store name -> reason, for every clearer that threw.
  final Map<String, String> failed = {};

  bool get isFullyCleared => failed.isEmpty;

  @override
  String toString() => 'ResetSummary(cleared: $cleared, failed: $failed)';
}

// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "What A Reset Removes"
/// Deletes everything the app wrote, one store at a time.
///
/// A reset exists so a broken install or a fresh start can be reached from the
/// device itself. ROM files, saves, states and BIOS are never the app's to
/// delete, so inside a user-chosen folder only the app's own files go: the
/// database, the media cache and the log. Each clearer is independent, so one
/// locked file cannot leave logins behind, and [resetAll] reports what cleared
/// and what did not instead of throwing.
class ResetService {
  static final _log = LoggerService.instance;

  /// The store names the summary and log lines use.
  static const String storeCredentials = 'credentials';
  static const String storePreferences = 'preferences';
  static const String storeDatabase = 'database';
  static const String storeMediaCache = 'media cache';
  static const String storeLog = 'log';
  static const String storeSafGrants = 'SAF grants';

  /// Every credential the app stores, by [CredentialStore] key. The owning
  /// repositories and services keep these as private constants; a reset is the
  /// one place that must enumerate all of them, so the list lives here and the
  /// comment names each owner.
  static const List<String> _credentialKeys = [
    'romm_password', // RommRepository
    'romm_api_key', // RommRepository
    'screenscraper_password', // ScraperRepository
    'ra_api_key', // RetroAchievementsRepository
    'auth_token', // NeoSync auth/billing/notification services
  ];

  /// The user-data location the file clearers use inside [resetAll].
  ///
  /// Captured once, up front, on purpose: [clearPreferences] forgets the
  /// custom user-data path, and the clearers that run after it would otherwise
  /// resolve the default folder and delete the wrong files. A clearer called
  /// on its own resolves the location itself.
  static ResetUserDataLocation? _capturedLocation;

  /// Runs every clearer in the fixed order the spec requires and reports what
  /// happened. Never throws.
  ///
  // Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Order And Resilience"
  static Future<ResetSummary> resetAll() async {
    _capturedLocation = await _resolveLocation();
    try {
      return await runSteps(await steps());
    } finally {
      _capturedLocation = null;
    }
  }

  /// The clearers in the order a reset must run: credentials and preferences
  /// first, so a crash midway still leaves the next launch a first run.
  @visibleForTesting
  static Future<List<ResetStep>> steps() async {
    return [
      ResetStep(storeCredentials, clearCredentials),
      ResetStep(storePreferences, clearPreferences),
      ResetStep(
        storeDatabase,
        () => clearDatabase(location: _capturedLocation),
      ),
      ResetStep(
        storeMediaCache,
        () => clearMediaCache(location: _capturedLocation),
      ),
      ResetStep(storeLog, () => clearLog(location: _capturedLocation)),
      ResetStep(storeSafGrants, clearSafGrants),
    ];
  }

  /// Runs [steps], isolating failures: a clearer that throws is logged with
  /// what it was clearing and the next one still runs.
  @visibleForTesting
  static Future<ResetSummary> runSteps(List<ResetStep> stepsToRun) async {
    final summary = ResetSummary();
    for (final step in stepsToRun) {
      try {
        await step.clearer();
        summary.cleared.add(step.store);
        _log.i('ResetService: store=${step.store} outcome=cleared');
      } catch (e) {
        summary.failed[step.store] = e.toString();
        _log.w('ResetService: store=${step.store} outcome=failed error=$e');
      }
    }
    return summary;
  }

  /// Deletes every credential the app stored. [CredentialStore.delete] is
  /// already best effort per backend and logs a refused delete with the key
  /// name, never the value
  /// (SPEC-0021 REQ "Error Handling Standards").
  static Future<void> clearCredentials() async {
    for (final key in _credentialKeys) {
      await CredentialStore.delete(key);
    }
  }

  /// Forgets every `SharedPreferences` key the app wrote, through the owning
  /// services where they exist.
  ///
  /// This clears the custom user-data path too, so the setup wizard asks for
  /// it again; the folder itself is not touched from here
  /// (SPEC-0021 REQ "What A Reset Removes").
  static Future<void> clearPreferences() async {
    await UserDataLocationService.clearCustomPath();
    await StartupThemeCache.clear();
    await GameSessionPersistence.clearGameSession();
    final prefs = await SharedPreferences.getInstance();
    // Declared in PermissionCheckWrapper (a widget, so not imported from a
    // service); the value must not drift from the const there.
    await prefs.remove(PermissionCheckWrapper.setupCompletedKey);
  }

  /// Closes the database, then deletes its file and SQLite's sidecars.
  ///
  // Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Database Operation Standards"
  static Future<void> clearDatabase({ResetUserDataLocation? location}) async {
    final dbPath =
        location?.databasePath ?? await SqliteService.getActualDatabasePath();
    await SqliteService.closeDatabase();

    // The secondary-display engine opens the same database. It is not told to
    // close first: on Android (the only platform with a second engine) the
    // reset is followed by a full activity relaunch, and POSIX unlink
    // semantics make deleting an open file safe there. A deletion that still
    // fails is recorded by [resetAll] like any other
    // (SPEC-0021 REQ "Order And Resilience").
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      await _deleteByName(dbPath, suffix);
    }
  }

  /// Deletes the media cache directory — scraped art and the RomM cover cache
  /// with it — by name inside the user-data folder, never the folder itself.
  static Future<void> clearMediaCache({ResetUserDataLocation? location}) async {
    final mediaPath = location?.mediaPath ?? await ConfigService.getMediaPath();
    await _deleteDirectoryByName(mediaPath);
  }

  /// Deletes the log file and its rotated copy. The logger's file output is
  /// detached first so the deletion is not racing an open handle.
  static Future<void> clearLog({ResetUserDataLocation? location}) async {
    final logFilePath =
        location?.logFilePath ?? await ConfigService.getLogFilePath();
    await LoggerService.instance.closeFileOutput();
    await _deleteByName(logFilePath, '');
    await _deleteByName(logFilePath, '.old');
  }

  /// Releases every persisted SAF URI permission the app holds. No-op off
  /// Android
  /// (SPEC-0021 REQ "What A Reset Removes").
  static Future<void> clearSafGrants() async {
    await SafDirectoryService.releaseAllPersistedPermissions();
  }

  /// Resolves every path the file clearers need in one go, tolerating failure:
  /// an unavailable user-data folder means the clearers each fail on their own
  /// and the summary says so.
  static Future<ResetUserDataLocation?> _resolveLocation() async {
    try {
      final userDataPath = await ConfigService.getUserDataPath();
      final isCustom = (await UserDataLocationService.getCustomPath()) != null;
      return ResetUserDataLocation(
        path: userDataPath,
        isCustom: isCustom,
        mediaPath: await ConfigService.getMediaPath(),
        logFilePath: await ConfigService.getLogFilePath(),
        databasePath: await SqliteService.getActualDatabasePath(),
      );
    } catch (e) {
      _log.w('ResetService: could not resolve the user-data location: $e');
      return null;
    }
  }

  /// Deletes `<name><suffix>` if it exists. A missing file is not a failure.
  static Future<void> _deleteByName(String name, String suffix) async {
    final file = File('$name$suffix');
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      throw StateError('could not delete ${file.path}: $e');
    }
  }

  /// Deletes the directory at [dirPath] recursively if it exists. Only ever
  /// called on directories the app created; the user-data folder itself is
  /// never the argument
  /// (SPEC-0021 REQ "What A Reset Removes").
  static Future<void> _deleteDirectoryByName(String dirPath) async {
    final dir = Directory(dirPath);
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      throw StateError('could not delete ${dir.path}: $e');
    }
  }
}
