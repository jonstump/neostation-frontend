import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_collection.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm/romm_collection_mirror.dart';

/// [RommCollectionMirror] against in-memory fakes of the RomM page walk, the
/// local-copy resolver and the collection repository: create on first run,
/// update the same collection on the next, keep the user's name, count the
/// unresolved, stop between pages, write nothing on a failed page, and
/// queue — never drop — a run that arrives while one is active.
///
/// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ
/// "Mirror Service", REQ "Error Handling Standards", REQ "Concurrency Safety"

const _server = 'https://romm.local';

const _bestOfSnes = RommCollection(id: '12', name: 'Best of SNES');

RommRom _rom(int id) => RommRom(
  id: id,
  name: 'Game $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'Game $id.sfc',
  fsNameNoExt: 'Game $id',
  fsExtension: 'sfc',
);

/// A local collection row as the fake repository keeps it.
class _Row {
  String name;
  String? imagePath;
  String? color1;
  int sortOrder;
  String serverUrl;
  String collectionId;
  bool virtual;
  DateTime syncedAt;
  Set<String> members = {};

  _Row({
    required this.name,
    required this.serverUrl,
    required this.collectionId,
    required this.virtual,
    required this.syncedAt,
    this.sortOrder = 0,
  });
}

/// The repository, the server and the resolver, all in memory.
class _Fixture {
  final Map<String, _Row> rows = {};
  final List<RommRom> serverRoms = [];
  final Map<int, String?> localPaths = {};
  final List<int> fetchedOffsets = [];
  int nextId = 1;
  bool stop = false;
  Object? failOnPage;
  int failPage = 0;
  int replaceCalls = 0;

  /// Releases each page fetch when set, so a test can hold the walk open.
  Completer<void>? pageGate;

  /// Called after each page is served, with its 1-based number — where a
  /// test flips [stop] "between pages".
  void Function(int page)? afterPage;

  int pageSize = RommCollectionMirror.pageSize;

  Future<RommRomPage> fetchPage({
    required int limit,
    required int offset,
  }) async {
    final gate = pageGate;
    if (gate != null) await gate.future;
    fetchedOffsets.add(offset);
    final page = offset ~/ pageSize + 1;
    if (failOnPage != null && page == failPage) throw failOnPage!;
    final end = (offset + limit).clamp(0, serverRoms.length);
    final result = RommRomPage(
      items: serverRoms.sublist(offset.clamp(0, serverRoms.length), end),
      total: serverRoms.length,
    );
    afterPage?.call(page);
    return result;
  }

  Future<String?> resolveLocal(RommRom rom) async => localPaths[rom.id];

  Future<Map<String, Object?>?> findMirror(String server, String id) async {
    for (final entry in rows.entries) {
      if (entry.value.serverUrl == server && entry.value.collectionId == id) {
        return {'id': entry.key, 'name': entry.value.name};
      }
    }
    return null;
  }

  Future<void> insertMirror({
    required String id,
    required String name,
    required String serverUrl,
    required String collectionId,
    required bool virtual,
    required DateTime syncedAt,
  }) async {
    rows[id] = _Row(
      name: name,
      serverUrl: serverUrl,
      collectionId: collectionId,
      virtual: virtual,
      syncedAt: syncedAt,
      sortOrder: rows.length,
    );
  }

  Future<({int added, int removed})> replaceMembers(
    String id,
    Set<String> paths,
  ) async {
    replaceCalls++;
    final row = rows[id]!;
    final added = paths.difference(row.members).length;
    final removed = row.members.difference(paths).length;
    row.members = Set.of(paths);
    return (added: added, removed: removed);
  }

  Future<void> setProvenance(
    String id, {
    required String serverUrl,
    required String collectionId,
    required bool virtual,
    required DateTime syncedAt,
  }) async {
    rows[id]!
      ..serverUrl = serverUrl
      ..collectionId = collectionId
      ..virtual = virtual
      ..syncedAt = syncedAt;
  }

