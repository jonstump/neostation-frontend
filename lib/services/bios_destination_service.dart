import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/system_model.dart';
import '../providers/romm_provider.dart' show RommProvider;
import '../repositories/config_repository.dart';
import 'logger_service.dart';
import 'retroarch_config_service.dart';
import 'user_data_location_service.dart';

/// Which candidate supplied a resolved BIOS destination.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
enum BiosDestinationSource {
  /// RetroArch's `system_directory`, discovered from `retroarch.cfg`.
  retroArch,

  /// `user_config.bios_directory` — the folder the user picked once.
  configured,
}

/// A resolved BIOS destination: the directory, and which candidate won.
///
/// The source matters to the UI, not just to the log: ADR-0012 §2 has the
/// picker offered only when RetroArch supplies nothing, so a panel that knows
/// RetroArch won can leave the picker out rather than offering a choice
/// [BiosDestinationService.resolve] would discard on the next open.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
class BiosDestination {
  /// The normalized, existing, writable directory firmware lands in.
  final String directory;

  /// Which of the two candidates this directory came from.
  final BiosDestinationSource source;

  const BiosDestination({required this.directory, required this.source});

  @override
  String toString() => 'BiosDestination($directory, ${source.name})';
}

/// Decides where a system's BIOS/firmware files belong on this device.
///
/// Precedence, per ADR-0012:
///
/// 1. RetroArch's `system_directory`, when `retroarch.cfg` names one and that
///    directory exists and is writable. RetroArch is the one emulator whose
///    BIOS location the app can discover, and if it is configured the user
///    almost certainly wants the files there.
/// 2. `user_config.bios_directory` — the folder the user picked once, through
///    the native picker on desktop or a SAF tree on Android.
/// 3. Nothing. The caller then offers the picker and persists the choice with
///    [setBiosDirectory].
///
/// [system] is not consulted yet; it is part of the contract so a later
/// per-emulator rule (a `bios_dir` in the emulator JSON, say) lands here rather
/// than in the panel.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
class BiosDestinationService {
  /// Dependencies are injectable so the precedence can be tested without a
  /// RetroArch install, a database or a filesystem; each defaults to the real
  /// collaborator.
  BiosDestinationService({
    Future<String?> Function()? retroArchSystemDirectory,
    Future<String?> Function()? storedBiosDirectory,
    Future<void> Function(String directory)? persistBiosDirectory,
    Future<bool> Function(String directory)? directoryExists,
    Future<bool> Function(String directory)? directoryIsWritable,
  }) : _retroArchSystemDirectory =
           retroArchSystemDirectory ?? _defaultRetroArchSystemDirectory,
       _storedBiosDirectory =
           storedBiosDirectory ?? ConfigRepository.getBiosDirectory,
       _persistBiosDirectory =
           persistBiosDirectory ?? ConfigRepository.setBiosDirectory,
       _directoryExists = directoryExists ?? _defaultDirectoryExists,
       _directoryIsWritable =
           directoryIsWritable ?? _defaultDirectoryIsWritable;

  static final _log = LoggerService.instance;

  /// Shared instance for production callers.
  static final BiosDestinationService instance = BiosDestinationService();

  final Future<String?> Function() _retroArchSystemDirectory;
  final Future<String?> Function() _storedBiosDirectory;
  final Future<void> Function(String directory) _persistBiosDirectory;
  final Future<bool> Function(String directory) _directoryExists;
  final Future<bool> Function(String directory) _directoryIsWritable;

  /// Returns the directory firmware for [system] should be written to, or null
  /// when the device has neither a RetroArch system directory nor a chosen
  /// BIOS folder.
  ///
  /// Convenience wrapper over [resolveDestination] for callers that only need
  /// the path.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  Future<String?> resolve(SystemModel system) async =>
      (await resolveDestination(system))?.directory;

