part of '../my_games_list.dart';

/// Downloading a remote entry from the game list.
///
/// The confirm press on a remote entry lands here instead of the emulator
/// launch: the file is not on the device, so A means Download (Cancel while
/// it transfers, Retry after a failure). The decision itself lives in
/// [RemoteDownloadFlow], with the dialogs, the provider calls and the notices
/// injected from this host, so the order of checks is pinned by tests without
/// a screen. All state lives on the host [State]; `setState` calls route
/// through the host [rebuild] bridge.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
extension _RemoteDownload on _SystemGamesListState {
  RemoteDownloadFlow _remoteDownloadFlow() => RemoteDownloadFlow(
    reachability: () => _rommProvider.reachability,
    lookupRom: _rommProvider.catalogRomFor,
    resolveDestination: (rom) async {
      final system = await _rommProvider.resolveSystem(rom);
      if (system == null) return null;
      return _rommProvider.destinationFor(
        system,
        _configProvider.config.romFolders,
      );
    },
    confirmDownload: _confirmRemoteDownload,
    confirmCancel: _confirmRemoteCancel,
    startDownload: (rom) => unawaited(_runRemoteDownload(rom)),
    cancelDownload: _rommProvider.cancelDownload,
  );

  /// The confirm press on a remote entry: Download, Cancel or Retry by its
  /// tracker's state, or the wait notice once the bytes are down.
  Future<void> _handleRemoteEntryPress(GameModel game) async {
    final romId = game.rommRomId;
    final status = romId == null
        ? null
        : _rommProvider.downloadFor(romId)?.status;
    final outcome = await _remoteDownloadFlow().press(game, status);
    if (!mounted) return;
    _reportRemoteOutcome(outcome);
  }

  /// The context menu's "Download" item.
  Future<void> _downloadRemoteEntry(GameModel game) async {
    final outcome = await _remoteDownloadFlow().download(game);
    if (!mounted) return;
    _reportRemoteOutcome(outcome);
  }

  /// The context menu's "Cancel download" item.
  Future<void> _cancelRemoteEntryDownload(GameModel game) async {
    final outcome = await _remoteDownloadFlow().cancel(game);
    if (!mounted) return;
    _reportRemoteOutcome(outcome);
  }

