import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_search_result.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_fix_match_controller.dart';
import 'package:neostation/services/romm_service.dart';

/// What reaches the user's own RomM server when they fix a match, and what
/// reaches the *local* library afterwards.
///
/// The write is a `PUT` that rewrites a library entry for every client of the
/// server, and the refresh behind it is a replace-mode fetch that overwrites
/// the local row — so the two things worth pinning are that the refresh runs
/// exactly once and only after the server confirmed the write, and that a
/// second press while a write is in flight sends nothing.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Fix Match In The Picker"
void main() {
  RommFixCandidate candidateNamed(String name) => RommFixCandidate(
    name: name,
    match: RommSearchResult(
      providerIds: const {'igdb_id': 123},
      name: name,
      coverUrl: 'https://cdn/$name.png',
    ),
  );

  /// A controller whose three seams are counted rather than networked.
  ({
    RommFixMatchController controller,
    List<String> searched,
    List<String> applied,
    List<int> refreshes,
  })
  build({
    RommFixMode mode = RommFixMode.match,
    Future<List<RommFixCandidate>> Function(String term)? search,
    Future<bool> Function(RommFixCandidate candidate)? apply,
    Future<void> Function()? refresh,
  }) {
    final searched = <String>[];
    final applied = <String>[];
    final refreshes = <int>[];
    final controller = RommFixMatchController(
      mode: mode,
      romId: 42,
      search: (term) async {
        searched.add(term);
        if (search != null) return search(term);
        return [candidateNamed('Chrono Trigger')];
      },
      applyCandidate: (candidate) async {
        applied.add(candidate.name);
        if (apply != null) return apply(candidate);
        return true;
      },
      refreshLocal: () async {
        refreshes.add(refreshes.length + 1);
        if (refresh != null) await refresh();
      },
    );
    return (
      controller: controller,
      searched: searched,
      applied: applied,
      refreshes: refreshes,
    );
  }

  group('search', () {
    test('trims the term and holds the results', () async {
      final t = build();

      await t.controller.searchNow('  Chrono Trigger  ');

      expect(t.searched, ['Chrono Trigger']);
      expect(t.controller.status, RommFixStatus.ready);
      expect(t.controller.results.map((c) => c.name), ['Chrono Trigger']);
    });

    test('keeps the error kind so the dialog can name the cause', () async {
      final t = build(
        search: (_) async => throw RommException(
          'no provider',
          statusCode: 500,
          kind: RommErrorKind.noMetadataSource,
        ),
      );

      await t.controller.searchNow('ct');

      expect(t.controller.status, RommFixStatus.error);
      expect(t.controller.lastErrorKind, RommErrorKind.noMetadataSource);
      expect(t.controller.results, isEmpty);
    });

    test('a superseded response never lands', () async {
      final gates = <Completer<List<RommFixCandidate>>>[];
      final t = build(
        search: (term) {
          final gate = Completer<List<RommFixCandidate>>();
          gates.add(gate);
          return gate.future;
        },
      );

      final first = t.controller.searchNow('slow');
      final second = t.controller.searchNow('fast');
      gates[1].complete([candidateNamed('fast result')]);
      await second;
      gates[0].complete([candidateNamed('slow result')]);
      await first;

      expect(t.controller.results.map((c) => c.name), ['fast result']);
    });
  });

  group('apply', () {
    test('writes once and replaces the local metadata exactly once', () async {
      final t = build();
      final candidate = candidateNamed('Chrono Trigger');

      expect(await t.controller.apply(candidate), isTrue);

      expect(t.applied, ['Chrono Trigger']);
      expect(t.refreshes, hasLength(1));
      expect(t.controller.lastApplyFailed, isFalse);
      expect(t.controller.status, RommFixStatus.ready);
    });

    test('a refused write leaves the local metadata alone', () async {
      final t = build(apply: (_) async => false);

      expect(
        await t.controller.apply(candidateNamed('Chrono Trigger')),
        isFalse,
      );

      expect(t.applied, hasLength(1));
      expect(t.refreshes, isEmpty);
      expect(t.controller.lastApplyFailed, isTrue);
    });

    test('a write that threw does not replace the local metadata', () async {
      final t = build(
        apply: (_) async => throw RommException('boom', statusCode: 500),
      );

      expect(
        await t.controller.apply(candidateNamed('Chrono Trigger')),
        isFalse,
      );

      expect(t.refreshes, isEmpty);
      expect(t.controller.lastApplyFailed, isTrue);
      expect(t.controller.lastErrorKind, RommErrorKind.other);
    });

    test('a second press while a write is in flight sends nothing', () async {
      final gate = Completer<bool>();
      final t = build(apply: (_) => gate.future);
      final candidate = candidateNamed('Chrono Trigger');

      final first = t.controller.apply(candidate);
      expect(t.controller.isApplying, isTrue);

      // The stray press: the confirmation is gone, the write is still on its
      // way, and nothing new may be sent.
      expect(await t.controller.apply(candidate), isFalse);
      expect(t.applied, hasLength(1));

      gate.complete(true);
      expect(await first, isTrue);
      expect(t.applied, hasLength(1));
      expect(t.refreshes, hasLength(1));
    });

    test('a failing refresh still counts the write as applied', () async {
      final t = build(refresh: () async => throw StateError('no disk'));

      expect(
        await t.controller.apply(candidateNamed('Chrono Trigger')),
        isTrue,
      );

      expect(t.refreshes, hasLength(1));
      expect(t.controller.lastApplyFailed, isFalse);
    });
  });

  group('cover mode', () {
    test('candidates carry the URL to write', () {
      final candidate = RommFixCandidate.fromCover(
        const RommCoverResult(
          name: 'Chrono Trigger',
          url: 'https://sgdb/1.png',
          thumbUrl: 'https://sgdb/t1.png',
        ),
      );

      expect(candidate.coverUrl, 'https://sgdb/1.png');
      expect(candidate.previewUrl, 'https://sgdb/t1.png');
      expect(candidate.match, isNull);
    });

    test('match candidates name their providers on the detail line', () {
      final candidate = RommFixCandidate.fromMatch(
        RommSearchResult.fromJson(const {
          'igdb_id': 123,
          'name': 'Chrono Trigger',
        }),
      );

      expect(candidate.detail, contains('igdb 123'));
      expect(candidate.coverUrl, isNull);
    });
  });
}
