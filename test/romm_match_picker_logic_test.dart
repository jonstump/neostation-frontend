import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_match_picker_controller.dart';

/// The link picker's logic behind the dialog (SPEC-0004 "Link Picker Dialog"
/// and "Error Handling Standards") against hand-written fakes: the search is
/// scoped to the platform ids the system resolves to, a burst of keystrokes
/// costs one request, confirm writes a manual row keyed by the on-disk
/// filename and invalidates the game's sync state exactly once, cancelling
/// writes nothing, and a failed search is reported and retryable.

// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"

RommRom _rom(int id, String fsName, {int platformId = 1, String? name}) =>
    RommRom(
      id: id,
      name: name ?? 'Rom $id',
      platformId: platformId,
      platformSlug: 'snes',
      fsName: fsName,
      fsNameNoExt: fsName.split('.').first,
      fsExtension: fsName.split('.').last,
    );

typedef _SearchCall = ({String search, List<int> platformIds, int limit});
typedef _WriteCall = ({
  String romname,
  String systemFolder,
  int rommRomId,
  String? fsName,
});

/// Records every call the controller makes; the search answer is scripted
/// per test.
class _Fakes {
  final searches = <_SearchCall>[];
  final writes = <_WriteCall>[];
  final invalidations = <String>[];
  List<int> platformIds = const [3, 7];
  RommSaveMapping? mapping;
  bool writeResult = true;
  Future<RommRomPage> Function(String search) answer = (_) async =>
      RommRomPage(items: [_rom(40, 'Chrono Trigger (USA).sfc')]);

  RommMatchPickerController controller({
    RommRom? preselected,
    Duration debounce = const Duration(milliseconds: 30),
  }) => RommMatchPickerController(
    linkKey: 'ct-final.sfc',
    syncKey: 'ct-final',
    systemFolder: 'snes',
    systemRealName: 'Super Nintendo',
    searchRoms:
        ({
          required String search,
          required List<int> platformIds,
          required int limit,
        }) {
          searches.add((
            search: search,
            platformIds: platformIds,
            limit: limit,
          ));
          return answer(search);
        },
    platformIdsFor: (_) async => platformIds,
    readMapping: () async => mapping,
    writeMapping:
        ({
          required String romname,
          required String systemFolder,
          required int rommRomId,
          String? fsName,
        }) async {
          writes.add((
            romname: romname,
            systemFolder: systemFolder,
            rommRomId: rommRomId,
            fsName: fsName,
          ));
          return writeResult;
        },
    invalidateSyncState: invalidations.add,
    preselected: preselected,
    debounce: debounce,
  );
}

