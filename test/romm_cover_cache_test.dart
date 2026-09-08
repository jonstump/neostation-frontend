import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_cover_cache.dart';
import 'package:path/path.dart' as p;

/// [RommCoverCache] against a temp directory and a fake fetcher: no network,
/// no database, no config. The clock is a counter so LRU order is exact.

const _server = 'https://romm.example';
const _other = 'https://other.example';

/// A JPEG header followed by padding, so the extension comes out as `jpg`.
Uint8List _jpeg(int size) {
  final bytes = Uint8List(size);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8;
  bytes[2] = 0xFF;
  return bytes;
}

/// A PNG header followed by padding.
Uint8List _png(int size) {
  final bytes = Uint8List(size);
  bytes[0] = 0x89;
  bytes[1] = 0x50;
  bytes[2] = 0x4E;
  bytes[3] = 0x47;
  return bytes;
}

RommCatalogRow _row(
  int id, {
  String server = _server,
  String? small = 'small',
  String? large = 'large',
  String? provider,
}) => RommCatalogRow(
  serverUrl: server,
  rommRomId: id,
  platformId: 1,
  systemFolder: 'snes',
  name: 'Game $id',
  fsName: 'game_$id.sfc',
  pathCoverSmall: small == null ? null : '/assets/$id/$small.png',
  pathCoverLarge: large == null ? null : '/assets/$id/$large.png',
  urlCover: provider,
  seenAt: DateTime.utc(2026, 9, 6),
);

/// The server, in memory: which URLs answer with which bytes, every URL
/// asked for, and how many fetches are in flight at once.
class _FakeFetcher {
  final Map<String, Uint8List> bodies = {};
  final List<String> requests = [];
  final Set<String> throwing = {};
  int inFlight = 0;
  int maxInFlight = 0;

  /// When set, every fetch waits on it before answering, so a test can hold
  /// the pool open and count workers.
  Completer<void>? gate;

  Future<Uint8List?> call(String url) async {
    requests.add(url);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await gate?.future;
      // Yield once so concurrent workers overlap even without a gate.
      await Future<void>.delayed(Duration.zero);
      if (throwing.contains(url)) throw const SocketException('down');
      return bodies[url];
    } finally {
      inFlight--;
    }
  }
}

List<String> _urls(RommCatalogRow row) => [
  for (final c in [row.pathCoverSmall, row.pathCoverLarge, row.urlCover])
    if (c != null && c.isNotEmpty)
      c.startsWith('http') ? c : '${row.serverUrl}$c',
];

