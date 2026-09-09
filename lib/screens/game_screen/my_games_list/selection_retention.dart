import '../../../models/game_model.dart';

/// Where [selected] is in [games] after a reload, or -1 when it is gone.
///
/// Three keys, in order. The romname is what every reload matched on before
/// the unified library and still settles nearly all of them. The RomM rom id
/// covers the same catalog entry under a different name and a local game
/// that carries its link. [indexedName] — the on-disk name the settle rescan
/// indexed a download under, read from the link row — is what a remote entry
/// that has just flipped to a local game matches by when the two names
/// differ: an unpacked multi-disc ROM is indexed as its `.m3u`, and a
/// download the destination folder needed zipped gains `.zip`. Without it
/// the selection would drop to the top of the list and "Later" on the
/// Play-now prompt would leave the user there. It never picks a remote
/// entry: the name belongs to a file on this device.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
int retainedSelectionIndex(
  List<GameModel> games,
  GameModel selected, {
  String? indexedName,
}) {
  final byName = games.indexWhere((g) => g.romname == selected.romname);
  if (byName != -1) return byName;
  final romId = selected.rommRomId;
  if (romId == null) return -1;
  final byId = games.indexWhere((g) => g.rommRomId == romId);
  if (byId != -1) return byId;
  if (indexedName == null || indexedName.isEmpty) return -1;
  return games.indexWhere((g) => !g.isRemote && g.romname == indexedName);
}
