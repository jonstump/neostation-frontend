import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../logger_service.dart';

/// Lists one SAF directory in the `SafDirectoryService.listFiles` map shape
/// (`name`, `uri`, `isDirectory`, `size`, `lastModified`).
typedef SafMirrorListFiles =
    Future<List<Map<String, dynamic>>> Function(String uri);

/// Reads `[offset, offset + length)` of one SAF document. A null result is a
/// failed read (the platform side answers errors with null); an empty or
/// short chunk is end of file.
typedef SafMirrorReadRange =
    Future<Uint8List?> Function(String uri, int offset, int length);

/// Free bytes on the volume holding [path], or null when it cannot be
/// measured on this platform.
typedef SafMirrorFreeSpace = Future<int?> Function(String path);

/// Per-file progress: [copied] of [total] planned files done, [currentName]
/// the file about to be copied (empty once the run is over).
typedef SafMirrorProgress =
    void Function(int copied, int total, String currentName);

/// Outcome of one [SafMediaMirror.run] over a single system folder.
class SafMirrorSummary {
  /// `<mirrorRoot>/<system folder>`: the directory the importer records as
  /// the system's media root once it holds at least one file.
  final String mirrorDir;

  /// Files whose destination was missing or size-mismatched before the run.
  final int filesPlanned;

  final int filesCopied;

  /// Files whose destination already had the listing's size and were left
  /// untouched.
  final int filesSkippedUnchanged;

  /// Files that could not be read over SAF or written locally; each one is
  /// logged with its URI.
  final int filesFailed;

  final int bytesCopied;

  /// Complete (non-`.part`) files under [mirrorDir] after the run, whether
  /// copied now or by an earlier run. Zero means there is nothing to record
  /// a media root for.
  final int filesPresent;

  /// The free-space check refused the whole folder: nothing was copied.
  final bool budgetRefused;

  /// Bytes the pending copy needed (the sum of planned listing sizes).
  final int requiredBytes;

  /// Free bytes on the mirror volume at plan time; null when the platform
  /// could not measure it (the guard then lets the copy proceed).
  final int? availableBytes;

  /// `shouldStop` answered true between files; the files copied before that
  /// are complete and kept.
  final bool cancelled;

  const SafMirrorSummary({
    required this.mirrorDir,
    this.filesPlanned = 0,
    this.filesCopied = 0,
    this.filesSkippedUnchanged = 0,
    this.filesFailed = 0,
    this.bytesCopied = 0,
    this.filesPresent = 0,
    this.budgetRefused = false,
    this.requiredBytes = 0,
    this.availableBytes,
    this.cancelled = false,
  });

  @override
  String toString() =>
      'SafMirrorSummary(dir=$mirrorDir planned=$filesPlanned '
      'copied=$filesCopied skipped=$filesSkippedUnchanged '
      'failed=$filesFailed bytes=$bytesCopied present=$filesPresent '
      'budgetRefused=$budgetRefused required=$requiredBytes '
      'available=$availableBytes cancelled=$cancelled)';
}

/// One file the plan decided to copy.
class _PlannedFile {
  final String uri;
  final String name;
  final String category;
  final File destination;
  final int size;

  const _PlannedFile({
    required this.uri,
    required this.name,
    required this.category,
    required this.destination,
    required this.size,
  });
}

/// Copies a SAF system folder's mapped media category folders into
/// `<mirrorRoot>/<system folder>/<category>/` so the unchanged media
/// resolver can read them as plain files.
///
/// Pure Dart over the SAF service's read-only primitives: one listing per
/// category folder gives names and sizes, a destination whose length equals
/// the listing size is skipped, and everything else is streamed in chunks
/// into a `.part` file that is renamed into place only once complete. The
/// SAF tree is never written. Every dependency is injected so a test can
/// drive the mirror with a recording fake and a temp directory.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Media Mirror"
class SafMediaMirror {
  static final _log = LoggerService.instance;

  /// The SPEC-0002 category set: the only folders the mirror copies.
  static const List<String> mappedCategories = [
    'covers',
    '3dboxes',
    'marquees',
    'screenshots',
    'titlescreens',
    'fanart',
    'videos',
    'images',
    'thumbnails',
  ];

