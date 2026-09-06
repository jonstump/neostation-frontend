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
const String kCollectionMenuViewMode = 'view_mode';

/// The menu's entries, top to bottom, for a collection with or without
/// artwork and with or without RomM provenance.
///
/// The per-collection entries come first, in the order they have always had;
/// "Unlink from RomM" is appended to that group only for a mirrored
/// collection, so the entries above it keep their positions. The view-mode
/// entry closes the menu below its hairline.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Mirrored Collections In The Browser"
List<String> collectionMenuIds({
  required bool hasImage,
  required bool isRommMirror,
}) => [
  kCollectionMenuRename,
  kCollectionMenuChangeImage,
  if (hasImage) kCollectionMenuRemoveImage,
  kCollectionMenuDelete,
  if (isRommMirror) kCollectionMenuUnlinkRomm,
  kCollectionMenuViewMode,
];