void main() {
  group('scoping', () {
    test(
      'search carries exactly the platform ids the system resolves to',
      () async {
        final fakes = _Fakes()..platformIds = const [3, 7];
        final c = fakes.controller();
        await c.init('ct-final');

        expect(fakes.searches, hasLength(1));
        expect(fakes.searches.single.platformIds, [3, 7]);
        expect(fakes.searches.single.search, 'ct-final');
        expect(fakes.searches.single.limit, 25);
        expect(c.isScoped, isTrue);
        expect(c.status, RommMatchPickerStatus.ready);
        expect(c.results.map((r) => r.id), [40]);
        c.dispose();
      },
    );

    test('no platform ids searches unscoped and says so', () async {
      final fakes = _Fakes()..platformIds = const [];
      final c = fakes.controller();
      await c.init('ct-final');

      expect(fakes.searches.single.platformIds, isEmpty);
      expect(c.isScoped, isFalse);
      c.dispose();
    });

    test('current link is read for the check mark', () async {
      final fakes = _Fakes()
        ..mapping = (
          rommRomId: 12,
          fsName: 'old.sfc',
          source: RommLinkSource.auto,
        );
      final c = fakes.controller();
      await c.init('ct-final');
      expect(c.currentRomId, 12);
      c.dispose();
    });
  });

  group('debounce', () {
    test('a burst of keystrokes costs one search, for the last text', () async {
      final fakes = _Fakes();
      final c = fakes.controller(debounce: const Duration(milliseconds: 30));
      await c.init('ct');
      fakes.searches.clear();

      c.onQueryChanged('chr');
      c.onQueryChanged('chro');
      c.onQueryChanged('chrono');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(fakes.searches, hasLength(1));
      expect(fakes.searches.single.search, 'chrono');
      c.dispose();
    });

    test('searchNow cancels a pending debounce', () async {
      final fakes = _Fakes();
      final c = fakes.controller(debounce: const Duration(milliseconds: 30));
      await c.init('ct');
      fakes.searches.clear();

      c.onQueryChanged('chr');
      await c.searchNow('chrono');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(fakes.searches.map((s) => s.search), ['chrono']);
      c.dispose();
    });

    test('a stale response is dropped in favour of the newer search', () async {
      final fakes = _Fakes();
      final first = Completer<RommRomPage>();
      final second = Completer<RommRomPage>();
      fakes.answer = (search) =>
          search == 'first' ? first.future : second.future;
      final c = fakes.controller();

      final firstSearch = c.searchNow('first');
      final secondSearch = c.searchNow('second');
      second.complete(RommRomPage(items: [_rom(2, 'two.sfc')]));
      await secondSearch;
      first.complete(RommRomPage(items: [_rom(1, 'one.sfc')]));
      await firstSearch;

      expect(c.results.map((r) => r.id), [2]);
      c.dispose();
    });
  });

  group('confirm', () {
    test(
      'writes manual keyed by the on-disk filename and invalidates once',
      () async {
        final fakes = _Fakes();
        final c = fakes.controller();
        await c.init('ct-final');

        final ok = await c.confirm(_rom(40, 'Chrono Trigger (USA).sfc'));

        expect(ok, isTrue);
        expect(fakes.writes, hasLength(1));
        expect(fakes.writes.single.romname, 'ct-final.sfc');
        expect(fakes.writes.single.systemFolder, 'snes');
        expect(fakes.writes.single.rommRomId, 40);
        expect(fakes.writes.single.fsName, 'Chrono Trigger (USA).sfc');
        expect(fakes.invalidations, ['ct-final']);
        expect(c.currentRomId, 40);
        c.dispose();
      },
    );

    test('a refused write invalidates nothing and reports false', () async {
      final fakes = _Fakes()..writeResult = false;
      final c = fakes.controller();
      await c.init('ct-final');

      expect(await c.confirm(_rom(40, 'x.sfc')), isFalse);
      expect(fakes.writes, hasLength(1));
      expect(fakes.invalidations, isEmpty);
      expect(c.currentRomId, isNull);
      c.dispose();
    });

    test('cancelling (dispose without confirm) writes nothing', () async {
      final fakes = _Fakes();
      final c = fakes.controller();
      await c.init('ct-final');
      c.onQueryChanged('something else');
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(fakes.writes, isEmpty);
      expect(fakes.invalidations, isEmpty);
      // The pending debounce died with the controller.
      expect(fakes.searches, hasLength(1));
    });
  });

  group('errors', () {
    test('a failed search is an error state that a retry clears', () async {
      final fakes = _Fakes();
      var fail = true;
      fakes.answer = (search) async {
        if (fail) throw StateError('connection refused');
        return RommRomPage(items: [_rom(40, 'ct.sfc')]);
      };
      final c = fakes.controller();
      await c.init('ct-final');

      expect(c.status, RommMatchPickerStatus.error);
      expect(c.results, isEmpty);
      final error = c.lastError;
      expect(error, isA<RommMatchSearchException>());
      expect(error!.query, 'ct-final');
      expect(error.platformIds, [3, 7]);
      expect(error.cause, isA<StateError>());
      expect(error.toString(), contains('connection refused'));

      fail = false;
      await c.searchNow('ct-final');

      expect(c.status, RommMatchPickerStatus.ready);
      expect(c.lastError, isNull);
      expect(c.results.map((r) => r.id), [40]);
      expect(fakes.searches, hasLength(2));
      c.dispose();
    });

    test('platform scope failing leaves the search unscoped', () async {
      final fakes = _Fakes();
      final c = RommMatchPickerController(
        linkKey: 'ct-final.sfc',
        syncKey: 'ct-final',
        systemFolder: 'snes',
        systemRealName: 'Super Nintendo',
        searchRoms:
            ({
              required String search,
              required List<int> platformIds,
              required int limit,
            }) {
              fakes.searches.add((
                search: search,
                platformIds: platformIds,
                limit: limit,
              ));
              return fakes.answer(search);
            },
        platformIdsFor: (_) async => throw StateError('no platforms'),
        readMapping: () async => null,
        writeMapping: fakes.controller().writeMapping,
        invalidateSyncState: fakes.invalidations.add,
      );
      await c.init('ct-final');

      expect(c.isScoped, isFalse);
      expect(fakes.searches.single.platformIds, isEmpty);
      expect(c.status, RommMatchPickerStatus.ready);
      c.dispose();
    });
  });

  group('preselected', () {
    test('is pinned at the top when the search does not return it', () async {
      final fakes = _Fakes();
      final pinned = _rom(9, 'pinned.sfc', name: 'Pinned');
      final c = fakes.controller(preselected: pinned);
      await c.init('Pinned');

      expect(c.results.map((r) => r.id), [9, 40]);
      expect(c.preselectedIndex, 0);
      c.dispose();
    });

    test('is not duplicated when the search already returns it', () async {
      final fakes = _Fakes();
      final pinned = _rom(40, 'Chrono Trigger (USA).sfc');
      final c = fakes.controller(preselected: pinned);
      await c.init('Chrono');

      expect(c.results.map((r) => r.id), [40]);
      expect(c.preselectedIndex, 0);
      c.dispose();
    });
  });

  group('cleaned queries', () {
    test('init pre-fills and searches the cleaned title', () async {
      final fakes = _Fakes();
      final c = fakes.controller();
      final initialized = c.init('Chrono Trigger (USA) [EN,FR]');
      // Readable before the scope resolves, so the field shows it at once.
      expect(c.prefilledQuery, 'Chrono Trigger');
      await initialized;

      expect(fakes.searches, hasLength(1));
      expect(fakes.searches.single.search, 'Chrono Trigger');
      expect(c.queryWasCleaned, isFalse);
      expect(c.cleanedQuery, isNull);
      expect(c.status, RommMatchPickerStatus.ready);
      c.dispose();
    });

    test('a raw query with no results is retried once, cleaned', () async {
      final fakes = _Fakes();
      fakes.answer = (search) async => RommRomPage(
        items: search == 'Zelda' ? [_rom(5, 'zelda.sfc')] : const [],
      );
      final c = fakes.controller();
      await c.init('Zelda');
      fakes.searches.clear();
      var notifications = 0;
      c.addListener(() => notifications++);

      await c.searchNow('Zelda (Europe) [!]');

      expect(fakes.searches.map((s) => s.search), [
        'Zelda (Europe) [!]',
        'Zelda',
      ]);
      expect(fakes.searches.last.platformIds, [3, 7]);
      expect(c.status, RommMatchPickerStatus.ready);
      expect(c.results.map((r) => r.id), [5]);
      expect(c.queryWasCleaned, isTrue);
      expect(c.cleanedQuery, 'Zelda');
      expect(notifications, greaterThan(0));
      c.dispose();
    });

    test('no retry when the cleaned form equals the raw query', () async {
      final fakes = _Fakes();
      fakes.answer = (_) async => const RommRomPage(items: []);
      final c = fakes.controller();

      await c.searchNow('Zelda');

      expect(fakes.searches, hasLength(1));
      expect(c.status, RommMatchPickerStatus.ready);
      expect(c.results, isEmpty);
      expect(c.queryWasCleaned, isFalse);
      c.dispose();
    });

    test('the cleaned retry is never itself retried', () async {
      final fakes = _Fakes();
      fakes.answer = (_) async => const RommRomPage(items: []);
      final c = fakes.controller();

      await c.searchNow('Zelda (Europe)');

      expect(fakes.searches.map((s) => s.search), ['Zelda (Europe)', 'Zelda']);
      expect(c.status, RommMatchPickerStatus.ready);
      expect(c.results, isEmpty);
      // Still marked: the user should know both forms were tried.
      expect(c.queryWasCleaned, isTrue);
      expect(c.cleanedQuery, 'Zelda');
      c.dispose();
    });

    test('the flag is cleared by the next search', () async {
      final fakes = _Fakes();
      fakes.answer = (search) async => RommRomPage(
        items: search.contains('(') ? const [] : [_rom(5, 'x.sfc')],
      );
      final c = fakes.controller();

      await c.searchNow('Zelda (Europe)');
      expect(c.queryWasCleaned, isTrue);

      await c.searchNow('Chrono');
      expect(c.queryWasCleaned, isFalse);
      expect(c.cleanedQuery, isNull);
      expect(fakes.searches, hasLength(3));
      c.dispose();
    });

    test('the flag is cleared as soon as the user edits the field', () async {
      final fakes = _Fakes();
      fakes.answer = (search) async => RommRomPage(
        items: search.contains('(') ? const [] : [_rom(5, 'x.sfc')],
      );
      final c = fakes.controller(debounce: const Duration(milliseconds: 30));
      await c.searchNow('Zelda (Europe)');
      expect(c.queryWasCleaned, isTrue);
      var notified = false;
      c.addListener(() => notified = true);

      c.onQueryChanged('Zelda (Europ');

      expect(c.queryWasCleaned, isFalse);
      expect(notified, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      c.dispose();
    });

    test('a failed search is not retried with the cleaned form', () async {
      final fakes = _Fakes();
      fakes.answer = (_) async => throw StateError('connection refused');
      final c = fakes.controller();

      await c.searchNow('Zelda (Europe)');

      expect(fakes.searches, hasLength(1));
      expect(c.status, RommMatchPickerStatus.error);
      expect(c.lastError?.query, 'Zelda (Europe)');
      expect(c.queryWasCleaned, isFalse);
      c.dispose();
    });

    test(
      'a retry that fails clears the flag and reports the cleaned query',
      () async {
        final fakes = _Fakes();
        fakes.answer = (search) async {
          if (search == 'Zelda') throw StateError('timeout');
          return const RommRomPage(items: []);
        };
        final c = fakes.controller();

        await c.searchNow('Zelda (Europe)');

        expect(fakes.searches, hasLength(2));
        expect(c.status, RommMatchPickerStatus.error);
        expect(c.lastError?.query, 'Zelda');
        expect(c.queryWasCleaned, isFalse);
        c.dispose();
      },
    );

    test('a retry superseded by a newer search is dropped', () async {
      final fakes = _Fakes();
      final retry = Completer<RommRomPage>();
      fakes.answer = (search) {
        if (search == 'Zelda') return retry.future;
        return Future.value(
          RommRomPage(
            items: search == 'Chrono' ? [_rom(7, 'ct.sfc')] : const [],
          ),
        );
      };
      final c = fakes.controller();

      final first = c.searchNow('Zelda (Europe)');
      // Let the raw search resolve and the retry start.
      await Future<void>.delayed(Duration.zero);
      expect(fakes.searches.map((s) => s.search), ['Zelda (Europe)', 'Zelda']);

      await c.searchNow('Chrono');
      retry.complete(RommRomPage(items: [_rom(5, 'zelda.sfc')]));
      await first;

      expect(c.results.map((r) => r.id), [7]);
      expect(c.queryWasCleaned, isFalse);
      c.dispose();
    });

    test(
      'a keystroke during the raw request wins over the cleaned retry',
      () async {
        final fakes = _Fakes();
        final raw = Completer<RommRomPage>();
        fakes.answer = (search) {
          if (search == 'Zelda (Europe)') return raw.future;
          return Future.value(
            RommRomPage(
              items: search == 'Chrono' ? [_rom(7, 'ct.sfc')] : const [],
            ),
          );
        };
        final c = fakes.controller(debounce: const Duration(milliseconds: 30));

        final rawSearch = c.searchNow('Zelda (Europe)');
        // The user keeps typing while the raw request is in flight...
        c.onQueryChanged('Chrono');
        // ...and the empty raw response lands before the debounce fires.
        raw.complete(const RommRomPage(items: []));
        await rawSearch;

        // The cleaned retry never ran, so nothing is marked as cleaned.
        expect(fakes.searches.map((s) => s.search), ['Zelda (Europe)']);
        expect(c.queryWasCleaned, isFalse);
        expect(c.cleanedQuery, isNull);

        // The pending search still fires for the text the field holds.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(fakes.searches.map((s) => s.search), [
          'Zelda (Europe)',
          'Chrono',
        ]);
        expect(c.status, RommMatchPickerStatus.ready);
        expect(c.results.map((r) => r.id), [7]);
        expect(c.queryWasCleaned, isFalse);
        c.dispose();
      },
    );
  });
}