  /// Same chunk size as `OptimizedMd5Utils.readAllBytes`, but each chunk goes
  /// straight to the file sink instead of a byte builder, so a video never
  /// sits in memory whole.
  static const int chunkSize = 2 * 1024 * 1024;

  /// Suffix of an in-flight destination; renamed away once the copy is
  /// complete so a partial file never masquerades as a mirrored one.
  static const String partialSuffix = '.part';

  final SafMirrorListFiles listFiles;
  final SafMirrorReadRange readRange;
  final SafMirrorFreeSpace freeSpaceBytes;

  /// Absolute `<user data>/imported_media` directory every write lands under.
  final String mirrorRoot;

  final bool Function() shouldStop;
  final SafMirrorProgress? onProgress;

  SafMediaMirror({
    required this.listFiles,
    required this.readRange,
    required this.freeSpaceBytes,
    required this.mirrorRoot,
    bool Function()? shouldStop,
    this.onProgress,
  }) : shouldStop = shouldStop ?? _never;

  static bool _never() => false;

  /// The mirror directory [run] would use for [systemFolder], without
  /// touching anything.
  String mirrorDirFor(String systemFolder) =>
      path.normalize(path.join(mirrorRoot, systemFolder));

  /// Mirrors [categoryDirs] (lowercased category name → SAF folder URI, as
  /// discovery collected them) of [systemFolder]. Categories outside
  /// [mappedCategories] are ignored even if present in the map.
  Future<SafMirrorSummary> run(
    String systemFolder,
    Map<String, String> categoryDirs,
  ) async {
    final mirrorDir = mirrorDirFor(systemFolder);
    // A system folder name is SAF-provided text; it must stay a single path
    // segment or the mirror would write outside its own root.
    if (!_isSafeSegment(systemFolder) ||
        !path.isWithin(path.normalize(mirrorRoot), mirrorDir)) {
      _log.w(
        'SAF mirror: refused system folder outside the mirror root '
        'folder=$systemFolder root=$mirrorRoot',
      );
      return SafMirrorSummary(mirrorDir: mirrorDir);
    }

    // ── Plan: one listing per mapped category, size-skip against disk. ──
    final plan = <_PlannedFile>[];
    var skipped = 0;
    var failed = 0;
    final categories =
        categoryDirs.keys.where(mappedCategories.contains).toList()..sort();
    for (final category in categories) {
      final uri = categoryDirs[category]!;
      List<Map<String, dynamic>> children;
      try {
        children = await listFiles(uri);
      } catch (e) {
        // A category that cannot be listed costs only itself: nothing of it
        // can be planned, the other categories still mirror.
        // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
        _log.w(
          'SAF mirror: cannot list category folder system=$systemFolder '
          'category=$category uri=$uri error=$e',
        );
        continue;
      }
      for (final child in children) {
        if (child['isDirectory'] == true) continue;
        final name = child['name']?.toString() ?? '';
        final fileUri = child['uri']?.toString() ?? '';
        if (name.isEmpty || fileUri.isEmpty) continue;
        if (!_isSafeSegment(name)) {
          _log.w(
            'SAF mirror: skipped file with an unsafe name system=$systemFolder '
            'category=$category name=$name uri=$fileUri',
          );
          failed++;
          continue;
        }
        final size = (child['size'] as num?)?.toInt() ?? -1;
        final destination = File(path.join(mirrorDir, category, name));
        if (size >= 0 && _lengthOf(destination) == size) {
          skipped++;
          continue;
        }
        plan.add(
          _PlannedFile(
            uri: fileUri,
            name: name,
            category: category,
            destination: destination,
            size: size,
          ),
        );
      }
    }

    // ── Budget guard: pending bytes against free space, before any copy. ──
    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Storage Budget Guard"
    var requiredBytes = 0;
    for (final file in plan) {
      if (file.size > 0) requiredBytes += file.size;
    }
    int? availableBytes;
    try {
      availableBytes = await freeSpaceBytes(mirrorRoot);
    } catch (e) {
      _log.w(
        'SAF mirror: free-space query failed root=$mirrorRoot error=$e; '
        'proceeding without a budget check',
      );
    }
    if (plan.isNotEmpty &&
        availableBytes != null &&
        requiredBytes > availableBytes) {
      _log.w(
        'SAF mirror: budget refused system=$systemFolder '
        'required=$requiredBytes available=$availableBytes '
        'files=${plan.length}',
      );
      return SafMirrorSummary(
        mirrorDir: mirrorDir,
        filesPlanned: plan.length,
        filesSkippedUnchanged: skipped,
        filesFailed: failed,
        filesPresent: _countPresent(mirrorDir),
        budgetRefused: true,
        requiredBytes: requiredBytes,
        availableBytes: availableBytes,
      );
    }

    // ── Copy: stream each pending file, checking for cancel between files. ──
    var copied = 0;
    var bytesCopied = 0;
    var cancelled = false;
    for (final file in plan) {
      // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
      if (shouldStop()) {
        cancelled = true;
        _log.i(
          'SAF mirror: cancelled system=$systemFolder '
          'copied=$copied of ${plan.length}',
        );
        break;
      }
      onProgress?.call(copied, plan.length, file.name);
      try {
        bytesCopied += await _copy(file);
        copied++;
      } catch (e) {
        // One unreadable or unwritable file costs only itself.
        // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
        failed++;
        _log.w(
          'SAF mirror: file failed system=$systemFolder '
          'category=${file.category} name=${file.name} uri=${file.uri} '
          'error=$e',
        );
      }
    }
    onProgress?.call(copied, plan.length, '');

    final summary = SafMirrorSummary(
      mirrorDir: mirrorDir,
      filesPlanned: plan.length,
      filesCopied: copied,
      filesSkippedUnchanged: skipped,
      filesFailed: failed,
      bytesCopied: bytesCopied,
      filesPresent: _countPresent(mirrorDir),
      requiredBytes: requiredBytes,
      availableBytes: availableBytes,
      cancelled: cancelled,
    );
    _log.i('SAF mirror: done system=$systemFolder $summary');
    return summary;
  }

