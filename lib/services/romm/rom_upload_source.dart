import 'dart:io';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart';

import '../retroachievements_hash_service.dart';
import '../saf_directory_service.dart';

/// Why a ROM path was refused as an upload source before any byte was read.
///
/// A refusal is not an I/O failure: the file may be perfectly readable, it is
/// just not something RomM's chunked session can take as one ROM. The bulk
/// upload lists these as "skipped, with a reason" rather than as failures.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source"
enum RomUploadRefusal {
  /// A directory or a playlist (`.m3u`): a game made of several files. RomM's
  /// session uploads exactly one file, and ADR-0014 leaves multi-file games
  /// out of this version.
  multiFile,

  /// A disc image or its container (`.cue`, `.chd`, `.gdi`, …): the file on
  /// disk is one member of a disc set, or a format RomM would have to unpack.
  discContainer,

  /// The path does not resolve to a file.
  missing,

  /// The file has no bytes, or its size could not be read (a SAF document
  /// whose provider answered nothing). A zero-chunk session is not something
  /// the server accepts.
  empty,
}

/// Raised by [RomUploadSource.open] for a path it will not upload.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source"
class RomUploadRefusedException implements Exception {
  final String romPath;
  final RomUploadRefusal reason;

  /// The system folder the ROM lives in, when the caller knew it — context
  /// for the log line, not for the decision.
  final String? systemFolder;

  RomUploadRefusedException(this.romPath, this.reason, {this.systemFolder});

  @override
  String toString() =>
      'RomUploadRefusedException(${reason.name}): path=$romPath'
      '${systemFolder == null ? '' : ' system=$systemFolder'}';
}

/// Reads `length` bytes of the file at `path` starting at `offset`. Returns
/// fewer bytes only at the end of the file.
typedef RomRangeReader =
    Future<Uint8List> Function(String path, int offset, int length);

/// The file's total size in bytes.
typedef RomSizeReader = Future<int> Function(String path);

/// Whether the path names a directory.
typedef RomDirectoryProbe = Future<bool> Function(String path);

/// The I/O behind a [RomUploadSource], bundled so a test can stand in a fake
/// for all of it.
///
/// The defaults are the real thing and run off the main isolate; a source
/// opened with injected readers runs them inline instead, since a closure
/// cannot cross an isolate boundary.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source"
class RomUploadReaders {
  final RomSizeReader sizeOf;
  final RomRangeReader readRange;
  final RomDirectoryProbe isDirectory;

  const RomUploadReaders({
    required this.sizeOf,
    required this.readRange,
    required this.isDirectory,
  });
}

/// One local ROM file opened for a chunked upload: its total size and a
/// `read(offset, length)` that returns exactly that range and nothing more.
///
/// Two backings, chosen by the path's scheme. A `content://` document (every
/// ROM on Android, see CLAUDE.md) is read through
/// [SafDirectoryService.readRange], one method-channel round trip per chunk;
/// anything else through a `dart:io` [RandomAccessFile] positioned at the
/// offset. Both run in a background isolate that holds the root isolate token,
/// which is what lets the SAF method channel answer off the main isolate —
/// the same arrangement `RomFingerprintService.computeInBackground` uses.
///
/// The whole file is never in memory: the largest read this object ever makes
/// is one [chunkSize], and a read is issued only when the session client asks
/// for that chunk.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source",
// REQ "Concurrency Safety"
class RomUploadSource {
  /// Bytes per chunk — 10 MiB, RomM's own web client's figure, which the
  /// server has been tuned against. The server recomputes the size as
  /// `ceil(total / chunks)` and rejects any chunk but the last that differs,
  /// so this is also the arithmetic the session headers must be derived from.
  static const int chunkSize = 10 * 1024 * 1024;

  /// The path this source reads — a plain path or a `content://` URI.
  final String path;

  /// The system folder the ROM lives in, when known. Carried for the log.
  final String? systemFolder;

  /// Total bytes in the file.
  final int size;

  final RomUploadReaders? _readers;

  RomUploadSource._(
    this.path,
    this.size, {
    required this.systemFolder,
    required RomUploadReaders? readers,
  }) : _readers = readers;

  /// Opens [romPath] for upload, or throws [RomUploadRefusedException] with
  /// the reason it cannot be uploaded as one file.
  ///
  /// The refusals come first and cost no I/O beyond a directory probe: a
  /// playlist or a directory is [RomUploadRefusal.multiFile], a disc container
  /// (by `RetroAchievementsHashService.isDiscContainer`'s list) is
  /// [RomUploadRefusal.discContainer]. Then the size is read — a missing plain
  /// file is [RomUploadRefusal.missing], a size of zero is
  /// [RomUploadRefusal.empty].
  ///
  /// [readers] is the test seam: when given, every read runs inline through
  /// it and no isolate is spawned.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source"
  static Future<RomUploadSource> open(
    String romPath, {
    String? systemFolder,
    RomUploadReaders? readers,
  }) async {
    final io = readers ?? _defaultReaders;

    if (isPlaylist(romPath) || await io.isDirectory(romPath)) {
      throw RomUploadRefusedException(
        romPath,
        RomUploadRefusal.multiFile,
        systemFolder: systemFolder,
      );
    }
    if (RetroAchievementsHashService.isDiscContainer(romPath)) {
      throw RomUploadRefusedException(
        romPath,
        RomUploadRefusal.discContainer,
        systemFolder: systemFolder,
      );
    }

    final int size;
    try {
      size = await io.sizeOf(romPath);
    } on FileSystemException {
      throw RomUploadRefusedException(
        romPath,
        RomUploadRefusal.missing,
        systemFolder: systemFolder,
      );
    }
    if (size <= 0) {
      throw RomUploadRefusedException(
        romPath,
        RomUploadRefusal.empty,
        systemFolder: systemFolder,
      );
    }
    return RomUploadSource._(
      romPath,
      size,
      systemFolder: systemFolder,
      readers: readers,
    );
  }

