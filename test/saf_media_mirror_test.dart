import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/esde/saf_media_mirror.dart';
import 'package:path/path.dart' as p;

/// An in-memory SAF tree behind the mirror's two read-only primitives. It
/// records every call, so a test can assert exactly which folders were
/// listed, which byte ranges were read, and that nothing else was ever
/// invoked: the fake has no write, create, move, or delete surface at all.
class FakeMirrorSaf {
  static const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3Aroms';

  /// Folder URI → its children, in the `listFiles` map shape.
  final Map<String, List<Map<String, dynamic>>> listings = {};

  /// Document URI → bytes.
  final Map<String, Uint8List> documents = {};

  /// Document URIs whose reads answer null (a failed platform read).
  final Set<String> failRead = {};

  /// Document URIs whose reads answer null once [offset] is past zero, to
  /// model a grant lost in the middle of a large file.
  final Set<String> failAfterFirstChunk = {};

  /// Folder URIs whose listing throws.
  final Set<String> failListing = {};

  /// Every call in order, as `op:uri[:offset]`.
  final List<String> calls = [];

  static String uriOf(String relativePath) {
    if (relativePath.isEmpty) return treeUri;
    final encoded = Uri.encodeComponent('roms/$relativePath');
    return '$treeUri/document/primary%3A$encoded';
  }

  String dir(String relativePath) {
    final uri = uriOf(relativePath);
    _addChild(relativePath, {
      'name': p.basename(relativePath),
      'uri': uri,
      'isDirectory': true,
      'size': 0,
      'lastModified': 0,
    });
    listings.putIfAbsent(uri, () => []);
    return uri;
  }

  /// Adds a document at [relativePath] holding [bytes]; [listedSize]
  /// overrides the size the listing reports, to model a stale listing.
  String file(String relativePath, List<int> bytes, {int? listedSize}) {
    final uri = uriOf(relativePath);
    final data = Uint8List.fromList(bytes);
    _addChild(relativePath, {
      'name': p.basename(relativePath),
      'uri': uri,
      'isDirectory': false,
      'size': listedSize ?? data.length,
      'lastModified': 0,
    });
    documents[uri] = data;
    return uri;
  }

  /// Replaces the bytes of an existing document, updating its listed size.
  void rewrite(String relativePath, List<int> bytes) {
    final uri = uriOf(relativePath);
    documents[uri] = Uint8List.fromList(bytes);
    for (final children in listings.values) {
      for (final child in children) {
        if (child['uri'] == uri) child['size'] = bytes.length;
      }
    }
  }

  void _addChild(String relativePath, Map<String, dynamic> entry) {
    final parent = p.dirname(relativePath);
    final parentUri = uriOf(parent == '.' ? '' : parent);
    listings.putIfAbsent(parentUri, () => []).add(entry);
  }

  Future<List<Map<String, dynamic>>> listFiles(String uri) async {
    calls.add('list:$uri');
    if (failListing.contains(uri)) {
      throw StateError('listing refused for $uri');
    }
    return listings[uri] ?? const [];
  }

  Future<Uint8List?> readRange(String uri, int offset, int length) async {
    calls.add('range:$uri:$offset');
    if (failRead.contains(uri)) return null;
    if (offset > 0 && failAfterFirstChunk.contains(uri)) return null;
    final data = documents[uri];
    if (data == null) return null;
    if (offset >= data.length) return Uint8List(0);
    final end = (offset + length).clamp(0, data.length);
    return Uint8List.sublistView(data, offset, end);
  }

  Iterable<String> get listedUris =>
      calls.where((c) => c.startsWith('list:')).map((c) => c.substring(5));

  Iterable<String> get rangeCalls => calls.where((c) => c.startsWith('range:'));
}