  /// Streams [file] into `<destination>.part` and renames it into place.
  /// Returns the bytes written. Throws on a failed read or write, after
  /// removing the partial file.
  Future<int> _copy(_PlannedFile file) async {
    final destination = file.destination;
    final partial = File('${destination.path}$partialSuffix');
    var written = 0;
    IOSink? sink;
    try {
      // The first chunk is read before anything is created on disk, so an
      // unreadable source leaves no empty category folder behind.
      var chunk = await readRange(file.uri, 0, chunkSize);
      if (chunk == null) {
        throw StateError('SAF read returned no data at offset 0');
      }
      await destination.parent.create(recursive: true);
      sink = partial.openWrite();
      var offset = 0;
      while (chunk!.isNotEmpty) {
        sink.add(chunk);
        written += chunk.length;
        offset += chunk.length;
        if (chunk.length < chunkSize) break;
        chunk = await readRange(file.uri, offset, chunkSize);
        if (chunk == null) {
          throw StateError('SAF read returned no data at offset $offset');
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (file.size >= 0 && written != file.size) {
        // The source changed under us; the copy is whatever was readable and
        // the next run's size check will redo it.
        _log.d(
          'SAF mirror: size drifted during copy uri=${file.uri} '
          'listed=${file.size} written=$written',
        );
      }
      // Rename over an existing destination is atomic on the platforms this
      // runs on; only if that fails fall back to delete-then-rename, so a
      // previously good copy is never removed before its replacement exists.
      try {
        await partial.rename(destination.path);
      } on FileSystemException {
        if (destination.existsSync()) await destination.delete();
        await partial.rename(destination.path);
      }
      return written;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // The write already failed; closing is best effort.
        }
      }
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (e) {
          _log.w(
            'SAF mirror: could not remove partial file path=${partial.path} '
            'error=$e',
          );
        }
      }
      rethrow;
    }
  }

  /// A single path segment with no separators or parent references.
  static bool _isSafeSegment(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\');

  static int? _lengthOf(File file) {
    try {
      return file.existsSync() ? file.lengthSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Complete files under [mirrorDir]; `.part` leftovers do not count.
  static int _countPresent(String mirrorDir) {
    final dir = Directory(mirrorDir);
    if (!dir.existsSync()) return 0;
    try {
      return dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith(partialSuffix))
          .length;
    } on FileSystemException {
      return 0;
    }
  }
}
