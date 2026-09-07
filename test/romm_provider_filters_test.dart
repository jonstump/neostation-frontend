import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_collection.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_rom_filters.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// [RommProvider]'s filter state and its "Surprise me" walk against a scripted
/// RomM.
///
/// What is pinned:
///
/// * a filter change re-pages from offset 0 rather than appending a filtered
///   page onto an unfiltered list, and bumps the generation so a page still on
///   the wire under the old filters is dropped;
/// * the filters belong to the *source*, so opening another platform, backing
///   out, or a library-wide search clears them — while typing in the same
///   platform or collection keeps them;
/// * the random pick pages forward to reach its ROM, but only within the cap,
///   and a pick it cannot reach still comes back for the card.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Filter Menu And Chips", REQ "Surprise Me"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final snes = RommPlatform(id: 12, name: 'SNES', slug: 'snes');
  final megadrive = RommPlatform(id: 13, name: 'Mega Drive', slug: 'genesis');

  Map<String, Object> rom(int id) => {
    'id': id,
    'name': 'Game $id',
    'platform_id': 12,
    'platform_slug': 'snes',
    'fs_name': 'game$id.sfc',
    'fs_name_no_ext': 'game$id',
    'fs_extension': 'sfc',
    'fs_size_bytes': 1,
  };

  http.Response json(Object? body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );

  /// Every `/api/roms` query RomM was asked, in request order.
  final queries = <Map<String, String>>[];

  /// Serves `/api/roms` from [library] (paged by limit/offset), the heartbeat
  /// on [version], and `/api/roms/random` with [randomId].
  void serve({
    List<int> library = const [],
    String version = '5.2.0',
    int? randomId,
  }) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/heartbeat') {
          return json({
            'SYSTEM': {'VERSION': version},
          });
        }
        if (path == '/api/roms/random') {
          return json(randomId == null ? null : rom(randomId));
        }
        if (path != '/api/roms') return http.Response('not found', 404);
        final q = request.url.queryParameters;
        queries.add(q);
        final limit = int.parse(q['limit']!);
        final offset = int.parse(q['offset']!);
        final start = offset.clamp(0, library.length);
        final end = (offset + limit).clamp(0, library.length);
        return json({
          'items': [for (final id in library.sublist(start, end)) rom(id)],
          'total': library.length,
        });
      }),
    );
  }

  Future<RommProvider> connected() async {
    final p = RommProvider();
    p.service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
    // The heartbeat is what settles the random-pick capability; the provider's
    // own connect path is a database round trip this test does not need.
    await p.service.fetchHeartbeat();
    return p;
  }

  setUp(queries.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  group('filter state', () {
    test('setFilters re-pages from offset 0 with the new parameters', () async {
      serve(library: List.generate(120, (i) => i));
      final p = await connected();
      await p.selectPlatform(snes);
      await p.loadMoreRoms();
      expect(p.roms.length, 100, reason: 'two pages loaded');
      queries.clear();

      await p.setFilters(const RommRomFilters(hasSaves: true));
      expect(queries.single['offset'], '0');
      expect(queries.single['has_saves'], 'true');
      // The list started over rather than growing.
      expect(p.roms.length, 50);
      expect(p.filters.hasSaves, isTrue);
    });

    test('setting the same filters again sends nothing', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(playable: true));
      queries.clear();
      await p.setFilters(const RommRomFilters(playable: true));
      expect(queries, isEmpty);
    });

    test('filters do nothing outside a platform or collection', () async {
      serve(library: const [1]);
      final p = await connected();
      await p.setFilters(const RommRomFilters(favorite: true));
      expect(p.filters, RommRomFilters.none);
      expect(queries, isEmpty);
    });

    test('opening another platform clears them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(hasSaves: true));
      await p.selectPlatform(megadrive);
      expect(p.filters, RommRomFilters.none);
      expect(queries.last.containsKey('has_saves'), isFalse);
    });

    test('opening a collection clears them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(hasStates: true));
      await p.selectCollection(
        RommCollection(id: '3', name: 'RPGs', romCount: 2),
      );
      expect(p.filters, RommRomFilters.none);
    });

    test('backing out to the lists clears them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(missing: true));
      p.backToPlatforms();
      expect(p.filters, RommRomFilters.none);
    });

    test('a library-wide search clears them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(duplicate: true));
      await p.searchLibrary('zelda');
      expect(p.filters, RommRomFilters.none);
    });

    test('typing in the same platform keeps them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectPlatform(snes);
      await p.setFilters(const RommRomFilters(hasRa: true));
      queries.clear();
      await p.searchRoms('zel');
      expect(p.filters.hasRa, isTrue);
      expect(queries.last['has_ra'], 'true');
      expect(queries.last['search_term'], 'zel');
    });

    // The collection twin of the test above. A collection is a *source* just
    // as a platform is, so typing inside one narrows it rather than opening a
    // different one — the filters and their chips must survive the keystroke.
    // Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips"
    test('typing in the same collection keeps them', () async {
      serve(library: const [1, 2]);
      final p = await connected();
      await p.selectCollection(
        RommCollection(id: '3', name: 'RPGs', romCount: 2),
      );
      await p.setFilters(const RommRomFilters(hasRa: true));
      queries.clear();
      await p.searchRoms('zel');
      expect(p.filters.hasRa, isTrue);
      expect(queries.last['has_ra'], 'true');
      expect(queries.last['search_term'], 'zel');
    });

    test('a page still on the wire under the old filters is dropped', () async {
      final slow = Completer<http.Response>();
      var served = 0;
      RommService.debugUseHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/heartbeat') {
            return json({
              'SYSTEM': {'VERSION': '5.2.0'},
            });
          }
          if (request.url.path != '/api/roms') {
            return http.Response('not found', 404);
          }
          queries.add(request.url.queryParameters);
          served++;
          // The unfiltered first page stalls; the filtered one answers at once.
          if (served == 1) return slow.future;
          return json({
            'items': [rom(99)],
            'total': 1,
          });
        }),
      );
      final p = await connected();
      final first = p.selectPlatform(snes);
      await Future<void>.delayed(Duration.zero);

      await p.setFilters(const RommRomFilters(playable: true));
      expect(p.roms.map((r) => r.id), [99]);

      slow.complete(
        json({
          'items': [rom(1), rom(2)],
          'total': 2,
        }),
      );
      await first;
      // The stale page changed nothing.
      expect(p.roms.map((r) => r.id), [99]);
      expect(p.filters.playable, isTrue);
    });
  });

  group('surpriseMe', () {
    test('returns the pick already on screen with its index', () async {
      serve(library: const [1, 2, 3], randomId: 2);
      final p = await connected();
      await p.selectPlatform(snes);
      final pick = await p.surpriseMe();
      expect(pick.outcome, RommSurpriseOutcome.picked);
      expect(pick.rom?.id, 2);
      expect(pick.index, 1);
      expect(pick.isFocusable, isTrue);
    });

    test('pages forward until the pick is loaded', () async {
      // 130 ROMs: the pick is on the third page, so two more must be pulled.
      serve(library: List.generate(130, (i) => i), randomId: 129);
      final p = await connected();
      await p.selectPlatform(snes);
      expect(p.roms.length, 50);
      final pick = await p.surpriseMe();
      expect(pick.isFocusable, isTrue);
      expect(pick.index, 129);
      expect(p.roms.length, 130);
    });

    test(
      'a pick outside the loaded list is still returned, unfocusable',
      () async {
        // The random endpoint names a ROM the (filtered) list never contains.
        serve(library: const [1, 2, 3], randomId: 404);
        final p = await connected();
        await p.selectPlatform(snes);
        final pick = await p.surpriseMe();
        expect(pick.outcome, RommSurpriseOutcome.picked);
        expect(pick.rom?.id, 404);
        expect(pick.index, -1);
        expect(pick.isFocusable, isFalse);
      },
    );

    test('an empty scope is reported as empty, not as a failure', () async {
      serve(library: const [], randomId: null);
      final p = await connected();
      await p.selectPlatform(snes);
      final pick = await p.surpriseMe();
      expect(pick.outcome, RommSurpriseOutcome.empty);
    });

    test('a server below the threshold is reported as unsupported', () async {
      serve(library: const [1], version: '5.1.0', randomId: 1);
      final p = await connected();
      await p.selectPlatform(snes);
      expect((await p.surpriseMe()).outcome, RommSurpriseOutcome.unsupported);
    });

    test('nothing open means nothing to pick', () async {
      serve(library: const [1], randomId: 1);
      final p = await connected();
      expect((await p.surpriseMe()).outcome, RommSurpriseOutcome.empty);
    });
  });
}