void main() {
  late Directory tempDir;
  late String mirrorRoot;
  late FakeMirrorSaf saf;
  late int? freeSpace;
  late List<String> freeSpaceQueries;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('saf_mirror_');
    mirrorRoot = p.join(tempDir.path, 'imported_media');
    saf = FakeMirrorSaf();
    freeSpace = 1 << 40;
    freeSpaceQueries = [];
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  SafMediaMirror mirror({
    bool Function()? shouldStop,
    SafMirrorProgress? onProgress,
  }) => SafMediaMirror(
    listFiles: saf.listFiles,
    readRange: saf.readRange,
    freeSpaceBytes: (path) async {
      freeSpaceQueries.add(path);
      return freeSpace;
    },
    mirrorRoot: mirrorRoot,
    shouldStop: shouldStop,
    onProgress: onProgress,
  );

  /// Relative paths of every complete file under [root], sorted.
  List<String> filesUnder(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: root))
        .toList()
      ..sort();
  }

  List<int> bytesOf(int length, [int seed = 7]) =>
      List<int>.generate(length, (i) => (i * seed + length) & 0xff);

  /// A snes folder with three covers and two unmapped manuals, returning the
  /// category map discovery would hand the mirror (manuals included, to
  /// prove the mirror itself filters).
  Map<String, String> snesWithCoversAndManuals() {
    saf.dir('snes');
    final covers = saf.dir('snes/covers');
    saf.file('snes/covers/a.png', bytesOf(300));
    saf.file('snes/covers/b.png', bytesOf(500));
    saf.file('snes/covers/c.jpg', bytesOf(700));
    final manuals = saf.dir('snes/manuals');
    saf.file('snes/manuals/a.pdf', bytesOf(900));
    saf.file('snes/manuals/b.pdf', bytesOf(1100));
    return {'covers': covers, 'manuals': manuals};
  }

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Media Mirror"
  group('SafMediaMirror first mirror', () {
    test('copies mapped category files and ignores unmapped folders', () async {
      final categoryDirs = snesWithCoversAndManuals();

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.mirrorDir, p.join(mirrorRoot, 'snes'));
      expect(summary.filesPlanned, 3);
      expect(summary.filesCopied, 3);
      expect(summary.filesSkippedUnchanged, 0);
      expect(summary.filesFailed, 0);
      expect(summary.bytesCopied, 300 + 500 + 700);
      expect(summary.filesPresent, 3);
      expect(summary.budgetRefused, isFalse);
      expect(summary.cancelled, isFalse);

      expect(filesUnder(mirrorRoot), [
        p.join('snes', 'covers', 'a.png'),
        p.join('snes', 'covers', 'b.png'),
        p.join('snes', 'covers', 'c.jpg'),
      ]);
      expect(
        File(p.join(mirrorRoot, 'snes', 'covers', 'b.png')).readAsBytesSync(),
        bytesOf(500),
      );
      // The unmapped folder was never even listed.
      expect(saf.listedUris, [FakeMirrorSaf.uriOf('snes/covers')]);
    });

    test('lists each mapped category exactly once', () async {
      saf.dir('snes');
      final covers = saf.dir('snes/covers');
      saf.file('snes/covers/a.png', bytesOf(10));
      final videos = saf.dir('snes/videos');
      saf.file('snes/videos/a.mp4', bytesOf(20));
      final shots = saf.dir('snes/screenshots');

      await mirror().run('snes', {
        'videos': videos,
        'covers': covers,
        'screenshots': shots,
      });

      expect(saf.listedUris.toList()..sort(), [covers, shots, videos]..sort());
      expect(saf.listedUris.length, 3);
    });

    test('reports progress per file and once at the end', () async {
      final categoryDirs = snesWithCoversAndManuals();
      final progress = <(int, int, String)>[];

      await mirror(
        onProgress: (copied, total, name) =>
            progress.add((copied, total, name)),
      ).run('snes', categoryDirs);

      expect(progress, [
        (0, 3, 'a.png'),
        (1, 3, 'b.png'),
        (2, 3, 'c.jpg'),
        (3, 3, ''),
      ]);
    });
  });

  group('SafMediaMirror size skip', () {
    test('a second run skips every size-matched file', () async {
      final categoryDirs = snesWithCoversAndManuals();
      await mirror().run('snes', categoryDirs);
      saf.calls.clear();

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.filesPlanned, 0);
      expect(summary.filesCopied, 0);
      expect(summary.filesSkippedUnchanged, 3);
      expect(summary.bytesCopied, 0);
      expect(summary.filesPresent, 3);
      // One listing, and not a single byte read.
      expect(saf.listedUris, [FakeMirrorSaf.uriOf('snes/covers')]);
      expect(saf.rangeCalls, isEmpty);
    });

    test('re-copies only the file whose size changed', () async {
      final categoryDirs = snesWithCoversAndManuals();
      await mirror().run('snes', categoryDirs);
      saf.rewrite('snes/covers/b.png', bytesOf(512, 3));
      saf.calls.clear();

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.filesPlanned, 1);
      expect(summary.filesCopied, 1);
      expect(summary.filesSkippedUnchanged, 2);
      expect(summary.bytesCopied, 512);
      expect(saf.rangeCalls.map((c) => c.split(':')[1]).toSet(), {
        'content',
      }, reason: 'only range calls, all on content URIs');
      expect(
        saf.rangeCalls.every(
          (c) => c.contains(Uri.encodeComponent('roms/snes/covers/b.png')),
        ),
        isTrue,
        reason: 'only the changed file was read',
      );
      expect(
        File(p.join(mirrorRoot, 'snes', 'covers', 'b.png')).readAsBytesSync(),
        bytesOf(512, 3),
      );
    });
  });

  group('SafMediaMirror streaming', () {
    test('streams a large file in chunks through a .part rename', () async {
      final size = SafMediaMirror.chunkSize * 2 + 4321;
      saf.dir('snes');
      final videos = saf.dir('snes/videos');
      final uri = saf.file('snes/videos/big.mp4', bytesOf(size, 11));

      final summary = await mirror().run('snes', {'videos': videos});

      expect(summary.filesCopied, 1);
      expect(summary.bytesCopied, size);
      expect(saf.rangeCalls, [
        'range:$uri:0',
        'range:$uri:${SafMediaMirror.chunkSize}',
        'range:$uri:${SafMediaMirror.chunkSize * 2}',
      ]);
      final dest = File(p.join(mirrorRoot, 'snes', 'videos', 'big.mp4'));
      expect(dest.lengthSync(), size);
      expect(dest.readAsBytesSync(), bytesOf(size, 11));
      expect(filesUnder(mirrorRoot), [p.join('snes', 'videos', 'big.mp4')]);
    });

    test('a read that fails mid-file leaves no partial file behind', () async {
      final size = SafMediaMirror.chunkSize + 100;
      saf.dir('snes');
      final videos = saf.dir('snes/videos');
      final bad = saf.file('snes/videos/bad.mp4', bytesOf(size));
      saf.failAfterFirstChunk.add(bad);
      saf.file('snes/videos/good.mp4', bytesOf(50));

      final summary = await mirror().run('snes', {'videos': videos});

      expect(summary.filesPlanned, 2);
      expect(summary.filesCopied, 1);
      expect(summary.filesFailed, 1);
      expect(summary.bytesCopied, 50);
      expect(summary.filesPresent, 1);
      // Neither the destination nor its .part exists; the good file does.
      expect(filesUnder(mirrorRoot), [p.join('snes', 'videos', 'good.mp4')]);
      expect(
        Directory(mirrorRoot)
            .listSync(recursive: true)
            .where((e) => e.path.endsWith(SafMediaMirror.partialSuffix)),
        isEmpty,
      );
    });
  });

  group('SafMediaMirror SAF tree untouched', () {
    test('only lists and reads ranges, never anything mutating', () async {
      final categoryDirs = snesWithCoversAndManuals();

      await mirror().run('snes', categoryDirs);
      saf.rewrite('snes/covers/a.png', bytesOf(1));
      await mirror().run('snes', categoryDirs);

      expect(saf.calls, isNotEmpty);
      expect(
        saf.calls.where(
          (c) => !c.startsWith('list:') && !c.startsWith('range:'),
        ),
        isEmpty,
      );
      // And the source never references a mutating SAF call.
      final source = File(
        'lib/services/esde/saf_media_mirror.dart',
      ).readAsStringSync();
      expect(
        source.contains('saf_directory_service.dart'),
        isFalse,
        reason: 'the mirror only sees the injected read primitives',
      );
      for (final mutator in const [
        'createDirectory',
        'moveFile',
        'writeTextFile',
        'deleteFile',
        'releasePermission',
      ]) {
        expect(
          source.contains(mutator),
          isFalse,
          reason: 'the mirror is read-only toward SAF; found $mutator',
        );
      }
    });
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Storage Budget Guard"
  group('SafMediaMirror budget guard', () {
    test('refuses the folder when pending bytes exceed free space', () async {
      final categoryDirs = snesWithCoversAndManuals();
      freeSpace = 1000; // pending is 1500

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.budgetRefused, isTrue);
      expect(summary.requiredBytes, 1500);
      expect(summary.availableBytes, 1000);
      expect(summary.filesPlanned, 3);
      expect(summary.filesCopied, 0);
      expect(summary.bytesCopied, 0);
      expect(summary.filesPresent, 0);
      expect(saf.rangeCalls, isEmpty);
      expect(Directory(mirrorRoot).existsSync(), isFalse);
      // The volume queried is the mirror root's.
      expect(freeSpaceQueries, [mirrorRoot]);
    });

    test('proceeds when free space covers the pending copy', () async {
      final categoryDirs = snesWithCoversAndManuals();
      freeSpace = 1500;

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.budgetRefused, isFalse);
      expect(summary.filesCopied, 3);
    });

    test('counts only pending bytes, not size-matched files', () async {
      final categoryDirs = snesWithCoversAndManuals();
      await mirror().run('snes', categoryDirs);
      saf.rewrite('snes/covers/a.png', bytesOf(400));
      freeSpace = 450; // enough for the one changed file, not for all three

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.budgetRefused, isFalse);
      expect(summary.requiredBytes, 400);
      expect(summary.filesCopied, 1);
      expect(summary.filesSkippedUnchanged, 2);
    });

    test('proceeds when free space cannot be measured', () async {
      final categoryDirs = snesWithCoversAndManuals();
      freeSpace = null;

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.budgetRefused, isFalse);
      expect(summary.availableBytes, isNull);
      expect(summary.filesCopied, 3);
    });
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Concurrency Safety"
  group('SafMediaMirror cancellation', () {
    test(
      'stops between files, keeps copied files, reports cancelled',
      () async {
        final categoryDirs = snesWithCoversAndManuals();

        final summary = await mirror(
          // Cancel once two files are on disk: polled before each file.
          shouldStop: () => filesUnder(mirrorRoot).length >= 2,
        ).run('snes', categoryDirs);

        expect(summary.cancelled, isTrue);
        expect(summary.filesPlanned, 3);
        expect(summary.filesCopied, 2);
        expect(summary.filesFailed, 0);
        expect(summary.filesPresent, 2);
        expect(filesUnder(mirrorRoot), [
          p.join('snes', 'covers', 'a.png'),
          p.join('snes', 'covers', 'b.png'),
        ]);
        // The third file was never read.
        expect(
          saf.rangeCalls.any(
            (c) => c.contains(Uri.encodeComponent('roms/snes/covers/c.jpg')),
          ),
          isFalse,
        );
      },
    );

    test('a later run resumes by size skip', () async {
      final categoryDirs = snesWithCoversAndManuals();
      await mirror(
        shouldStop: () => filesUnder(mirrorRoot).length >= 2,
      ).run('snes', categoryDirs);

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.cancelled, isFalse);
      expect(summary.filesSkippedUnchanged, 2);
      expect(summary.filesCopied, 1);
      expect(summary.filesPresent, 3);
    });
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Error Handling Standards"
  group('SafMediaMirror failure isolation', () {
    test('a file that cannot be read is counted and the rest copy', () async {
      final categoryDirs = snesWithCoversAndManuals();
      saf.failRead.add(FakeMirrorSaf.uriOf('snes/covers/b.png'));

      final summary = await mirror().run('snes', categoryDirs);

      expect(summary.filesCopied, 2);
      expect(summary.filesFailed, 1);
      expect(summary.bytesCopied, 300 + 700);
      expect(filesUnder(mirrorRoot), [
        p.join('snes', 'covers', 'a.png'),
        p.join('snes', 'covers', 'c.jpg'),
      ]);
    });

    test('a category that cannot be listed costs only itself', () async {
      final categoryDirs = snesWithCoversAndManuals();
      final shots = saf.dir('snes/screenshots');
      saf.file('snes/screenshots/a.png', bytesOf(40));
      saf.failListing.add(FakeMirrorSaf.uriOf('snes/covers'));

      final summary = await mirror().run('snes', {
        ...categoryDirs,
        'screenshots': shots,
      });

      expect(summary.filesCopied, 1);
      expect(summary.filesFailed, 0);
      expect(filesUnder(mirrorRoot), [p.join('snes', 'screenshots', 'a.png')]);
    });

    test('an unreadable source creates no empty category folder', () async {
      saf.dir('snes');
      final covers = saf.dir('snes/covers');
      saf.failRead.add(saf.file('snes/covers/a.png', bytesOf(10)));

      final summary = await mirror().run('snes', {'covers': covers});

      expect(summary.filesFailed, 1);
      expect(summary.filesPresent, 0);
      expect(Directory(p.join(mirrorRoot, 'snes')).existsSync(), isFalse);
    });
  });

  group('SafMediaMirror write scope', () {
    test('never writes outside the mirror root', () async {
      // Hostile names from the SAF side: a system folder and file names that
      // try to climb out of the root.
      saf.dir('snes');
      final covers = saf.dir('snes/covers');
      saf.file('snes/covers/ok.png', bytesOf(10));
      saf.listings[covers]!.add({
        'name': '../../escape.png',
        'uri': FakeMirrorSaf.uriOf('snes/covers/escape.png'),
        'isDirectory': false,
        'size': 10,
      });
      saf.documents[FakeMirrorSaf.uriOf('snes/covers/escape.png')] =
          Uint8List.fromList(bytesOf(10));

      final ok = await mirror().run('snes', {'covers': covers});
      final climbing = await mirror().run('../outside', {'covers': covers});
      final absolute = await mirror().run(p.join(tempDir.path, 'abs'), {
        'covers': covers,
      });

      expect(ok.filesCopied, 1);
      expect(ok.filesFailed, 1, reason: 'the climbing name is refused');
      expect(climbing.filesCopied, 0);
      expect(absolute.filesCopied, 0);
      // Everything the temp dir gained sits under the mirror root.
      final outside = tempDir
          .listSync(recursive: true)
          .map((e) => e.path)
          .where((path) => !p.isWithin(mirrorRoot, path) && path != mirrorRoot);
      expect(outside, isEmpty);
      expect(filesUnder(mirrorRoot), [p.join('snes', 'covers', 'ok.png')]);
    });
  });
}
