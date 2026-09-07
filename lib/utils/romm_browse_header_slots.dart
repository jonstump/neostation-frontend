/// Which controls the RomM browse screen's two header rows carry, and where
/// the cursor lands when that answer changes underneath it.
///
/// Both SPEC-0018 browse stories add a header action, and both actions are
/// *conditionally* present — "Surprise me" only on a server new enough to
/// answer `/api/roms/random`, "Server maintenance" only on a connection that
/// holds the `tasks.run` scope — and both conditions resolve **after** the
/// first build, when the heartbeat and the scope negotiation land. A header
/// whose length changes under a bare integer cursor is how the firmware panel
/// accumulated its navigation bugs, so the arithmetic lives here as pure
/// functions the tests can walk through every present/absent combination.
///
/// Two rules make it safe:
///
/// * **Append, never insert.** A new action goes at the *end* of its row, so
///   every pre-existing index means the same control whether or not the new
///   one is there. A growing list cannot invalidate an in-range index; an
///   insert shifts everything after it.
/// * **Re-anchor by identity, not by number.** When the row is rebuilt, the
///   cursor follows the *control* it was on ([rommReanchorSlot]); only if that
///   control is gone does it fall back to a clamp, which by construction lands
///   inside the new row.
///
/// No Flutter, no provider: pure lists and indices.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Filter Menu And Chips", REQ "Surprise Me", REQ "Maintenance Tasks"
library;

/// A control on the account header — the two-line strip the browse screen
/// draws at the library root, above the source cards.
///
/// Order is cursor order, left to right. [maintenance] is last precisely
/// because it is the conditional one: with it absent the row is exactly the
/// pre-SPEC-0018 `[saveSync, disconnect]` at indices 0 and 1, and with it
/// present those two keep those indices.
// Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
enum RommAccountHeaderSlot { saveSync, disconnect, maintenance }

/// A control on the ROM view's header row — the search row above the grid,
/// which is the only header a platform or collection draws.
///
/// [clearSearch] is conditional and *not* last: it is the X inside the field,
/// so it cannot be moved to the end of the row without moving it out of the
/// field. That is exactly the case [rommReanchorSlot] exists for — typing the
/// first character inserts it and shifts [filters]/[surpriseMe] right by one,
/// and the cursor has to follow the control rather than the number.
// Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips", REQ "Surprise Me"
enum RommRomHeaderSlot { searchField, clearSearch, filters, surpriseMe }

/// The account header's controls, in cursor order.
///
/// [maintenance] is present only when the connection is known to hold the
/// `tasks.run` scope group — an unknown or denied answer leaves the action out
/// rather than offering a button that 403s.
// Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
List<RommAccountHeaderSlot> rommAccountHeaderSlots({
  required bool maintenance,
}) => [
  RommAccountHeaderSlot.saveSync,
  RommAccountHeaderSlot.disconnect,
  if (maintenance) RommAccountHeaderSlot.maintenance,
];

/// The ROM view header's controls, in cursor order.
///
/// [canClear] follows the field having text; [surpriseMe] follows the server
/// answering `/api/roms/random`. The filter menu has no gate — RomM's boolean
/// list filters predate every version NeoStation talks to — so it is always
/// drawn.
// Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips", REQ "Surprise Me"
List<RommRomHeaderSlot> rommRomHeaderSlots({
  required bool canClear,
  required bool surpriseMe,
}) => [
  RommRomHeaderSlot.searchField,
  if (canClear) RommRomHeaderSlot.clearSearch,
  RommRomHeaderSlot.filters,
  if (surpriseMe) RommRomHeaderSlot.surpriseMe,
];

/// Where the cursor at [index] of [previous] belongs in [next].
///
/// The control the cursor was on wins: if it is still in the row, the cursor
/// follows it wherever it moved, so a capability resolving (or the clear
/// button appearing as the user types) never slides the selection onto a
/// different button. If it is gone — or [index] was never valid — the result
/// is clamped into [next], so it can never point past the end or at a stale
/// slot. An empty [next] yields 0, which callers read as "nothing parked".
// Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips", REQ "Maintenance Tasks"
int rommReanchorSlot<T>(List<T> previous, List<T> next, int index) {
  if (next.isEmpty) return 0;
  if (index >= 0 && index < previous.length) {
    final moved = next.indexOf(previous[index]);
    if (moved >= 0) return moved;
  }
  return index.clamp(0, next.length - 1);
}