  /// The destination firmware for [system] should be written to and which
  /// candidate supplied it, or null when neither is usable.
  ///
  /// Both candidates are translated out of the Android SAF form, confirmed to
  /// exist, and then probed for writability with the same probe-file
  /// round-trip the ROM download path uses ([RommProvider.dirIfWritable]) — so
  /// a non-null answer is a directory the download can actually write into,
  /// not merely one that is there. That distinction is the whole point on
  /// Android without All Files Access, where an existing directory is readable
  /// and unwritable and the failure would otherwise surface only at the first
  /// byte written.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  Future<BiosDestination?> resolveDestination(SystemModel system) async {
    final retroArch = await _usableDirectory(await _retroArchSystemDirectory());
    if (retroArch != null) {
      _log.i(
        'BIOS destination: source=retroarch system=${system.folderName} '
        'dir=$retroArch',
      );
      return BiosDestination(
        directory: retroArch,
        source: BiosDestinationSource.retroArch,
      );
    }

    final configured = await _usableDirectory(await _storedBiosDirectory());
    if (configured != null) {
      _log.i(
        'BIOS destination: source=config system=${system.folderName} '
        'dir=$configured',
      );
      return BiosDestination(
        directory: configured,
        source: BiosDestinationSource.configured,
      );
    }

    _log.i(
      'BIOS destination: source=none system=${system.folderName} '
      '(no RetroArch system_directory, no bios_directory)',
    );
    return null;
  }

  /// Persists the folder the user just picked and returns the real path it
  /// resolves to, or null when an Android SAF tree could not be translated
  /// onto a filesystem path (nothing is stored in that case).
  ///
  /// The raw picker result is what gets stored — translation happens on every
  /// read, so a device that later gains All Files Access resolves the same
  /// stored URI to a usable path without the user re-picking.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  Future<String?> setBiosDirectory(String picked) async {
    final trimmed = picked.trim();
    if (trimmed.isEmpty) {
      _log.w('BIOS destination: refused an empty folder choice');
      return null;
    }
    final real = realPathFor(trimmed);
    if (real == null) {
      _log.w('BIOS destination: cannot map picked folder to a path: $trimmed');
      return null;
    }
    await _persistBiosDirectory(trimmed);
    _log.i('BIOS destination: stored=$trimmed real=$real');
    return real;
  }

  /// The filesystem path [stored] denotes.
  ///
  /// Plain paths pass through. Android's folder picker hands back SAF
  /// `content://` tree URIs even for ordinary directories, so those go through
  /// the shared [UserDataLocationService.safUriToRealPath] — the same
  /// translation the ROM download uses. Returns null for a URI it cannot map.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
  static String? realPathFor(String stored) {
    final trimmed = stored.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('content://')) return trimmed;
    return UserDataLocationService.safUriToRealPath(trimmed);
  }

  /// Normalizes a candidate to an existing, writable directory, or null.
  ///
  /// Existence is checked before writability on purpose: the shared probe
  /// creates the directory it is handed, and a BIOS folder that has since been
  /// deleted (or lives on an unmounted card) must fall through to the next
  /// candidate rather than be silently recreated somewhere useless.
  Future<String?> _usableDirectory(String? candidate) async {
    if (candidate == null) return null;
    final real = realPathFor(candidate);
    if (real == null) return null;
    final normalized = path.normalize(real);
    if (!await _directoryExists(normalized)) return null;
    if (!await _directoryIsWritable(normalized)) {
      _log.w(
        'BIOS destination: directory exists but is not writable: '
        '$normalized',
      );
      return null;
    }
    return normalized;
  }

  static Future<String?> _defaultRetroArchSystemDirectory() async {
    try {
      final config = await RetroArchConfigService().getMergedConfig();
      return config.systemDirectory;
    } catch (e) {
      // A missing or unparsable retroarch.cfg is an ordinary state, not a
      // failure of the firmware feature: fall through to the configured
      // folder. Logged once so a wrong destination is explainable.
      _log.w('BIOS destination: RetroArch config unavailable: $e');
      return null;
    }
  }

  static Future<bool> _defaultDirectoryExists(String directory) =>
      Directory(directory).exists();

  /// Reuses the ROM download path's probe rather than repeating it: one
  /// definition of "writable" for every RomM download, and its concurrency fix
  /// (a per-call probe filename) comes along for free.
  static Future<bool> _defaultDirectoryIsWritable(String directory) async =>
      await RommProvider.dirIfWritable(directory) != null;
}
