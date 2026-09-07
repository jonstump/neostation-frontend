import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../models/romm_firmware.dart';
import '../../models/romm_firmware_row.dart';
import '../../utils/optimized_md5_utils.dart';
import '../logger_service.dart';
import '../romm_service.dart';

/// How one firmware download ended.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
enum RommFirmwareDownloadResult {
  /// The bytes are in the destination under their final name.
  downloaded,

  /// The user asked to stop; the `.part` file is gone.
  cancelled,

  /// The row is flagged `missing_from_fs`: nothing was requested.
  serverMissing,

  /// The credential holds no `firmware.read` scope (HTTP 403).
  scopeDenied,

  /// Anything else — see the log line this service wrote.
  failed,
}

/// The local half of the firmware panel: what the destination already holds,
/// whether it is the same file the server holds, and the guarded download.
///
/// Deliberately free of providers, datasources and `BuildContext`: it takes a
/// configured [RommService] and a real destination directory, and it answers in
/// plain models the panel formats. The presence check never opens a file — a
/// `stat` for name and size is the whole test, per ADR-0012 — and the md5
/// comparison runs on a background isolate so a slow card cannot stall a frame.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
class RommFirmwareService {
  const RommFirmwareService._();

  static final _log = LoggerService.instance;

  /// The path [firmware] occupies inside [destDir].
  static String destPathFor(String destDir, RommFirmware firmware) =>
      path.join(destDir, firmware.fileName);

  /// The local state of [firmware] in [destDir].
  ///
  /// `stat` only: a `missing_from_fs` row is reported as such whatever is on
  /// disk (the server cannot serve it either way), a null [destDir] means the
  /// question cannot be asked yet, and otherwise the entry must be a file whose
  /// size equals the server's. A server that reports size 0 — an importer that
  /// never filled the column — degrades to a name-only check rather than
  /// declaring every local copy wrong.
  ///
  /// Contents are never read here; that is what "Verify" is for.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  static Future<RommFirmwareLocalState> localStateOf(
    RommFirmware firmware,
    String? destDir,
  ) async {
    if (firmware.missingFromFs) return RommFirmwareLocalState.serverMissing;
    if (destDir == null || destDir.trim().isEmpty) {
      return RommFirmwareLocalState.unknownDestination;
    }
    if (firmware.fileName.trim().isEmpty) {
      return RommFirmwareLocalState.missing;
    }
    try {
      final stat = await FileStat.stat(destPathFor(destDir, firmware));
      if (stat.type != FileSystemEntityType.file) {
        return RommFirmwareLocalState.missing;
      }
      if (firmware.fileSizeBytes <= 0) return RommFirmwareLocalState.present;
      return stat.size == firmware.fileSizeBytes
          ? RommFirmwareLocalState.present
          : RommFirmwareLocalState.missing;
    } catch (e) {
      _log.w(
        'RomM firmware presence check failed: file=${firmware.fileName} '
        'dir=$destDir cause=$e',
      );
      return RommFirmwareLocalState.missing;
    }
  }

  /// One row per listed file, in listing order, each carrying its local state.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  static Future<List<RommFirmwareRow>> describe(
    List<RommFirmware> firmware,
    String? destDir,
  ) async {
    final rows = <RommFirmwareRow>[];
    for (final f in firmware) {
      rows.add(
        RommFirmwareRow(firmware: f, state: await localStateOf(f, destDir)),
      );
    }
    return rows;
  }

  /// Compares the local file's md5 with the server's, on a background isolate.
  ///
  /// Returns [RommFirmwareVerifyState.unchecked] when the server published no
  /// md5 to compare against (the panel does not offer the action then), and
  /// [RommFirmwareVerifyState.unreadable] when the local file could not be
  /// read at all.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  static Future<RommFirmwareVerifyState> verify(
    RommFirmware firmware,
    String destDir,
  ) async {
    final expected = firmware.md5;
    if (expected == null || expected.isEmpty) {
      return RommFirmwareVerifyState.unchecked;
    }
    final filePath = destPathFor(destDir, firmware);
    // Off the UI isolate: the panel stays responsive while a multi-megabyte
    // BIOS image is streamed through the digest.
    final actual = await compute(_md5Isolate, filePath);
    if (actual == null) {
      _log.w('RomM firmware verify unreadable: file=${firmware.fileName}');
      return RommFirmwareVerifyState.unreadable;
    }
    final same = actual.toLowerCase() == expected.toLowerCase();
    _log.i(
      'RomM firmware verify: file=${firmware.fileName} '
      'expected=$expected actual=$actual match=$same',
    );
    return same
        ? RommFirmwareVerifyState.match
        : RommFirmwareVerifyState.mismatch;
  }

  /// Streams the md5 of [filePath] without holding the file in memory, or null
  /// when it cannot be read.
  ///
  /// Chunked through [OptimizedMd5Utils.readChunked] — the same SAF-aware
  /// reader the ROM fingerprint pass uses — so a BIOS folder that lives behind
  /// a content URI hashes the same way an ordinary path does.
  @visibleForTesting
  static Future<String?> md5OfFile(String filePath) async {
    try {
      final sink = _DigestSink();
      final input = crypto.md5.startChunkedConversion(sink);
      await OptimizedMd5Utils.readChunked(filePath, input.add);
      input.close();
      return sink.digest.toString();
    } catch (e) {
      _log.w('RomM firmware md5 failed ($filePath): $e');
      return null;
    }
  }

  static Future<String?> _md5Isolate(String filePath) => md5OfFile(filePath);

  /// Downloads [firmware] into [destDir] through [service].
  ///
  /// Refuses a row the server flagged `missing_from_fs` before any request is
  /// sent: RomM lists the record but no longer holds the bytes, so the call
  /// could only fail — ADR-0012's "listed, but not downloadable" is enforced
  /// here as well as in the row's action gating.
  ///
  /// Every outcome is a value, never an exception: the panel reports each file
  /// in the notification and moves on to the next one.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  static Future<RommFirmwareDownloadResult> download(
    RommFirmware firmware, {
    required RommService service,
    required String destDir,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (firmware.missingFromFs) {
      _log.w(
        'RomM firmware download refused: file=${firmware.fileName} '
        'reason=missing_from_fs',
      );
      return RommFirmwareDownloadResult.serverMissing;
    }
    try {
      await service.downloadFirmware(
        firmware,
        destFilePath: destPathFor(destDir, firmware),
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
      return RommFirmwareDownloadResult.downloaded;
    } on RommCancelledException {
      return RommFirmwareDownloadResult.cancelled;
    } on RommException catch (e) {
      // The service already logged the failure once, naming file and cause.
      return e.kind == RommErrorKind.scopeDenied
          ? RommFirmwareDownloadResult.scopeDenied
          : RommFirmwareDownloadResult.failed;
    } catch (e) {
      _log.w(
        'RomM firmware download failed: file=${firmware.fileName} cause=$e',
      );
      return RommFirmwareDownloadResult.failed;
    }
  }
}

/// Collects the single digest a chunked conversion emits on close.
class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest digest;

  @override
  void add(crypto.Digest data) => digest = data;

  @override
  void close() {}
}
