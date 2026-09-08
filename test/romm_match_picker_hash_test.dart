import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/rom_fingerprint.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_match_picker_controller.dart';
import 'package:neostation/services/rom_fingerprint_service.dart';

/// The link picker's "Match by hash" (SPEC-0011 "Match By Hash In The
/// Picker") against hand-written fakes: the action is offered only when the
/// server is not known to lack the endpoint and both halves are wired; a hit
/// pins the ROM first and pre-selects it, and confirming it writes the manual
/// row exactly as a searched row does; a miss keeps the search results; a
/// fingerprint skip surfaces its reason; a cancelled run drops the result
/// that arrives later; and a second press while busy costs nothing.
///
/// Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Match By Hash
/// In The Picker"

RommRom _rom(int id) => RommRom(
  id: id,
  name: 'Rom $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'rom$id.sfc',
  fsNameNoExt: 'rom$id',
  fsExtension: 'sfc',
);

const _fingerprint = RomFingerprint(
  crc32: 'DEADBEEF',
  md5: '0123456789abcdef0123456789abcdef',
  sizeBytes: 4096,
);

typedef _Printed = ({RomFingerprint? fingerprint, String? skipReason});

class _Fakes {
  int fingerprints = 0;
  final lookups = <RomFingerprint>[];
  final writes = <int>[];
  List<RommRom> page = [_rom(40), _rom(41)];

  Future<_Printed> Function() printer = () async =>
      (fingerprint: _fingerprint, skipReason: null);
  Future<RommRom?> Function(RomFingerprint) lookup = (_) async => _rom(41);

  RommMatchPickerController controller({
    bool hashLookupAvailable = true,
    bool wireFingerprint = true,
    bool wireLookup = true,
    RommRom? preselected,
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
        }) async => RommRomPage(items: page, total: page.length),
    platformIdsFor: (_) async => const [1],
    readMapping: () async => null,
    writeMapping:
        ({
          required String romname,
          required String systemFolder,
          required int rommRomId,
          String? fsName,
        }) async {
          writes.add(rommRomId);
          return true;
        },
    invalidateSyncState: (_) {},
    fetchMetadata: (_) async => const RommMetadataOutcome(
      kind: RommMetadataOutcomeKind.filled,
      columnsWritten: 1,
    ),
    preselected: preselected,
    hashLookupAvailable: hashLookupAvailable,
    fingerprintFile: wireFingerprint
        ? () {
            fingerprints++;
            return printer();
          }
        : null,
    lookupByHash: wireLookup
        ? (fingerprint) {
            lookups.add(fingerprint);
            return lookup(fingerprint);
          }
        : null,
    debounce: const Duration(milliseconds: 10),
  );
}

