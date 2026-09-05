/// The Manage tab's fixed navigation layout: which index is which row, and
/// which rows can take focus in a given state.
///
/// Indices are fixed so focus doesn't jump around when cloud sync visibility
/// or the RomM state changes; new rows are appended, never inserted. Kept as a
/// pure class so the gating rules are unit-testable without widgets, the way
/// `rommLinkStateOf` is for the state line.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-Game Fetch Action"
abstract final class ManageTabLayout {
  static const int cloudSync = 0;
  static const int playTime = 1;
  static const int hide = 2;
  static const int delete = 3;
  static const int linkRomm = 4;
  static const int unlinkRomm = 5;

  /// "Fetch metadata from RomM", appended after Unlink so indices 0-5 keep
  /// their meaning.
  static const int fetchRommMetadata = 6;

  static const int total = 7;

  /// Whether [idx] can receive focus.
  ///
  /// Cloud sync needs an authenticated sync provider, Link needs a RomM
  /// connection, Unlink needs a mapping row, and Fetch needs both a row and a
  /// connection (there is nothing to fetch without an id, and nowhere to fetch
  /// it from without a server).
  static bool isEnabled(
    int idx, {
    required bool showCloudSync,
    required bool rommConnected,
    required bool hasRommLink,
  }) {
    if (idx == cloudSync && !showCloudSync) return false;
    if (idx == linkRomm && !rommConnected) return false;
    if (idx == unlinkRomm && !hasRommLink) return false;
    if (idx == fetchRommMetadata && !(hasRommLink && rommConnected)) {
      return false;
    }
    return idx >= 0 && idx < total;
  }
}