  /// The notice for [outcome], where one is owed. A started download is
  /// reported by the card's progress band and the footer's Cancel, and its
  /// end by [_runRemoteDownload]; a declined dialog says nothing.
  void _reportRemoteOutcome(RemoteDownloadOutcome outcome) {
    switch (outcome) {
      case RemoteDownloadOutcome.offlineNotice:
        AppNotification.showNotification(
          context,
          AppLocale.rommRemoteOfflineNotice.getString(context),
          type: NotificationType.info,
        );
      case RemoteDownloadOutcome.notCatalogued:
        _notifyRemoteNotDownloaded();
      case RemoteDownloadOutcome.waiting:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloading.getString(context),
          type: NotificationType.info,
        );
      case RemoteDownloadOutcome.nothing:
      case RemoteDownloadOutcome.declined:
      case RemoteDownloadOutcome.started:
      case RemoteDownloadOutcome.cancelDeclined:
      case RemoteDownloadOutcome.cancelRequested:
        break;
    }
  }

  /// The confirmation before a download: name, size, destination folder.
  Future<bool> _confirmRemoteDownload(RemoteDownloadRequest request) {
    final size =
        request.sizeLabel ?? AppLocale.rommRemoteSizeUnknown.getString(context);
    // With no writable ROM folder the download will report that itself; the
    // dialog names the system folder so the line is never blank.
    final folder =
        request.destination ??
        _selectedGame?.systemFolderName ??
        widget.system.folderName;
    return ConfirmActionDialog.show(
      context,
      title: AppLocale.rommRemoteDownloadConfirmTitle.getString(context),
      body: AppLocale.rommRemoteDownloadConfirmBody
          .getString(context)
          .replaceFirst('{name}', request.name)
          .replaceFirst('{size}', size)
          .replaceFirst('{folder}', folder),
      confirmLabel: AppLocale.download.getString(context),
      icon: Symbols.cloud_download_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
  }

  /// The confirmation before a running download is cancelled — A on a
  /// downloading entry would otherwise throw away a long transfer on a slip.
  Future<bool> _confirmRemoteCancel(GameModel game) => ConfirmActionDialog.show(
    context,
    title: AppLocale.rommRemoteCancelConfirmTitle.getString(context),
    body: AppLocale.rommRemoteCancelConfirmBody
        .getString(context)
        .replaceFirst('{name}', game.name),
    confirmLabel: AppLocale.rommRemoteCancelDownload.getString(context),
    icon: Symbols.cancel_rounded,
  );

  /// Runs one download to its end and reports it. The card's band and the
  /// footer follow the tracker on their own; this only speaks when the
  /// transfer is over — and, once the settle rescan has indexed the file,
  /// offers to play it.
  Future<void> _runRemoteDownload(RommRom rom) async {
    final romFolders = _configProvider.config.romFolders;
    final result = await _rommProvider.downloadRom(
      rom,
      romFolders: romFolders,
      fileProvider: _fileProvider,
    );
    if (!mounted) return;

    switch (result.status) {
      case RommDownloadStatus.completed:
        await _offerPlayNow(rom, result);
      case RommDownloadStatus.cancelled:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadCancelled.getString(context),
          type: NotificationType.info,
        );
      case RommDownloadStatus.failed:
      case RommDownloadStatus.downloading:
        AppNotification.showNotification(
          context,
          switch (result.error) {
            RommDownloadError.noSystemMatch => AppLocale.rommNoSystemMatch,
            RommDownloadError.noWritableFolder =>
              AppLocale.rommNoWritableFolder,
            _ => AppLocale.rommDownloadFailed,
          }.getString(context),
          type: NotificationType.error,
        );
    }
  }

  /// Once the settle rescan has indexed the download, offers "Play now" one
  /// time. The list reloads on [RommProvider.libraryRevision] on its own; this
  /// waits for the local game to be in the merged list before it asks, so a
  /// yes can select and launch it. A download the scan never indexed (no
  /// settle handler, or the row not found) is reported as complete instead.
  Future<void> _offerPlayNow(RommRom rom, RommDownload tracker) async {
    await tracker.indexed.timeout(
      const Duration(seconds: 45),
      onTimeout: () {},
    );
    if (!mounted) return;
    final local = await _awaitIndexedGame(rom);
    if (!mounted) return;
    if (local == null) {
      AppNotification.showNotification(
        context,
        AppLocale.rommDownloadComplete.getString(context),
        type: NotificationType.success,
      );
      return;
    }
    final play = await ConfirmActionDialog.show(
      context,
      title: AppLocale.rommRemoteDownloadReadyTitle.getString(context),
      body: AppLocale.rommRemoteDownloadReadyBody
          .getString(context)
          .replaceFirst('{name}', local.name),
      confirmLabel: AppLocale.rommRemotePlayNow.getString(context),
      cancelLabel: AppLocale.rommRemotePlayLater.getString(context),
      icon: Symbols.play_arrow_rounded,
      accentColor: Theme.of(context).colorScheme.primary,
    );
    if (!mounted || !play) return;
    final index = _gameIndexMap[local] ?? _games.indexOf(local);
    if (index == -1) return;
    await _selectGame(_games[index]);
    if (!mounted) return;
    await _selectCurrentGame();
  }

  /// The local game the download became, once the reload that follows the
  /// settle has put it in the list. Matched by the name the scan indexed
  /// (the .m3u for an unpacked multi-disc ROM), read back from the link row
  /// the download wrote. A few short retries cover the reload racing this.
  Future<GameModel?> _awaitIndexedGame(RommRom rom) async {
    final system = await _rommProvider.resolveSystem(rom);
    if (system == null) return null;
    final indexedName = await RommSaveMapRepository.getIndexedNameForRomId(
      rom.id,
      system.folderName,
    );
    if (indexedName == null) return null;
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!mounted) return null;
      for (final game in _allGames) {
        if (!game.isRemote && game.romname == indexedName) return game;
      }
      await _loadGames();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }
}