  /// Whether [romPath] is a playlist standing in for several disc files.
  /// `.m3u` is also on the disc-container list, but it is refused as
  /// multi-file first because that is the more useful reason to show.
  static bool isPlaylist(String romPath) =>
      romPath.toLowerCase().endsWith('.m3u');

  /// How many chunks of [chunkSize] the session needs: `ceil(size / chunkSize)`,
  /// the value the `x-upload-total-chunks` header carries.
  int get chunkCount => (size + chunkSize - 1) ~/ chunkSize;

  /// Byte offset of chunk [index].
  int chunkOffset(int index) {
    _checkIndex(index);
    return index * chunkSize;
  }

  /// Length of chunk [index]: [chunkSize] for every chunk but the last, which
  /// is the remainder (or a full chunk when the size divides evenly).
  int chunkLength(int index) {
    _checkIndex(index);
    final remaining = size - index * chunkSize;
    return remaining < chunkSize ? remaining : chunkSize;
  }

  /// Reads chunk [index] — exactly [chunkLength] bytes from [chunkOffset].
  Future<Uint8List> readChunk(int index) =>
      read(chunkOffset(index), chunkLength(index));

  /// Reads [length] bytes from [offset], off the main isolate.
  ///
  /// Throws [FileSystemException] when the backing file returned fewer bytes
  /// than asked for inside the file (a SAF provider that stopped answering,
  /// a file truncated under us) — the session client turns that into a
  /// failed chunk rather than sending a short one the server would reject.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Concurrency Safety"
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > size) {
      throw RangeError(
        'read($offset, $length) is outside the $size-byte file $path',
      );
    }
    if (length == 0) return Uint8List(0);

    final readers = _readers;
    final Uint8List bytes;
    if (readers != null) {
      bytes = await readers.readRange(path, offset, length);
    } else {
      bytes = await compute(_readInIsolate, <String, Object?>{
        'path': path,
        'offset': offset,
        'length': length,
        // SAF reads go through a method channel, which a bare isolate cannot
        // reach; the token is what makes content:// URIs work off the main
        // isolate.
        'token': RootIsolateToken.instance,
      });
    }
    if (bytes.length != length) {
      throw FileSystemException(
        'short read: wanted $length bytes at $offset, got ${bytes.length}',
        path,
      );
    }
    return bytes;
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, this, 'chunk', null, chunkCount);
    }
  }

  @override
  String toString() =>
      'RomUploadSource(path=$path size=$size chunks=$chunkCount)';

  // ── Default (real) I/O ────────────────────────────────────────────────────

  static bool _isSafUri(String path) => path.startsWith('content://');

  /// The production readers: SAF for `content://`, `dart:io` for the rest.
  /// Exposed so a test can drive the real desktop backing inline.
  @visibleForTesting
  static const RomUploadReaders defaultReaders = _defaultReaders;

  static const RomUploadReaders _defaultReaders = RomUploadReaders(
    sizeOf: _sizeOf,
    readRange: _readRange,
    isDirectory: _isDirectory,
  );

  static Future<int> _sizeOf(String path) async {
    if (_isSafUri(path)) {
      // Answers 0 for a document it cannot stat; `open` reads that as empty.
      return SafDirectoryService.getFileSize(path);
    }
    return File(path).length();
  }

  static Future<bool> _isDirectory(String path) async {
    if (_isSafUri(path)) {
      // A SAF *tree* URI names a folder; a document URI names a file. The
      // ROM scan only ever records document URIs for games, so this is a
      // guard against a caller handing over a folder, not a stat.
      return !path.contains('/document/');
    }
    return FileSystemEntity.isDirectory(path);
  }

  static Future<Uint8List> _readRange(
    String path,
    int offset,
    int length,
  ) async {
    if (_isSafUri(path)) {
      final bytes = await SafDirectoryService.readRange(path, offset, length);
      return bytes ?? Uint8List(0);
    }
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  /// Isolate entry: initialises the platform messenger with the root token so
  /// the SAF method channel answers here, then does the read.
  static Future<Uint8List> _readInIsolate(Map<String, Object?> params) async {
    final token = params['token'] as RootIsolateToken?;
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }
    return _readRange(
      params['path'] as String,
      params['offset'] as int,
      params['length'] as int,
    );
  }
}