  RommCollectionMirror mirror({DateTime Function()? clock}) =>
      RommCollectionMirror(
        fetchPage: fetchPage,
        resolveLocal: resolveLocal,
        findMirror: findMirror,
        insertMirror: insertMirror,
        replaceMembers: replaceMembers,
        setProvenance: setProvenance,
        newId: () => 'local-${nextId++}',
        shouldStop: () => stop,
        clock: clock,
      );
}

/// The summary lines the mirror logged, from the logger's capture.
List<String> _summaryLines() => LoggerService.instance
    .takeCapture()
    .where((l) => l.startsWith('i|RomM collection mirror'))
    .toList();

void main() {
  late _Fixture f;

  setUp(() {
    RommCollectionMirror.resetForTesting();
    LoggerService.instance.startCapture();
    f = _Fixture();
  });
  tearDown(() {
    LoggerService.instance.takeCapture();
    RommCollectionMirror.resetForTesting();
  });

  group('first sync creates', () {
    test('a collection named after the RomM one, with provenance', () async {
      f.serverRoms.addAll([_rom(1), _rom(2), _rom(3)]);
      f.localPaths[1] = '/r/snes/Game 1.sfc';
      f.localPaths[2] = '/r/snes/Game 2.sfc';
      final at = DateTime.utc(2026, 9, 5, 12);

      final s = await f
          .mirror(clock: () => at)
          .run(_bestOfSnes, serverUrl: _server);

      expect(s.created, isTrue);
      expect(s.collectionId, 'local-1');
      expect(s.added, 2);
      expect(s.removed, 0);
      expect(s.kept, 0);
      expect(s.unresolved, 1);
      expect(s.members, 2);
      expect(s.cancelled, isFalse);
      expect(s.failed, isFalse);
      expect(s.wroteMembership, isTrue);

      final row = f.rows['local-1']!;
      expect(row.name, 'Best of SNES');
      expect(row.serverUrl, _server);
      expect(row.collectionId, '12');
      expect(row.virtual, isFalse);
      expect(row.syncedAt, at);
      expect(row.members, {'/r/snes/Game 1.sfc', '/r/snes/Game 2.sfc'});
      expect(f.rows.length, 1);
    });

    test('a virtual collection records its flag', () async {
      const genre = RommCollection(
        id: 'genre:rpg',
        name: 'RPG',
        isVirtual: true,
      );
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/a.sfc';
      final s = await f.mirror().run(genre, serverUrl: _server);
      expect(s.created, isTrue);
      expect(f.rows[s.collectionId]!.virtual, isTrue);
    });

    test('an empty resolved set still creates the collection', () async {
      f.serverRoms.addAll([_rom(1), _rom(2)]);
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(s.created, isTrue);
      expect(s.unresolved, 2);
      expect(s.members, 0);
      expect(f.rows[s.collectionId]!.members, isEmpty);
    });
  });

  group('second sync updates', () {
    test(
      'the same collection gains new, loses removed, no duplicate',
      () async {
        f.serverRoms.addAll([_rom(1), _rom(2), _rom(3)]);
        f.localPaths[1] = '/r/1.sfc';
        f.localPaths[2] = '/r/2.sfc';
        final first = await f.mirror().run(_bestOfSnes, serverUrl: _server);

        // ROM 2 left the RomM collection; ROM 3 is now local.
        f.serverRoms.removeWhere((r) => r.id == 2);
        f.localPaths[3] = '/r/3.sfc';
        final at = DateTime.utc(2026, 9, 6);
        final second = await f
            .mirror(clock: () => at)
            .run(_bestOfSnes, serverUrl: _server);

        expect(second.collectionId, first.collectionId);
        expect(second.created, isFalse);
        expect(second.added, 1);
        expect(second.removed, 1);
        expect(second.kept, 1);
        expect(second.members, 2);
        expect(f.rows.length, 1, reason: 'no second collection');
        expect(f.rows[first.collectionId]!.members, {'/r/1.sfc', '/r/3.sfc'});
        expect(f.rows[first.collectionId]!.syncedAt, at);
      },
    );

    test('a hand-added member is removed', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      final first = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      f.rows[first.collectionId]!.members.add('/r/by-hand.sfc');

      final second = await f.mirror().run(_bestOfSnes, serverUrl: _server);

      expect(second.removed, 1);
      expect(f.rows[first.collectionId]!.members, {'/r/1.sfc'});
    });

    test('keeps the user\'s rename, image, colour and order', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      final first = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      final row = f.rows[first.collectionId]!
        ..name = 'My SNES picks'
        ..imagePath = '/media/collections/x.png'
        ..color1 = '#123456'
        ..sortOrder = 7;

      await f.mirror().run(
        const RommCollection(id: '12', name: 'Best of SNES (renamed)'),
        serverUrl: _server,
      );

      expect(row.name, 'My SNES picks');
      expect(row.imagePath, '/media/collections/x.png');
      expect(row.color1, '#123456');
      expect(row.sortOrder, 7);
    });

    test('provenance is per server: another server gets its own', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      await f.mirror().run(_bestOfSnes, serverUrl: _server);
      final other = await f.mirror().run(
        _bestOfSnes,
        serverUrl: 'https://other',
      );
      expect(other.created, isTrue);
      expect(f.rows.length, 2);
    });
  });

  group('unresolved', () {
    test('ROMs neither local nor downloaded are counted, not added', () async {
      f.serverRoms.addAll([_rom(1), _rom(2), _rom(3), _rom(4)]);
      f.localPaths[1] = '/r/1.sfc';
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(s.unresolved, 3);
      expect(s.members, 1);
      expect(f.rows[s.collectionId]!.members, {'/r/1.sfc'});
    });

    test('a resolver that throws counts that ROM unresolved', () async {
      f.serverRoms.addAll([_rom(1), _rom(2)]);
      f.localPaths[1] = '/r/1.sfc';
      final mirror = RommCollectionMirror(
        fetchPage: f.fetchPage,
        resolveLocal: (rom) async {
          if (rom.id == 2) throw StateError('probe failed');
          return f.localPaths[rom.id];
        },
        findMirror: f.findMirror,
        insertMirror: f.insertMirror,
        replaceMembers: f.replaceMembers,
        setProvenance: f.setProvenance,
        newId: () => 'local-x',
      );
      final s = await mirror.run(_bestOfSnes, serverUrl: _server);
      expect(s.failed, isFalse);
      expect(s.unresolved, 1);
      expect(s.members, 1);
      final lines = LoggerService.instance.takeCapture();
      expect(
        lines.where(
          (l) =>
              l.startsWith('w|RomM collection mirror resolve failed') &&
              l.contains('collection=12') &&
              l.contains('rom=2'),
        ),
        hasLength(1),
      );
    });
  });

  group('paging', () {
    test('walks every page and stops on a short one', () async {
      f.serverRoms.addAll([for (var i = 1; i <= 1001; i++) _rom(i)]);
      for (final rom in f.serverRoms) {
        f.localPaths[rom.id] = '/r/${rom.id}.sfc';
      }
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(f.fetchedOffsets, [0, 500, 1000]);
      expect(s.members, 1001);
    });

    test('cancel between pages leaves membership unchanged', () async {
      f.serverRoms.addAll([for (var i = 1; i <= 600; i++) _rom(i)]);
      for (final rom in f.serverRoms) {
        f.localPaths[rom.id] = '/r/${rom.id}.sfc';
      }
      final first = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(f.rows[first.collectionId]!.members.length, 600);
      f.fetchedOffsets.clear();

      // Something changed on the server, and the run is stopped once the
      // first page has been served: the second page never fetches and
      // nothing is written.
      f.serverRoms.removeRange(0, 100);
      f.afterPage = (page) {
        if (page == 1) f.stop = true;
      };
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);

      expect(s.cancelled, isTrue);
      expect(s.failed, isFalse);
      expect(s.collectionId, first.collectionId);
      expect(s.wroteMembership, isFalse);
      expect(f.fetchedOffsets, [0], reason: 'the in-flight page completed');
      expect(f.rows[first.collectionId]!.members.length, 600);
      expect(f.replaceCalls, 1, reason: 'only the first run wrote');
    });

    test('cancel before the first page creates nothing', () async {
      f.serverRoms.add(_rom(1));
      f.stop = true;
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(s.cancelled, isTrue);
      expect(s.collectionId, isNull);
      expect(f.rows, isEmpty);
    });
  });

  group('page failure', () {
    test(
      'stops the run, keeps membership, names collection and page',
      () async {
        f.serverRoms.addAll([for (var i = 1; i <= 600; i++) _rom(i)]);
        for (final rom in f.serverRoms) {
          f.localPaths[rom.id] = '/r/${rom.id}.sfc';
        }
        final first = await f.mirror().run(_bestOfSnes, serverUrl: _server);
        LoggerService.instance.takeCapture();
        LoggerService.instance.startCapture();

        f.serverRoms.removeRange(0, 100);
        f.failOnPage = TimeoutException('timeout');
        f.failPage = 2;
        final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);

        expect(s.failed, isTrue);
        expect(s.cancelled, isFalse);
        expect(s.error, isA<RommCollectionMirrorPageException>());
        final error = s.error as RommCollectionMirrorPageException;
        expect(error.collectionId, '12');
        expect(error.page, 2);
        expect(error.toString(), contains('RomM collection 12 page 2'));
        expect(s.collectionId, first.collectionId);
        expect(f.rows[first.collectionId]!.members.length, 600);
        expect(f.replaceCalls, 1);

        final lines = LoggerService.instance.takeCapture();
        expect(
          lines.where(
            (l) =>
                l.startsWith('w|RomM collection mirror page failed') &&
                l.contains('collection=12') &&
                l.contains('page=2') &&
                l.contains('error='),
          ),
          hasLength(1),
        );
        expect(
          lines.where((l) => l.startsWith('i|RomM collection mirror failed')),
          hasLength(1),
        );
      },
    );

    test('a failing first run creates no collection', () async {
      f.serverRoms.add(_rom(1));
      f.failOnPage = StateError('boom');
      f.failPage = 1;
      final s = await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(s.failed, isTrue);
      expect(s.collectionId, isNull);
      expect(f.rows, isEmpty);
    });

    test('a failing membership write is reported with its step', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      final mirror = RommCollectionMirror(
        fetchPage: f.fetchPage,
        resolveLocal: f.resolveLocal,
        findMirror: f.findMirror,
        insertMirror: f.insertMirror,
        replaceMembers: (_, _) async => throw StateError('disk full'),
        setProvenance: f.setProvenance,
        newId: () => 'local-x',
      );
      final s = await mirror.run(_bestOfSnes, serverUrl: _server);
      expect(s.failed, isTrue);
      expect(s.error, isA<RommCollectionMirrorWriteException>());
      expect(
        (s.error as RommCollectionMirrorWriteException).step,
        'membership',
      );
      expect(s.collectionId, 'local-x');
      expect(s.created, isTrue);
    });
  });

  group('single instance', () {
    test('isActive while a run is in flight, clear afterwards', () async {
      f.serverRoms.add(_rom(1));
      f.pageGate = Completer<void>();
      final pending = f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(RommCollectionMirror.isActive, isTrue);
      f.pageGate!.complete();
      await pending;
      expect(RommCollectionMirror.isActive, isFalse);
    });

    test('a run during an active one is queued and follows it', () async {
      f.serverRoms.addAll([_rom(1), _rom(2)]);
      f.localPaths[1] = '/r/1.sfc';
      f.pageGate = Completer<void>();
      final order = <String>[];

      final first = f.mirror().run(_bestOfSnes, serverUrl: _server).then((s) {
        order.add('first');
        return s;
      });
      // The settle fires while the post-sync run is still paging: ROM 2 got
      // indexed meanwhile, and the second run must see it.
      f.localPaths[2] = '/r/2.sfc';
      final second = f.mirror().run(_bestOfSnes, serverUrl: _server).then((s) {
        order.add('second');
        return s;
      });
      expect(RommCollectionMirror.queuedCollectionIds, ['12']);
      expect(f.replaceCalls, 0);

      f.pageGate!.complete();
      final s1 = await first;
      final s2 = await second;

      expect(order, ['first', 'second']);
      expect(s1.created, isTrue);
      expect(s2.created, isFalse);
      expect(s2.collectionId, s1.collectionId);
      expect(f.replaceCalls, 2, reason: 'the queued run was not dropped');
      expect(f.rows[s1.collectionId]!.members, {'/r/1.sfc', '/r/2.sfc'});
      expect(RommCollectionMirror.isActive, isFalse);
      expect(RommCollectionMirror.queuedCollectionIds, isEmpty);
    });

    test('a third request for the same id joins the pending run', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      f.pageGate = Completer<void>();
      final first = f.mirror().run(_bestOfSnes, serverUrl: _server);
      final second = f.mirror().run(_bestOfSnes, serverUrl: _server);
      final third = f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(RommCollectionMirror.queuedCollectionIds, ['12']);

      f.pageGate!.complete();
      await first;
      final s2 = await second;
      final s3 = await third;

      expect(identical(s2, s3), isTrue, reason: 'one queued run, one result');
      expect(f.replaceCalls, 2);
    });

    test('queued runs for different collections run in order', () async {
      f.serverRoms.add(_rom(1));
      f.localPaths[1] = '/r/1.sfc';
      f.pageGate = Completer<void>();
      final a = f.mirror().run(_bestOfSnes, serverUrl: _server);
      final b = f.mirror().run(
        const RommCollection(id: '13', name: 'Other'),
        serverUrl: _server,
      );
      final c = f.mirror().run(
        const RommCollection(id: '14', name: 'Third'),
        serverUrl: _server,
      );
      expect(RommCollectionMirror.queuedCollectionIds, ['13', '14']);
      f.pageGate!.complete();
      await Future.wait([a, b, c]);
      expect(f.rows.values.map((r) => r.collectionId).toList(), [
        '12',
        '13',
        '14',
      ]);
      expect(f.rows.values.map((r) => r.sortOrder).toList(), [0, 1, 2]);
    });
  });

  group('summary log', () {
    test('exactly one info line per run with every count', () async {
      f.serverRoms.addAll([_rom(1), _rom(2)]);
      f.localPaths[1] = '/r/1.sfc';
      await f.mirror().run(_bestOfSnes, serverUrl: _server);

      final lines = _summaryLines();
      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line, startsWith('i|RomM collection mirror complete: '));
      for (final field in [
        'collection=12',
        'virtual=false',
        'local=local-1',
        'created=true',
        'added=1',
        'removed=0',
        'kept=0',
        'unresolved=1',
        'cancelled=false',
        'failed=false',
        'elapsed_ms=',
      ]) {
        expect(line, contains(field));
      }
    });

    test('a cancelled run logs one cancelled line', () async {
      f.serverRoms.add(_rom(1));
      f.stop = true;
      await f.mirror().run(_bestOfSnes, serverUrl: _server);
      final lines = _summaryLines();
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('i|RomM collection mirror cancelled: '));
      expect(lines.single, contains('cancelled=true'));
    });

    test('two runs log two lines', () async {
      f.serverRoms.add(_rom(1));
      await f.mirror().run(_bestOfSnes, serverUrl: _server);
      await f.mirror().run(_bestOfSnes, serverUrl: _server);
      expect(_summaryLines(), hasLength(2));
    });
  });
}
