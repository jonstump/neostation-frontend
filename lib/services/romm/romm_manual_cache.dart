import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/romm_manual.dart';
import '../../models/romm_rom.dart';
import '../logger_service.dart';
import '../romm_service.dart';

/// Where a downloaded manual lives, and how it gets there.
///
/// Manuals share the media cache root with a game's covers and videos, under
/// `manuals/<romId>.<ext>` (ADR-0017): same lifecycle as the rest of a game's
/// media, no new storage location, no schema change. Every entry point takes
/// the media root as a plain path so this stays a service — it never reaches
/// for a provider or a datasource.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
class RommManualCache {
  static final _log = LoggerService.instance;

  /// Folder name under the media cache root.
  static const String folder = 'manuals';

  const RommManualCache._();

  /// The directory manuals are cached in.
  static String directoryFor(String mediaRoot) => p.join(mediaRoot, folder);

  /// Absolute path a manual with [extension] is cached at.
  static String pathFor({
    required String mediaRoot,
    required int romId,
    required String extension,
  }) => p.join(directoryFor(mediaRoot), '$romId.$extension');

  /// The cached file for [romId], or null when nothing is cached.
  ///
  /// Looks for every accepted extension rather than being told which one, so a
  /// manual can be opened offline — before any detail fetch has said what its
  /// type is. This is the check that keeps a second open off the network.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
  static Future<String?> cachedPathFor({
    required String mediaRoot,
    required int romId,
  }) async {
    for (final ext in RommManual.supportedExtensions) {
      final candidate = pathFor(
        mediaRoot: mediaRoot,
        romId: romId,
        extension: ext,
      );
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// Resolves [rom]'s manual to a local file, downloading it only when needed.
  ///
  /// With [refresh] false (the default) an existing cache entry is returned
  /// untouched and **no request is made** — the "second open" scenario. With
  /// [refresh] true the file is re-downloaded and replaces what was there,
  /// which is what the "Refresh" action runs.
  ///
  /// Throws [RommException] (including [RommCancelledException]) on failure;
  /// the caller turns that into the localized message.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
  static Future<String> ensure({
    required RommService service,
    required RommRom rom,
    required String mediaRoot,
    bool refresh = false,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (!refresh) {
      final cached = await cachedPathFor(mediaRoot: mediaRoot, romId: rom.id);
      if (cached != null) {
        _log.d('RomM manual cache hit: rom=${rom.id} path=$cached');
        return cached;
      }
    }

    final manual = rom.manual;
    if (manual == null) {
      throw RommException('No manual for rom ${rom.id}');
    }

    final dest = pathFor(
      mediaRoot: mediaRoot,
      romId: rom.id,
      extension: manual.extension,
    );
    await service.downloadManual(
      rom,
      destFilePath: dest,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );

    // A refresh can change the type (a `.txt` replaced by a `.pdf`), which
    // would otherwise leave the old file behind for `cachedPathFor` to find
    // first. Drop every sibling that is not the one just written.
    await _dropStaleSiblings(mediaRoot: mediaRoot, romId: rom.id, keep: dest);
    _log.i('RomM manual cached: rom=${rom.id} path=$dest');
    return dest;
  }

  /// Deletes every cached manual for [romId] whose path is not [keep].
  static Future<void> _dropStaleSiblings({
    required String mediaRoot,
    required int romId,
    required String keep,
  }) async {
    for (final ext in RommManual.supportedExtensions) {
      final other = pathFor(mediaRoot: mediaRoot, romId: romId, extension: ext);
      if (other == keep) continue;
      final file = File(other);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (e) {
          _log.w('RomM manual cache: could not drop $other: $e');
        }
      }
    }
  }
}
