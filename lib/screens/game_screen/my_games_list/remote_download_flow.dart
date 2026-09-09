import '../../../models/game_model.dart';
import '../../../models/romm_rom.dart';
import '../../../providers/romm_provider.dart';
import '../../../widgets/remote_entry_badge.dart';

/// What a press on a remote entry led to, for the host to report.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
enum RemoteDownloadOutcome {
  /// The entry was not remote, or nothing applied: no action taken.
  nothing,

  /// The server is unreachable: the "not available offline" notice, and no
  /// request of any kind.
  offlineNotice,

  /// The catalog no longer has the ROM (deleted on the server since the list
  /// was built): the "not downloaded" notice.
  notCatalogued,

  /// The user declined the confirmation: nothing started.
  declined,

  /// The download was started.
  started,

  /// The bytes are down and the settle rescan has yet to index the file.
  waiting,

  /// The user kept the running download.
  cancelDeclined,

  /// Cancellation was requested for the running download.
  cancelRequested,
}

/// What the confirmation shows before a download starts.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
class RemoteDownloadRequest {
  /// The catalog's copy of the ROM, as [RommProvider.downloadRom] takes it.
  final RommRom rom;

  /// The name the list shows for the entry.
  final String name;

  /// The formatted size, or null when the server sent none.
  final String? sizeLabel;

  /// The folder the file would land in, or null when no ROM folder is
  /// writable (the download would then fail with that reason).
  final String? destination;

  const RemoteDownloadRequest({
    required this.rom,
    required this.name,
    required this.sizeLabel,
    required this.destination,
  });
}

/// The decision a press on a remote entry goes through, with every effect
/// injected so the order of checks can be pinned without a screen.
///
/// The rules are SPEC-0019's: an unreachable server answers with a notice and
/// sends nothing; otherwise the catalog row becomes the ROM to download, its
/// destination is resolved without creating anything, the user confirms name,
/// size and folder, and only then does the download start. A press while a
/// download runs asks before cancelling it, and a press on a finished-but-
/// unindexed entry waits for the settle rescan.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
class RemoteDownloadFlow {
  final RommReachability Function() reachability;
  final Future<RommRom?> Function(int rommRomId) lookupRom;
  final Future<String?> Function(RommRom rom) resolveDestination;
  final Future<bool> Function(RemoteDownloadRequest request) confirmDownload;
  final Future<bool> Function(GameModel game) confirmCancel;
  final void Function(RommRom rom) startDownload;
  final void Function(int rommRomId) cancelDownload;

  const RemoteDownloadFlow({
    required this.reachability,
    required this.lookupRom,
    required this.resolveDestination,
    required this.confirmDownload,
    required this.confirmCancel,
    required this.startDownload,
    required this.cancelDownload,
  });

  /// The confirm press (A, the footer button, a second tap) on [game], given
  /// its tracker's [status].
  Future<RemoteDownloadOutcome> press(
    GameModel game,
    RommDownloadStatus? status,
  ) async {
    final romId = game.rommRomId;
    if (!game.isRemote || romId == null) return RemoteDownloadOutcome.nothing;
    final state = remoteEntryStateFor(game, status);
    switch (remoteEntryActionFor(state, status: status)) {
      case RemoteEntryAction.play:
        return RemoteDownloadOutcome.nothing;
      case RemoteEntryAction.wait:
        return RemoteDownloadOutcome.waiting;
      case RemoteEntryAction.cancel:
        return cancel(game);
      case RemoteEntryAction.download:
      case RemoteEntryAction.retry:
        return download(game);
    }
  }

  /// The "Download" route (the context menu's item, and what [press] takes
  /// for a remote or failed entry): offline check, catalog lookup,
  /// destination, confirmation, start.
  Future<RemoteDownloadOutcome> download(GameModel game) async {
    final romId = game.rommRomId;
    if (!game.isRemote || romId == null) return RemoteDownloadOutcome.nothing;
    if (reachability() == RommReachability.offline) {
      return RemoteDownloadOutcome.offlineNotice;
    }
    final rom = await lookupRom(romId);
    if (rom == null) return RemoteDownloadOutcome.notCatalogued;
    final destination = await resolveDestination(rom);
    final confirmed = await confirmDownload(
      RemoteDownloadRequest(
        rom: rom,
        name: game.name.isNotEmpty ? game.name : rom.name,
        sizeLabel: remoteEntrySizeLabel(game),
        destination: destination,
      ),
    );
    if (!confirmed) return RemoteDownloadOutcome.declined;
    startDownload(rom);
    return RemoteDownloadOutcome.started;
  }

  /// The "Cancel download" route: ask, then request cancellation.
  Future<RemoteDownloadOutcome> cancel(GameModel game) async {
    final romId = game.rommRomId;
    if (!game.isRemote || romId == null) return RemoteDownloadOutcome.nothing;
    if (!await confirmCancel(game)) return RemoteDownloadOutcome.cancelDeclined;
    cancelDownload(romId);
    return RemoteDownloadOutcome.cancelRequested;
  }
}