void main() {
  late Directory temp;
  late _FakeFetcher fetcher;
  var capMb = 200;
  var tick = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('neostation_romm_covers');
    fetcher = _FakeFetcher();
    capMb = 200;
    tick = 0;
    LoggerService.instance.startCapture();
  });

  tearDown(() async {
    LoggerService.instance.takeCapture();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  RommCoverCache build({
    bool Function()? shouldStop,
    String? root,
    RommCoverFetcher? fetch,
  }) => RommCoverCache(
    root: () async => root ?? temp.path,
    fetch: fetch ?? fetcher.call,
    coverUrls: _urls,
    capMb: () async => capMb,
    shouldStop: shouldStop,
    clock: () => DateTime.fromMillisecondsSinceEpoch(++tick * 1000),
  );

  String smallUrl(int id) => '$_server/assets/$id/small.png';
  String largeUrl(int id) => '$_server/assets/$id/large.png';

  group('lazy fill', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — fills on first render, small first
    test(
      'ensure fetches the small cover first and writes it by content type',
      () async {
        fetcher.bodies[smallUrl(10)] = _jpeg(100);
        final cache = build();

        final path = await cache.ensure(_server, _row(10));

        expect(path, isNotNull);
        expect(p.basename(path!), '10.jpg', reason: 'JPEG bytes, .png path');
        expect(
          p.basename(p.dirname(path)),
          RommCoverCache.serverHash(_server),
          reason: 'one directory per server',
        );
        expect(p.dirname(p.dirname(path)), temp.path);
        expect(await File(path).length(), 100);
        expect(fetcher.requests, [
          smallUrl(10),
        ], reason: 'the small file first');
        expect(cache.pathFor(_server, 10), path);
      },
    );

    test('a missing small cover falls through to the large one', () async {
      fetcher.bodies[largeUrl(11)] = _png(64);
      final cache = build();

      final path = await cache.ensure(_server, _row(11));

      expect(path, endsWith('11.png'));
      expect(fetcher.requests, [smallUrl(11), largeUrl(11)]);
    });

    test('a second ensure is served from disk without a request', () async {
      fetcher.bodies[smallUrl(12)] = _jpeg(10);
      final cache = build();
      final first = await cache.ensure(_server, _row(12));

      final second = await cache.ensure(_server, _row(12));

      expect(second, first);
      expect(fetcher.requests, hasLength(1));
    });

    test('two concurrent ensures for one cover share a fetch', () async {
      fetcher.bodies[smallUrl(13)] = _jpeg(10);
      fetcher.gate = Completer<void>();
      final cache = build();
      await cache.initialize();

      final a = cache.ensure(_server, _row(13));
      final b = cache.ensure(_server, _row(13));
      await Future<void>.delayed(Duration.zero);
      fetcher.gate!.complete();

      expect(await a, await b);
      expect(fetcher.requests, hasLength(1));
    });

    // Governing: SPEC-0019 REQ "Error Handling Standards" — debug, retried
    test(
      'a failed fill returns null, logs at debug, and retries next time',
      () async {
        fetcher.throwing.add(smallUrl(14));
        final cache = build();

        expect(await cache.ensure(_server, _row(14, large: null)), isNull);
        expect(cache.pathFor(_server, 14), isNull);
        final lines = LoggerService.instance.takeCapture();
        expect(lines.where((l) => l.startsWith('d|')), isNotEmpty);
        expect(
          lines.where((l) => l.startsWith('w|') || l.startsWith('e|')),
          isEmpty,
        );

        fetcher.throwing.clear();
        fetcher.bodies[smallUrl(14)] = _jpeg(10);
        expect(await cache.ensure(_server, _row(14, large: null)), isNotNull);
      },
    );

    test('a row with no cover fields is a miss without a request', () async {
      final cache = build();

      expect(
        await cache.ensure(_server, _row(15, small: null, large: null)),
        isNull,
      );
      expect(fetcher.requests, isEmpty);
    });

    test('an unusable root leaves every fill a quiet miss', () async {
      final file = File(p.join(temp.path, 'not_a_dir'))..writeAsStringSync('x');
      final cache = build(root: p.join(file.path, 'covers'));

      expect(await cache.ensure(_server, _row(16)), isNull);
      expect(cache.pathFor(_server, 16), isNull);
    });
  });

  group('pathFor', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — synchronous, build-time safe
    test('is null before initialize and after, until a fill', () async {
      final cache = build();
      expect(cache.pathFor(_server, 1), isNull);

      await cache.initialize();
      expect(cache.pathFor(_server, 1), isNull);
    });

    test(
      'treats a trailing slash on the server URL as the same server',
      () async {
        fetcher.bodies[smallUrl(20)] = _jpeg(10);
        final cache = build();
        await cache.ensure(_server, _row(20));

        expect(cache.pathFor('$_server/', 20), isNotNull);
        expect(cache.pathFor(_other, 20), isNull);
      },
    );
  });

  group('index rebuild', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — offline render from the directory
    test('a new instance finds what the previous one wrote', () async {
      fetcher.bodies[smallUrl(30)] = _jpeg(40);
      fetcher.bodies[smallUrl(31)] = _png(50);
      final first = build();
      await first.ensure(_server, _row(30));
      await first.ensure(_server, _row(31));

      final second = build();
      expect(second.pathFor(_server, 30), isNull, reason: 'not yet scanned');
      await second.initialize();

      expect(second.pathFor(_server, 30), endsWith('30.jpg'));
      expect(second.pathFor(_server, 31), endsWith('31.png'));
      expect(second.entryCount, 2);
      expect(second.totalBytes, 90);
      expect(fetcher.requests, hasLength(2), reason: 'no refetch');
    });

    test('ignores files that are not covers', () async {
      final serverDir = Directory(
        p.join(temp.path, RommCoverCache.serverHash(_server)),
      )..createSync(recursive: true);
      File(p.join(serverDir.path, 'notes.txt')).writeAsStringSync('x');
      File(p.join(serverDir.path, '7.jpg.part')).writeAsBytesSync(_jpeg(5));
      File(p.join(serverDir.path, '8.jpg')).writeAsBytesSync(_jpeg(5));
      File(p.join(temp.path, 'stray.png')).writeAsBytesSync(_png(5));

      final cache = build();
      await cache.initialize();

      expect(cache.entryCount, 1);
      expect(cache.pathFor(_server, 8), isNotNull);
      expect(cache.pathFor(_server, 7), isNull);
    });

    test('creates the root when it does not exist yet', () async {
      final root = p.join(temp.path, 'nested', 'romm_covers');
      final cache = build(root: root);

      await cache.initialize();

      expect(Directory(root).existsSync(), isTrue);
      expect(cache.rootPath, root);
    });
  });

  group('prefetch', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — bounded to max, concurrency
    test(
      'fills only missing rows, at most max, with bounded concurrency',
      () async {
        for (var id = 1; id <= 10; id++) {
          fetcher.bodies[smallUrl(id)] = _jpeg(10);
        }
        final cache = build();
        await cache.ensure(_server, _row(1));
        fetcher.requests.clear();
        fetcher.gate = Completer<void>();

        final rows = [for (var id = 1; id <= 10; id++) _row(id)];
        final done = cache.prefetch(rows, max: 5, concurrency: 3);
        await Future<void>.delayed(Duration.zero);
        expect(fetcher.inFlight, 3, reason: 'three workers, no more');
        fetcher.gate!.complete();
        final filled = await done;

        expect(filled, 5);
        expect(fetcher.maxInFlight, 3);
        expect(
          fetcher.requests,
          unorderedEquals([for (var id = 2; id <= 6; id++) smallUrl(id)]),
          reason: 'row 1 was cached; the next five in order, none beyond max',
        );
        expect(cache.entryCount, 6);
      },
    );

    test('uses the defaults of 300 and 3', () {
      expect(RommCoverCache.defaultPrefetchMax, 300);
      expect(RommCoverCache.defaultPrefetchConcurrency, 3);
    });

    test('a failing row does not stop the others', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      fetcher.throwing.add(smallUrl(2));
      fetcher.bodies[smallUrl(3)] = _jpeg(10);
      final cache = build();

      final filled = await cache.prefetch([
        _row(1),
        _row(2, large: null),
        _row(3),
      ]);

      expect(filled, 2);
      expect(cache.pathFor(_server, 2), isNull);
    });

    // Governing: SPEC-0019 REQ "Concurrency Safety" — stop checked between files
    test('stops between files when the stop signal is raised', () async {
      for (var id = 1; id <= 6; id++) {
        fetcher.bodies[smallUrl(id)] = _jpeg(10);
      }
      var stop = false;
      final cache = build(shouldStop: () => stop);
      await cache.initialize();
      fetcher.gate = Completer<void>();

      final done = cache.prefetch([
        for (var id = 1; id <= 6; id++) _row(id),
      ], concurrency: 1);
      await Future<void>.delayed(Duration.zero);
      stop = true;
      fetcher.gate!.complete();
      final filled = await done;

      expect(filled, 1, reason: 'the fetch in flight lands, nothing after');
      expect(fetcher.requests, hasLength(1));
    });

    test('duplicate rows are fetched once', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      final cache = build();

      final filled = await cache.prefetch([_row(1), _row(1), _row(1)]);

      expect(filled, 1);
      expect(fetcher.requests, hasLength(1));
    });
  });

  group('eviction', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — "Eviction" scenario
    test(
      'after a prefetch the least recently used files go until under the cap',
      () async {
        const mb = 1024 * 1024;
        capMb = 2;
        // Four covers of 0.6 MB: 2.4 MB, over a 2 MB cap by one file.
        for (var id = 1; id <= 4; id++) {
          fetcher.bodies[smallUrl(id)] = _jpeg((0.6 * mb).round());
        }
        final cache = build();
        await cache.ensure(_server, _row(1));
        await cache.ensure(_server, _row(2));
        // Row 1 was used most recently of the two; row 2 is the oldest.
        cache.pathFor(_server, 1);

        await cache.prefetch([_row(3), _row(4)], concurrency: 1);

        expect(cache.totalBytes, lessThanOrEqualTo(2 * mb));
        expect(cache.pathFor(_server, 2), isNull, reason: 'LRU goes first');
        expect(cache.pathFor(_server, 1), isNotNull);
        expect(cache.pathFor(_server, 3), isNotNull);
        expect(cache.pathFor(_server, 4), isNotNull);
        final files = Directory(
          p.join(temp.path, RommCoverCache.serverHash(_server)),
        ).listSync().map((f) => p.basename(f.path)).toList();
        expect(files, unorderedEquals(['1.jpg', '3.jpg', '4.jpg']));
      },
    );

    test('nothing is evicted while under the cap', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      fetcher.bodies[smallUrl(2)] = _jpeg(10);
      final cache = build();

      await cache.prefetch([_row(1), _row(2)]);

      expect(cache.entryCount, 2);
      final lines = LoggerService.instance.takeCapture();
      expect(lines.where((l) => l.contains('evicted')), isEmpty);
    });

    test('lazy fills check the cap every 100 fills', () async {
      capMb = 1;
      // 101 covers of 20 KB: over 1 MB after 52 fills, but only checked at 100.
      for (var id = 1; id <= 101; id++) {
        fetcher.bodies[smallUrl(id)] = _jpeg(20 * 1024);
      }
      final cache = build();

      for (var id = 1; id <= 99; id++) {
        await cache.ensure(_server, _row(id));
      }
      expect(cache.entryCount, 99, reason: 'no check before the 100th fill');

      await cache.ensure(_server, _row(100));
      await cache.evictIfNeeded(); // joins the pass the 100th fill started
      expect(cache.totalBytes, lessThanOrEqualTo(1024 * 1024));
      expect(cache.entryCount, lessThan(100));
      expect(cache.pathFor(_server, 100), isNotNull, reason: 'newest survives');
      expect(cache.pathFor(_server, 1), isNull, reason: 'oldest goes first');
    });

    test('an unreadable cap falls back to the default', () async {
      final cache = RommCoverCache(
        root: () async => temp.path,
        fetch: fetcher.call,
        coverUrls: _urls,
        capMb: () async => throw StateError('no config'),
      );
      fetcher.bodies[smallUrl(1)] = _jpeg(10);

      await cache.prefetch([_row(1)]); // ends in an eviction pass

      expect(cache.entryCount, 1, reason: 'the throw never reaches a caller');
      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where(
          (l) =>
              l.contains('cap unreadable, using default') &&
              l.contains('no config'),
        ),
        hasLength(1),
        reason: 'the pass ran on the default cap, not on a failed read',
      );
    });
  });

  group('clear', () {
    // Governing: SPEC-0019 REQ "Settings And Actions" — per server
    test(
      'removes one server\'s files and index and leaves the other',
      () async {
        fetcher.bodies[smallUrl(1)] = _jpeg(10);
        fetcher.bodies['$_other/assets/1/small.png'] = _jpeg(10);
        final cache = build();
        await cache.ensure(_server, _row(1));
        await cache.ensure(_other, _row(1, server: _other));

        await cache.clear(_server);

        expect(cache.pathFor(_server, 1), isNull);
        expect(cache.pathFor(_other, 1), isNotNull);
        expect(
          Directory(
            p.join(temp.path, RommCoverCache.serverHash(_server)),
          ).existsSync(),
          isFalse,
        );
        expect(
          Directory(
            p.join(temp.path, RommCoverCache.serverHash(_other)),
          ).existsSync(),
          isTrue,
        );
      },
    );

    test('clearing a server that has nothing is fine', () async {
      final cache = build();
      await cache.clear(_server);
      expect(cache.entryCount, 0);
    });

    test('a fill that finishes after clear leaves nothing behind', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      fetcher.gate = Completer<void>();
      final cache = build();
      await cache.initialize();
      final pending = cache.ensure(_server, _row(1));
      await Future<void>.delayed(Duration.zero);
      expect(fetcher.inFlight, 1, reason: 'the fetch is on the wire');

      await cache.clear(_server);
      fetcher.gate!.complete();

      expect(await pending, isNull);
      expect(cache.pathFor(_server, 1), isNull);
      expect(cache.entryCount, 0);
      final serverDir = Directory(
        p.join(temp.path, RommCoverCache.serverHash(_server)),
      );
      expect(
        serverDir.existsSync()
            ? serverDir.listSync()
            : const <FileSystemEntity>[],
        isEmpty,
        reason: 'no orphan file survives the clear',
      );

      // The server is not poisoned: the next ask fills it again.
      fetcher.gate = null;
      expect(await cache.ensure(_server, _row(1)), endsWith('1.jpg'));
      expect(cache.entryCount, 1);
    });
  });

  group('rommCoverPathFor', () {
    // Governing: SPEC-0019 REQ "Cover Cache" — scraped media wins
    test('a local game draws its scraped media, never the cache', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      final cache = build();
      await cache.ensure(_server, _row(1));

      expect(
        rommCoverPathFor(
          isLocal: true,
          scrapedMediaPath: '/media/snes/cover/game.png',
          serverUrl: _server,
          rommRomId: 1,
          cache: cache,
        ),
        '/media/snes/cover/game.png',
      );
      expect(
        rommCoverPathFor(
          isLocal: true,
          scrapedMediaPath: null,
          serverUrl: _server,
          rommRomId: 1,
          cache: cache,
        ),
        isNull,
        reason: 'a local game without art shows the placeholder',
      );
    });

    test('a remote entry draws the cached cover, else nothing', () async {
      fetcher.bodies[smallUrl(1)] = _jpeg(10);
      final cache = build();
      await cache.ensure(_server, _row(1));

      expect(
        rommCoverPathFor(
          isLocal: false,
          scrapedMediaPath: null,
          serverUrl: _server,
          rommRomId: 1,
          cache: cache,
        ),
        endsWith('1.jpg'),
      );
      expect(
        rommCoverPathFor(
          isLocal: false,
          scrapedMediaPath: null,
          serverUrl: _server,
          rommRomId: 2,
          cache: cache,
        ),
        isNull,
      );
      expect(
        rommCoverPathFor(
          isLocal: false,
          scrapedMediaPath: null,
          serverUrl: _server,
          rommRomId: null,
          cache: cache,
        ),
        isNull,
      );
    });
  });
}
