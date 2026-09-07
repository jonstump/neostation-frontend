import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/romm_browse_header_slots.dart';

/// The RomM browse screen's header arithmetic, walked through every
/// present/absent combination of the two SPEC-0018 actions.
///
/// This exists because both browse stories append a *conditionally present*
/// header action whose condition resolves after the first build — "Surprise
/// me" when the heartbeat says the server answers `/api/roms/random`, "Server
/// maintenance" when the login settles the `tasks.run` scope. A header whose
/// length changes under a bare integer cursor is how the firmware panel
/// accumulated its navigation bugs, so what is pinned here is:
///
/// * every pre-existing index still means the same control in every
///   combination (appending, not inserting);
/// * a cursor never lands past the end or on a stale control when the row is
///   rebuilt;
/// * a cursor follows the control it was on rather than its number, including
///   through the one insertion the ROM header cannot avoid (the clear button
///   appearing inside the search field as the user types).
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Filter Menu And Chips", REQ "Surprise Me", REQ "Maintenance
/// Tasks"
void main() {
  group('account header slots', () {
    test('save-sync and disconnect keep indices 0 and 1 in both cases', () {
      for (final maintenance in [false, true]) {
        final slots = rommAccountHeaderSlots(maintenance: maintenance);
        expect(
          slots.indexOf(RommAccountHeaderSlot.saveSync),
          0,
          reason: 'maintenance=$maintenance',
        );
        expect(
          slots.indexOf(RommAccountHeaderSlot.disconnect),
          1,
          reason: 'maintenance=$maintenance',
        );
      }
    });

    test('maintenance is appended last, and only when granted', () {
      expect(rommAccountHeaderSlots(maintenance: false), [
        RommAccountHeaderSlot.saveSync,
        RommAccountHeaderSlot.disconnect,
      ]);
      expect(rommAccountHeaderSlots(maintenance: true), [
        RommAccountHeaderSlot.saveSync,
        RommAccountHeaderSlot.disconnect,
        RommAccountHeaderSlot.maintenance,
      ]);
    });

    test('the scope resolving after first build never moves the cursor', () {
      final before = rommAccountHeaderSlots(maintenance: false);
      final after = rommAccountHeaderSlots(maintenance: true);
      for (var i = 0; i < before.length; i++) {
        expect(
          rommReanchorSlot(before, after, i),
          i,
          reason: 'index $i moved when maintenance appeared',
        );
      }
    });

    test('losing the scope pulls a cursor off it back into range', () {
      final before = rommAccountHeaderSlots(maintenance: true);
      final after = rommAccountHeaderSlots(maintenance: false);
      // Parked on the maintenance button when the scope goes away.
      final landed = rommReanchorSlot(before, after, 2);
      expect(landed, lessThan(after.length));
      expect(after[landed], RommAccountHeaderSlot.disconnect);
    });
  });

  group('ROM view header slots', () {
    /// Every combination of the two conditional members.
    const combos = [
      (canClear: false, surpriseMe: false),
      (canClear: false, surpriseMe: true),
      (canClear: true, surpriseMe: false),
      (canClear: true, surpriseMe: true),
    ];

    test('the search field is index 0 in all four combinations', () {
      for (final c in combos) {
        final slots = rommRomHeaderSlots(
          canClear: c.canClear,
          surpriseMe: c.surpriseMe,
        );
        expect(slots.first, RommRomHeaderSlot.searchField, reason: '$c');
      }
    });

    test('each combination draws exactly the controls it should', () {
      expect(rommRomHeaderSlots(canClear: false, surpriseMe: false), [
        RommRomHeaderSlot.searchField,
        RommRomHeaderSlot.filters,
      ]);
      expect(rommRomHeaderSlots(canClear: false, surpriseMe: true), [
        RommRomHeaderSlot.searchField,
        RommRomHeaderSlot.filters,
        RommRomHeaderSlot.surpriseMe,
      ]);
      expect(rommRomHeaderSlots(canClear: true, surpriseMe: false), [
        RommRomHeaderSlot.searchField,
        RommRomHeaderSlot.clearSearch,
        RommRomHeaderSlot.filters,
      ]);
      expect(rommRomHeaderSlots(canClear: true, surpriseMe: true), [
        RommRomHeaderSlot.searchField,
        RommRomHeaderSlot.clearSearch,
        RommRomHeaderSlot.filters,
        RommRomHeaderSlot.surpriseMe,
      ]);
    });

    test('"Surprise me" appearing leaves every other index untouched', () {
      for (final canClear in [false, true]) {
        final before = rommRomHeaderSlots(
          canClear: canClear,
          surpriseMe: false,
        );
        final after = rommRomHeaderSlots(canClear: canClear, surpriseMe: true);
        for (var i = 0; i < before.length; i++) {
          expect(
            rommReanchorSlot(before, after, i),
            i,
            reason: 'canClear=$canClear index=$i',
          );
          expect(after[i], before[i]);
        }
      }
    });

    test(
      'typing inserts the clear button and the cursor follows its control',
      () {
        for (final surpriseMe in [false, true]) {
          final empty = rommRomHeaderSlots(
            canClear: false,
            surpriseMe: surpriseMe,
          );
          final typed = rommRomHeaderSlots(
            canClear: true,
            surpriseMe: surpriseMe,
          );
          for (var i = 0; i < empty.length; i++) {
            final landed = rommReanchorSlot(empty, typed, i);
            expect(
              typed[landed],
              empty[i],
              reason: 'surpriseMe=$surpriseMe index=$i changed control',
            );
          }
          // The filter action is exactly one to the right once the clear
          // button exists — the shift the naive integer cursor got wrong.
          expect(
            rommReanchorSlot(
              empty,
              typed,
              empty.indexOf(RommRomHeaderSlot.filters),
            ),
            empty.indexOf(RommRomHeaderSlot.filters) + 1,
          );
        }
      },
    );

    test('clearing the field never strands the cursor on a gone control', () {
      for (final surpriseMe in [false, true]) {
        final typed = rommRomHeaderSlots(
          canClear: true,
          surpriseMe: surpriseMe,
        );
        final empty = rommRomHeaderSlots(
          canClear: false,
          surpriseMe: surpriseMe,
        );
        for (var i = 0; i < typed.length; i++) {
          final landed = rommReanchorSlot(typed, empty, i);
          expect(landed, inInclusiveRange(0, empty.length - 1));
          // The clear button is the only control that disappears; every other
          // cursor keeps its control.
          if (typed[i] != RommRomHeaderSlot.clearSearch) {
            expect(empty[landed], typed[i], reason: 'index $i');
          }
        }
      }
    });
  });

  group('rommReanchorSlot', () {
    test('an index past the end is clamped into the new row', () {
      final next = rommRomHeaderSlots(canClear: false, surpriseMe: false);
      expect(rommReanchorSlot(const <RommRomHeaderSlot>[], next, 99), 1);
    });

    test('a negative index is clamped to the first control', () {
      final next = rommRomHeaderSlots(canClear: true, surpriseMe: true);
      expect(rommReanchorSlot(next, next, -3), 0);
    });

    test('an empty row yields 0 rather than throwing', () {
      expect(
        rommReanchorSlot(
          const [RommAccountHeaderSlot.saveSync],
          const <RommAccountHeaderSlot>[],
          0,
        ),
        0,
      );
    });

    test('an unchanged row is the identity for every valid index', () {
      final slots = rommRomHeaderSlots(canClear: true, surpriseMe: true);
      for (var i = 0; i < slots.length; i++) {
        expect(rommReanchorSlot(slots, slots, i), i);
      }
    });
  });
}