void main() {
  group('availability', () {
    test('the action is hidden when the server is known to lack it', () {
      final c = _Fakes().controller(hashLookupAvailable: false);
      expect(c.hashLookupAvailable, isFalse);
      c.dispose();
    });

    test('the action is hidden when either half is not wired', () {
      final fakes = _Fakes();
      final noPrint = fakes.controller(wireFingerprint: false);
      final noLookup = fakes.controller(wireLookup: false);
      expect(noPrint.hashLookupAvailable, isFalse);
      expect(noLookup.hashLookupAvailable, isFalse);
      noPrint.dispose();
      noLookup.dispose();
    });

    test('the action is offered when supported or unknown and wired', () {
      final c = _Fakes().controller();
      expect(c.hashLookupAvailable, isTrue);
      c.dispose();
    });

    test('a press while unavailable does nothing', () async {
      final fakes = _Fakes();
      final c = fakes.controller(hashLookupAvailable: false);
      await c.init('ct-final');

      await c.matchByHash();

      expect(fakes.fingerprints, 0);
      expect(fakes.lookups, isEmpty);
      expect(c.hashStatus, RommMatchByHashStatus.idle);
      c.dispose();
    });
  });

  group('a hit', () {
    // Scenario "Hit": the ROM is preselected and confirming writes a manual
    // row as today.
    test('pins the ROM first, preselects it, and confirm writes it', () async {
      final fakes = _Fakes();
      final c = fakes.controller();
      await c.init('ct-final');
      expect(c.results.map((r) => r.id), [40, 41]);

      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.hit);
      expect(fakes.lookups.single.crc32, 'DEADBEEF');
      expect(c.results.map((r) => r.id), [41, 40], reason: 'hit goes first');
      expect(c.preselectedIndex, 0);
      expect(c.pinnedRom?.id, 41);

      expect(await c.confirm(c.results[c.preselectedIndex]), isTrue);
      expect(fakes.writes, [41]);
      c.dispose();
    });

    test('a ROM the search never listed is prepended', () async {
      final fakes = _Fakes()..lookup = (_) async => _rom(99);
      final c = fakes.controller();
      await c.init('ct-final');

      await c.matchByHash();

      expect(c.results.map((r) => r.id), [99, 40, 41]);
      expect(c.preselectedIndex, 0);
      c.dispose();
    });

    test('outranks the caller\'s preselected row', () async {
      final fakes = _Fakes();
      final c = fakes.controller(preselected: _rom(40));
      await c.init('ct-final');
      expect(c.preselectedIndex, 0);
      expect(c.pinnedRom?.id, 40);

      await c.matchByHash();

      expect(c.pinnedRom?.id, 41);
      expect(c.results.map((r) => r.id), [41, 40]);
      expect(c.preselectedIndex, 0);
      c.dispose();
    });

    test('stays pinned first through a later search', () async {
      final fakes = _Fakes()..lookup = (_) async => _rom(99);
      final c = fakes.controller();
      await c.init('ct-final');
      await c.matchByHash();
      expect(c.results.first.id, 99);

      await c.searchNow('something else');

      expect(c.results.map((r) => r.id), [99, 40, 41]);
      expect(c.preselectedIndex, 0);
      c.dispose();
    });
  });

  group('a miss, a skip, a failure', () {
    // Scenario "Miss": the picker shows the no-match line and keeps its
    // search results.
    test('a miss keeps the search results', () async {
      final fakes = _Fakes()..lookup = (_) async => null;
      final c = fakes.controller();
      await c.init('ct-final');

      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.miss);
      expect(c.results.map((r) => r.id), [40, 41]);
      expect(c.pinnedRom, isNull);
      expect(c.preselectedIndex, -1);
      c.dispose();
    });

    test('a fingerprint skip surfaces its reason and asks nothing', () async {
      final fakes = _Fakes()
        ..printer = () async =>
            (fingerprint: null, skipReason: RomFingerprintService.skipDisc);
      final c = fakes.controller();
      await c.init('ct-final');

      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.skipped);
      expect(c.hashSkipReason, RomFingerprintService.skipDisc);
      expect(fakes.lookups, isEmpty);
      expect(c.results.map((r) => r.id), [40, 41]);
      c.dispose();
    });

    test('a lookup that throws is a failure, not a miss', () async {
      final fakes = _Fakes()..lookup = (_) async => throw StateError('down');
      final c = fakes.controller();
      await c.init('ct-final');

      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.error);
      expect(c.hashError, isA<StateError>());
      expect(c.results.map((r) => r.id), [40, 41]);
      c.dispose();
    });

    test('a fingerprint that throws is a failure too', () async {
      final fakes = _Fakes()..printer = () async => throw StateError('io');
      final c = fakes.controller();
      await c.init('ct-final');

      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.error);
      expect(fakes.lookups, isEmpty);
      c.dispose();
    });

    test('a new run clears the previous outcome', () async {
      final fakes = _Fakes()..lookup = (_) async => null;
      final c = fakes.controller();
      await c.init('ct-final');
      await c.matchByHash();
      expect(c.hashStatus, RommMatchByHashStatus.miss);

      fakes.lookup = (_) async => _rom(41);
      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.hit);
      expect(c.hashSkipReason, isNull);
      expect(c.hashError, isNull);
      c.dispose();
    });

    test('a later miss drops the previous hit from the pinned row', () async {
      final fakes = _Fakes()..lookup = (_) async => _rom(41);
      final c = fakes.controller();
      await c.init('ct-final');
      await c.matchByHash();
      expect(c.hashStatus, RommMatchByHashStatus.hit);
      expect(c.pinnedRom?.id, 41);

      fakes.lookup = (_) async => null;
      await c.matchByHash();

      expect(c.hashStatus, RommMatchByHashStatus.miss);
      expect(c.hashHit, isNull);
      expect(c.pinnedRom, isNull);
      c.dispose();
    });
  });

  group('busy and cancel', () {
    test('a second press while busy is ignored', () async {
      final gate = Completer<RommRom?>();
      final fakes = _Fakes()..lookup = (_) => gate.future;
      final c = fakes.controller();
      await c.init('ct-final');

      final first = c.matchByHash();
      await Future<void>.delayed(Duration.zero);
      expect(c.isMatchingByHash, isTrue);
      await c.matchByHash();

      expect(fakes.fingerprints, 1);
      gate.complete(_rom(41));
      await first;
      expect(c.hashStatus, RommMatchByHashStatus.hit);
      c.dispose();
    });

    test('cancel discards a result that arrives afterwards', () async {
      final gate = Completer<RommRom?>();
      final fakes = _Fakes()..lookup = (_) => gate.future;
      final c = fakes.controller();
      await c.init('ct-final');
      var notifications = 0;
      c.addListener(() => notifications++);

      final run = c.matchByHash();
      await Future<void>.delayed(Duration.zero);
      expect(c.isMatchingByHash, isTrue);

      expect(c.cancelMatchByHash(), isTrue);
      expect(c.hashStatus, RommMatchByHashStatus.idle);
      final afterCancel = notifications;

      gate.complete(_rom(41));
      await run;

      expect(c.hashStatus, RommMatchByHashStatus.idle);
      expect(c.results.map((r) => r.id), [40, 41], reason: 'nothing pinned');
      expect(c.pinnedRom, isNull);
      expect(notifications, afterCancel, reason: 'the late result is silent');
      c.dispose();
    });

    test('cancel while idle reports nothing to cancel', () {
      final c = _Fakes().controller();
      expect(c.cancelMatchByHash(), isFalse);
      c.dispose();
    });

    test('a run started after a cancel is not confused with it', () async {
      final firstGate = Completer<RommRom?>();
      final fakes = _Fakes()..lookup = (_) => firstGate.future;
      final c = fakes.controller();
      await c.init('ct-final');

      final first = c.matchByHash();
      await Future<void>.delayed(Duration.zero);
      c.cancelMatchByHash();

      fakes.lookup = (_) async => _rom(99);
      await c.matchByHash();
      expect(c.hashStatus, RommMatchByHashStatus.hit);
      expect(c.results.first.id, 99);

      firstGate.complete(_rom(41));
      await first;

      expect(c.results.first.id, 99, reason: 'the stale hit did not re-pin');
      c.dispose();
    });

    test('a result after dispose is dropped', () async {
      final gate = Completer<RommRom?>();
      final fakes = _Fakes()..lookup = (_) => gate.future;
      final c = fakes.controller();
      await c.init('ct-final');

      final run = c.matchByHash();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      gate.complete(_rom(41));

      await expectLater(run, completes);
    });
  });
}
