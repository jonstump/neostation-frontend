/// Result ids of the collections browser's per-collection menu, and the pure
/// layout that decides which of them a given collection gets.
///
/// Kept apart from the screen so the layout is testable without a widget
/// tree: the screen maps each id to its label and icon and dispatches on it.
library;

const String kCollectionMenuRename = 'rename';
const String kCollectionMenuChangeImage = 'change_image';
const String kCollectionMenuRemoveImage = 'remove_image';
const String kCollectionMenuDelete = 'delete';
const String kCollectionMenuUnlinkRomm = 'unlink_romm';
const String kCollectionMenuPushRomm = 'push_romm';
const String kCollectionMenuViewMode = 'view_mode';

/// The menu's entries, top to bottom, for a collection with or without
/// artwork and with or without RomM provenance.
///
/// The per-collection entries come first, in the order they have always had;
/// the RomM entry is appended to that group so the entries above it keep
/// their positions: "Unlink from RomM" for a linked collection — a mirror
/// ([isRommMirror]) or one pushed from this device ([isPushedToRomm]) —
/// and "Push to RomM" for an unlinked one while [canPushToRomm] (a
/// connected server whose login may write collections). The two never
/// appear together: one writer per collection (ADR-0015). The view-mode
/// entry closes the menu below its hairline.
///
/// The favourites collection of SPEC-0013 is RomM's, not a local
/// collection — favourites here are a flag on the ROM — so the only local
/// row that can stand for it is a mirror of it, which the provenance rule
/// already keeps off the push entry.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Mirrored Collections In The Browser"
// Governing: ADR-0015 (collections push), SPEC-0015 REQ "Push Action", REQ "Origin Badge"
List<String> collectionMenuIds({
  required bool hasImage,
  required bool isRommMirror,
  bool isPushedToRomm = false,
  bool canPushToRomm = false,
}) {
  final linked = isRommMirror || isPushedToRomm;
  return [
    kCollectionMenuRename,
    kCollectionMenuChangeImage,
    if (hasImage) kCollectionMenuRemoveImage,
    kCollectionMenuDelete,
    if (linked) kCollectionMenuUnlinkRomm,
    if (!linked && canPushToRomm) kCollectionMenuPushRomm,
    kCollectionMenuViewMode,
  ];
}
