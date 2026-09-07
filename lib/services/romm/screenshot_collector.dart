import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/game_model.dart';
import '../../models/retroarch_config_model.dart';
import '../../repositories/romm_screenshot_map_repository.dart';
import '../../utils/rom_tree.dart';
import '../logger_service.dart';
import '../retroarch_config_service.dart';

/// One capture the collector decided is new for this session.
///
/// Metadata only — the collector never opens a file, so nothing here comes
/// from the bytes.
class CollectedScreenshot {
  /// Absolute path on disk, ready for the upload.
  final String path;

  /// Base name, which is also the ledger key and the name RomM files it under.
  final String fileName;

  /// Size in bytes, as `stat` reported it.
  final int sizeBytes;

  /// Last-modified timestamp, used only for ordering (oldest first).
  final DateTime modifiedAt;

  const CollectedScreenshot({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  @override
  String toString() =>
      'CollectedScreenshot($fileName, $sizeBytes bytes, $modifiedAt)';
}

/// Finds the RetroArch captures a just-finished play session left behind.
///
/// RetroArch names a capture `<content basename>-<date>-<time>.png` in its
/// `screenshot_directory` (plus a per-content subdirectory when
/// `sort_screenshots_by_content_enable` is on). Two filters bound the listing
/// of what can be a very large folder: the name must start with the game's ROM
/// stem, and the file's modification time must fall inside the session window.
/// A third filter — the upload ledger — removes what this device already sent.
///
/// The listing and the filtering run in a background isolate: a screenshot
/// folder on a handheld's SD card can hold thousands of entries and each entry
/// costs a `stat`. File **contents** are never read, here or in the isolate.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
class ScreenshotCollector {
  static final _log = LoggerService.instance;

  /// Extensions RetroArch can write a capture as. `.png` is what it uses by
  /// default; the rest are accepted so a user who changed the format is not
  /// silently unsupported.
  static const Set<String> imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'bmp',
    'webp',
  };

  /// How far before the recorded session start a capture may be stamped and
  /// still count as this session's.
  ///
  /// The session start is taken when NeoStation hands off to the emulator,
  /// which is *after* RetroArch's own clock starts, and the two devices'
  /// filesystems round mtimes differently (FAT32 to two seconds). Five seconds
  /// absorbs both without widening the window enough to pick up the previous
  /// session's last shot.
  static const Duration startTolerance = Duration(seconds: 5);

  /// Resolves the RetroArch configuration. Injectable so tests can describe a
  /// screenshot directory without a `retroarch.cfg` on the machine.
  final Future<RetroArchConfig> Function() _loadConfig;

  /// Reads the upload ledger for a ROM path. Injectable for the same reason.
  final Future<Map<String, int?>> Function(String romPath) _loadLedger;

  ScreenshotCollector({
    @visibleForTesting Future<RetroArchConfig> Function()? loadConfig,
    @visibleForTesting
    Future<Map<String, int?>> Function(String romPath)? loadLedger,
  }) : _loadConfig = loadConfig ?? RetroArchConfigService().getMergedConfig,
       _loadLedger = loadLedger ?? RommScreenshotMapRepository.recordedFor;

  /// Captures for [game] taken during the session that began at
  /// [sessionStart], oldest first.
  ///
  /// Returns an empty list — never throws — when RetroArch has no configured
  /// screenshot directory, when the directory does not exist, or when the game
  /// has no ROM path to key the ledger on. Each of those logs one line naming
  /// the path, because a silently empty result is indistinguishable from
  /// "nothing was captured".
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
  Future<List<CollectedScreenshot>> collect(
    GameModel game,
    DateTime sessionStart,
  ) async {
    final romPath = game.romPath ?? '';
    final stem = romStemFor(game);
    if (stem.isEmpty) {
      _log.i('Screenshot collect skipped: game="${game.romname}" has no stem');
      return const [];
    }

    final RetroArchConfig config;
    try {
      config = await _loadConfig();
    } catch (e) {
      _log.w('Screenshot collect skipped: RetroArch config unreadable: $e');
      return const [];
    }

    final directory = config.screenshotDirectory?.trim() ?? '';
    if (directory.isEmpty) {
      _log.i(
        'Screenshot collect skipped: no screenshot_directory in '
        'cfg="${config.configPath}"',
      );
      return const [];
    }

    final directories = <String>[directory];
    if (config.sortScreenshotsByContent) {
      final subdirectory = contentSubdirectoryFor(game);
      if (subdirectory != null && subdirectory.isNotEmpty) {
        directories.add('$directory${Platform.pathSeparator}$subdirectory');
      }
    }

    final ledger = romPath.isEmpty
        ? const <String, int?>{}
        : await _loadLedger(romPath);

    final rows = await compute(_scanForScreenshots, {
      'directories': directories,
      'stem': stem.toLowerCase(),
      'cutoffMs': sessionStart.subtract(startTolerance).millisecondsSinceEpoch,
      'extensions': imageExtensions.toList(),
      // Encoded as name -> size, with -1 standing in for the null size of a
      // skipped row; a Map<String, int?> crosses the isolate boundary fine but
      // the explicit sentinel keeps the isolate side free of nullable maths.
      'ledger': {for (final e in ledger.entries) e.key: e.value ?? -1},
    });

    if (rows.isEmpty) {
      _log.i(
        'Screenshot collect: none new for stem="$stem" in '
        'dirs="${directories.join(Platform.pathSeparator == '/' ? ':' : ';')}"',
      );
      return const [];
    }

    final out = [
      for (final row in rows)
        CollectedScreenshot(
          path: row['path'] as String,
          fileName: row['fileName'] as String,
          sizeBytes: row['sizeBytes'] as int,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(
            row['modifiedMs'] as int,
          ),
        ),
    ];
    _log.i(
      'Screenshot collect: found=${out.length} stem="$stem" '
      'ledger=${ledger.length}',
    );
    return out;
  }

  /// The prefix RetroArch names this game's captures with: the ROM file's base
  /// name without its extension.
  ///
  /// Derived from [GameModel.romPath] where there is one, because that is the
  /// path handed to the emulator. On Android that path is a SAF `content://`
  /// URI whose real path lives URL-encoded in the document id
  /// (`…/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip`), so it goes through
  /// [normalizeRomPath] first — splitting the raw URI on `/` would otherwise
  /// yield the whole encoded id as the "file name". Falls back to
  /// [GameModel.romname], which carries the same name for a game with no path.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
  @visibleForTesting
  static String romStemFor(GameModel game) {
    final path = game.romPath;
    final source = (path != null && path.isNotEmpty)
        ? _baseName(normalizeRomPath(path))
        : game.romname;
    return _stripExtension(source.trim());
  }

  /// The per-content subdirectory RetroArch sorts captures into when
  /// `sort_screenshots_by_content_enable` is on: the name of the directory the
  /// content itself sits in. Null when the path has no parent directory.
  @visibleForTesting
  static String? contentSubdirectoryFor(GameModel game) {
    final path = game.romPath;
    if (path == null || path.isEmpty) return null;
    final normalized = normalizeRomPath(path);
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return null;
    final parent = normalized.substring(0, lastSlash);
    final parentSlash = parent.lastIndexOf('/');
    final name = parentSlash == -1 ? parent : parent.substring(parentSlash + 1);
    return name.isEmpty ? null : name;
  }

  static String _baseName(String normalizedPath) {
    final lastSlash = normalizedPath.lastIndexOf('/');
    return lastSlash == -1
        ? normalizedPath
        : normalizedPath.substring(lastSlash + 1);
  }

  static String _stripExtension(String name) {
    final lastDot = name.lastIndexOf('.');
    return lastDot > 0 ? name.substring(0, lastDot) : name;
  }
}

/// Isolate body for [ScreenshotCollector.collect].
///
/// Top-level and primitive-in/primitive-out because [compute] hands it to a
/// fresh isolate. Lists each directory, keeps the entries that pass every
/// filter, and returns metadata only — no file is opened.
// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
List<Map<String, Object>> _scanForScreenshots(Map<String, Object?> args) {
  final directories = (args['directories'] as List).cast<String>();
  final stem = args['stem'] as String;
  final cutoffMs = args['cutoffMs'] as int;
  final extensions = (args['extensions'] as List).cast<String>().toSet();
  final ledger = (args['ledger'] as Map).map(
    (k, v) => MapEntry(k.toString(), v as int),
  );

  final found = <String, Map<String, Object>>{};
  for (final directoryPath in directories) {
    final directory = Directory(directoryPath);
    if (!directory.existsSync()) continue;

    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      // An unreadable directory is not a failure of the session; the summary
      // line on the caller's side reports the empty result.
      continue;
    }

    for (final entry in entries) {
      if (entry is! File) continue;
      final fileName = entry.path.split(Platform.pathSeparator).last;
      final lowerName = fileName.toLowerCase();
      if (!lowerName.startsWith(stem)) continue;

      final lastDot = lowerName.lastIndexOf('.');
      if (lastDot <= 0) continue;
      if (!extensions.contains(lowerName.substring(lastDot + 1))) continue;

      final FileStat stat;
      try {
        stat = entry.statSync();
      } on FileSystemException {
        continue;
      }
      if (stat.modified.millisecondsSinceEpoch < cutoffMs) continue;

      // A ledger row with the sentinel -1 size is a 413 skip: never offer that
      // name again, whatever it now weighs.
      final recorded = ledger[fileName];
      if (recorded != null && (recorded < 0 || recorded == stat.size)) continue;

      // Keyed by name so the content subdirectory cannot yield a duplicate of
      // a file already found in the root.
      found[fileName] = {
        'path': entry.path,
        'fileName': fileName,
        'sizeBytes': stat.size,
        'modifiedMs': stat.modified.millisecondsSinceEpoch,
      };
    }
  }

  final rows = found.values.toList()
    ..sort(
      (a, b) => (a['modifiedMs'] as int).compareTo(b['modifiedMs'] as int),
    );
  return rows;
}
