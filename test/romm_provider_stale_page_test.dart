import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// [RommProvider.loadMoreRoms] against a scripted RomM whose responses can be
/// held back: a page that answers a search term, platform or collection the
/// user has since moved on from must be dropped, not appended to the list
/// that replaced it — and the replacement's own first page must not be
/// blocked by the request still on the wire.
///
/// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Concurrency
/// Safety"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final snes = RommPlatform(id: 12, name: 'SNES', slug: 'snes');

  /// One ROM whose name is the term that found it, so a list says which
  /// request it came from.
  Map<String, Object> rom(int id, String term) => {
    'id': id,
    'name': term,
    'platform_id': 12,
    'platform_slug': 'snes',
    'fs_name': '$term.sfc',
    'fs_name_no_ext': term,
    'fs_extension': 'sfc',
    'fs_size_bytes': 1,
  };

  http.Response page(List<Map<String, Object>> items) => http.Response(
    jsonEncode({'items': items, 'total': items.length}),
    200,
    headers: const {'content-type': 'application/json'},
  );

  /// The search terms RomM was asked for, in request order.
  final terms = <String>[];

  /// Answers `/api/roms` through [respond], which may hold its response.
  void serve(Future<http.Response> Function(String term) respond) {
    RommService.debugUseHttpClient(
      MockClient((request) async {
        if (request.url.path != '/api/roms') {
          return http.Response('not found', 404);
        }
        final term = request.url.queryParameters['search_term'] ?? '';
        terms.add(term);
        return respond(term);
      }),
    );
  }

  RommProvider provider() {
    final p = RommProvider();
    p.service.configure(serverUrl: 'https://romm.local', apiKey: 'test-key');
    return p;
  }

  setUp(terms.clear);
  tearDown(() => RommService.debugUseHttpClient(null));

  test('a page for a superseded term is dropped', () async {
    final slow = Completer<http.Response>();
    serve(
      (term) => term == 'ch' ? slow.future : Future.value(page([rom(2, term)])),
    );
    final p = provider();

    // "ch" settles first and goes to the server, where it stalls ...
    final first = p.selectPlatform(snes, search: 'ch');
    await Future<void>.delayed(Duration.zero);
    expect(p.loadingRoms, isTrue);

    // ... "chrono" settles while it is still out; its page comes straight
    // back and must not be held up by the stalled request.
    await p.searchRoms('chrono');
    expect(terms, ['ch', 'chrono']);
    expect(p.roms.map((r) => r.name), ['chrono']);
    expect(p.loadingRoms, isFalse);

    // The slow "ch" page lands last and must change nothing.
    slow.complete(page([rom(1, 'ch')]));
    await first;
    expect(p.roms.map((r) => r.name), ['chrono']);
    expect(p.searchTerm, 'chrono');
    expect(p.romsHasMore, isFalse);
    expect(p.loadingRoms, isFalse);
    expect(p.lastError, isNull);
  });

  test('a page that lands after backing out is dropped', () async {
    final slow = Completer<http.Response>();
    serve((_) => slow.future);
    final p = provider();

    final load = p.selectPlatform(snes);
    await Future<void>.delayed(Duration.zero);
    p.backToPlatforms();
    expect(p.currentPlatform, isNull);

    slow.complete(page([rom(1, '')]));
    await load;
    expect(p.roms, isEmpty);
    expect(p.loadingRoms, isFalse);
  });

  test('a failure for a superseded term does not surface', () async {
    final slow = Completer<http.Response>();
    serve(
      (term) => term == 'ch' ? slow.future : Future.value(page([rom(2, term)])),
    );
    final p = provider();

    final first = p.selectPlatform(snes, search: 'ch');
    await Future<void>.delayed(Duration.zero);
    await p.searchRoms('chrono');

    slow.complete(http.Response('gateway timeout', 504));
    await first;
    expect(p.lastError, isNull, reason: 'the error belongs to a dead search');
    expect(p.roms.map((r) => r.name), ['chrono']);
    expect(p.loadingRoms, isFalse);
  });

  test('a failure for the current term still surfaces', () async {
    serve((_) async => http.Response('gateway timeout', 504));
    final p = provider();

    await p.selectPlatform(snes, search: 'chrono');
    expect(p.lastError, isNotNull);
    expect(p.roms, isEmpty);
    expect(p.loadingRoms, isFalse, reason: 'the field stays usable');
  });

  test('paging within one term still appends', () async {
    serve((term) async => page([rom(terms.length, term)]));
    final p = provider();

    await p.selectPlatform(snes, search: 'mario');
    await p.loadMoreRoms();
    expect(terms, ['mario', 'mario']);
    expect(p.roms.length, 2);
  });
}
