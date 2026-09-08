part of '../neo_sync_provider.dart';

extension NeoSyncCore on NeoSyncProvider {
  Future<void> updateSelectedGame(
    String romname,
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Updates the internal state of the selected game
    _selectedGameRomname = romname;

    // Get the game model to store the name
    final gameModel = await findGameModelByRomName(romname);
    _selectedGameName = gameModel?.name ?? romname;

    // If the game does not exist in the map, add it
    if (!_gameSyncStates.containsKey(romname)) {
      _gameSyncStates[romname] = neo_sync.GameSyncState(
        gameId: romname,
        gameName: _selectedGameName!,
        status: neo_sync.GameSyncStatus.noSaveFound,
        cloudEnabled: true,
        localSave: null,
        cloudSave: null,
        lastSync: null,
        errorMessage: null,
      );
    }
    // Checks the sync state for the selected game
    await checkSelectedGameSaveStatus(findGameModelByRomName);
    notify();
  }

  /// Checks the synchronization state only for the selected game
  Future<void> checkSelectedGameSaveStatus(
    Future<GameModel?> Function(String romname) findGameModelByRomName,
  ) async {
    // Clear multi-emulator files tracking for new check (PS2 and Switch shared memory cards/saves)
    _processedMultiEmulatorFilesInSession.clear();

    if (_selectedGameRomname == null) {
      _syncStatus = 'No selected game for status check';
      _processedItems.add('No selected game for NeoSync save status check');
      NeoSyncProvider._log.w('No selected game for NeoSync save status check');
      notify();
      return;
    }

    final selectedGameState = _gameSyncStates[_selectedGameRomname];
    if (selectedGameState != null) {
      // Find the game model (GameModel) using the romname
      final selectedGameModel = await findGameModelByRomName(
        _selectedGameRomname!,
      );
      if (selectedGameModel != null) {
        // Only checks the state, does not sync
        await _checkGameSaveStatus(selectedGameModel);
        _syncStatus = 'Checked save status for selected game';
        _processedItems.add(
          'Checked save status for: ${selectedGameState.gameName}',
        );
        notify();
        return;
      } else {
        _syncStatus = 'Selected game model not found';
        _processedItems.add('Selected game model not found for status check');
        NeoSyncProvider._log.w(
          'Selected game model not found for status check',
        );
        notify();
        return;
      }
    }
    _syncStatus = 'No selected game for status check';
    _processedItems.add('No selected game for NeoSync save status check');
    NeoSyncProvider._log.w('No selected game for NeoSync save status check');
    notify();
    return;
  }

  /// Only checks the synchronization state for a game (no sync actions)
  Future<void> _checkGameSaveStatus(GameModel game) async {
    // Find local save for this game
    final localSave = await _findGameSaveFile(game);
    // Find cloud save for this game
    final cloudSave = await _getCloudSaveForGame(game, localSave: localSave);
    // Determine the synchronization state
    final syncStatus = await _calculateGameSyncStatus(localSave, cloudSave);

    // PRESERVE the quotaExceeded state if already set or if the global flag is active
    final currentState = _gameSyncStates[game.romname];
    final finalStatus =
        currentState?.status == neo_sync.GameSyncStatus.quotaExceeded ||
            _quotaExceededActive
        ? neo_sync.GameSyncStatus.quotaExceeded
        : syncStatus;

    // Update the state in the map
    _updateGameSyncState(
      game.romname,
      game.name,
      finalStatus,
      localSave: localSave,
      cloudSave: cloudSave,
    );
  }

  void setAuthService(AuthService authService) {
    _authService = authService;
    notify();
  }

  bool get isNeoSyncAuthenticated {
    return _authService?.isLoggedIn == true;
  }

  /// Unified synchronization: Uploads and downloads with automatic resolution
  Future<void> syncWithConflictResolution() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing) return;

    _setSyncing(true);
    _error = null;
    _syncProgress = 0.0;
    _syncStatus = 'Starting unified sync...';
    _totalFiles = 0;
    _processedFiles = 0;
    _uploadedFiles = 0;
    _skippedFiles = 0;
    _downloadedFiles = 0;
    _processedItems = [];

    notify();

    try {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath == null) {
        _syncStatus = 'RetroArch saves directory not found';
        _processedItems.add('RetroArch saves directory not found');
        return;
      }

      // Phase 1: Upload local files
      await _performUploadPhase(savesPath);

      // Phase 2: Download cloud files
      await _performDownloadPhase(savesPath);

      _syncProgress = 1.0;
      _syncStatus =
          'Unified sync completed: '
          '$_uploadedFiles uploaded, $_downloadedFiles downloaded, '
          '$_skippedFiles already synced';
      _processedItems.add('Unified sync completed successfully!');
    } catch (e) {
      if (e is QuotaExceededException) {
        _error = 'Storage quota exceeded after ${e.attemptCount} attempts';
        _syncStatus = 'Quota exceeded - sync stopped';
        _processedItems.add('Storage quota exceeded - sync stopped');
        NeoSyncProvider._log.e(
          'Sync stopped due to quota exceeded: ${e.message}',
        );
      } else {
        _error = 'Error during sync: $e';
        _syncStatus = 'Error: $_error';
        _processedItems.add('Sync error: $e');
        NeoSyncProvider._log.e('Unified sync error: $e');
      }
    } finally {
      _setSyncing(false);
    }
  }

  /// Steam-style auto-sync: Detects and synchronizes files automatically
  Future<void> autoSync() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (_isSyncing || _isAutoSyncing) return;

    _setAutoSyncing(true);
    try {
      await autoSyncUploads();
      await autoSyncDownloads();
    } finally {
      _setAutoSyncing(false);
    }
  }

  /// Stops the ongoing synchronization
  void stopSyncing() {
    _isSyncing = false;
    _syncStatus = 'Sync stopped by user';
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  void clearError() {
    _error = null;
    // Defer the notification to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notify();
    });
  }

  /// Enables or disables auto-sync
  void setAutoSyncEnabled(bool enabled) {
    _autoSyncEnabled = enabled;
    notify();
  }

  /// Runs auto-sync before starting a game (Steam-style)
  Future<void> syncBeforeGameStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Syncing saves before game start...');
    await autoSync();
  }

  /// Runs auto-sync after closing a game (Steam-style)
  Future<void> syncAfterGameEnd() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Syncing saves after game end...');
    await autoSyncUploads(); // Only upload local changes after the game
  }

  /// Runs only download auto-sync when initializing the app
  Future<void> syncOnAppStart() async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (!_autoSyncEnabled) return;

    _processedItems.add('Checking for cloud updates on app start...');
    await autoSyncDownloads(); // Only download on initialization
  }

  /// Resets the state of the quota exceeded dialog
  void resetQuotaExceededDialog() {
    _quotaExceededDialogShown = false;
    _quotaExceededAttempts = 0;
    _quotaExceededActive = false; // Also reset the global flag
  }

  /// Shows the quota exceeded dialog
  Future<String?> showQuotaExceededDialog(BuildContext context) async {
    if (_quotaExceededDialogShown) return null;

    _quotaExceededDialogShown = true;
    notify();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => QuotaExceededDialog(
        quota: _quota!,
        attemptCount: _quotaExceededAttempts,
        onUpgradePlan: () {
          // Navigate to the plan upgrade screen (not yet implemented).
        },
        onManageFiles: () {
          // Navigate to the file management screen (not yet implemented).
        },
      ),
    );
  }

  /// Gets all local saves with their synchronization state
  Future<List<LocalSaveFile>> getLocalSaveFiles() async {
    final savesPath = await _getRetroArchSavesPath();
    if (savesPath == null) {
      NeoSyncProvider._log.w('RetroArch saves directory not found');
      return [];
    }

    final saveFiles = await _getSaveFiles(savesPath);
    final localSaveFiles = <LocalSaveFile>[];

    // Create a map of synced files by name for quick comparison
    final syncedFilesMap = <String, NeoSyncFile>{};
    for (final syncedFile in _files) {
      // Normalize separators for consistent comparison
      final normalizedFileName = syncedFile.fileName.replaceAll('\\', '/');
      syncedFilesMap[normalizedFileName] = syncedFile;
    }

    for (final file in saveFiles) {
      try {
        final stat = await file.stat();
        final fileName = file.path.split(Platform.pathSeparator).last;
        final gameName = _extractGameNameFromPath(file.path);

        // Calculate the full relative path (same as used for uploading)
        String relativePath = '';
        final normalizedFilePath = file.path.replaceAll('\\', '/');
        final normalizedSavesPath = savesPath.replaceAll('\\', '/');

        final savesPathWithSeparator = normalizedSavesPath.endsWith('/')
            ? normalizedSavesPath
            : '$normalizedSavesPath/';

        if (normalizedFilePath.startsWith(savesPathWithSeparator)) {
          relativePath = normalizedFilePath.substring(
            savesPathWithSeparator.length,
          );
        } else {
          relativePath = fileName;
        }

        // Normalize separators for consistent comparison
        relativePath = relativePath.replaceAll('\\', '/');

        // Check whether it is synced by comparing against the cloud files using the relative path
        final syncedFile = syncedFilesMap[relativePath];
        bool isSynced = false;

        if (syncedFile != null) {
          // Compare timestamps and sizes to determine whether it is synced
          final localTimestamp = stat.modified.millisecondsSinceEpoch;
          final cloudTimestamp = syncedFile.fileModifiedAtTimestamp;

          // Treat it as synced when the timestamps match or the difference is negligible
          if (cloudTimestamp != null) {
            final timeDiff = (localTimestamp - cloudTimestamp).abs();
            isSynced = timeDiff < 1000; // 1 second of tolerance
          }

          // Also compare sizes when timestamps are unavailable
          if (!isSynced && syncedFile.fileSize == stat.size) {
            isSynced = true;
          }
        }

        localSaveFiles.add(
          LocalSaveFile(
            filePath: file.path,
            fileName: fileName,
            fileSize: stat.size,
            lastModified: stat.modified,
            gameName: gameName,
            isSynced: isSynced,
            relativePath: relativePath,
          ),
        );
      } catch (e) {
        NeoSyncProvider._log.w(
          'Error processing local save file ${file.path}: $e',
        );
      }
    }

    // Sort by modification date (most recent first)
    localSaveFiles.sort((a, b) => b.lastModified.compareTo(a.lastModified));

    return localSaveFiles;
  }

  // ==========================================
  // PER-GAME SYNCHRONIZATION METHODS
  // ==========================================

  /// Automatically detects save files for a specific game
  /// and performs an automatic sync when appropriate
  Future<void> detectGameSaveFiles(GameModel game) async {
    if (!isNeoSyncAuthenticated) {
      return;
    }
    if (game.cloudSyncEnabled != true) {
      // If sync is disabled for this game, do nothing
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // Check whether the system has sync disabled
    final system = await _getSystemForGame(game);
    if (system != null && !system.neosync.sync) {
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.disabled,
      );
      return;
    }

    // FIRST: update the state to "checking/syncing" so the user gets immediate visual feedback
    _updateGameSyncState(
      game.romname,
      game.name,
      neo_sync.GameSyncStatus.syncing,
    );

    try {
      // Identify whether this is a "shared memory cards" system
      final system = await _getSystemForGame(game);
      final isSharedSystem =
          system?.folderName == 'ps2' || system?.folderName == 'dreamcast';

      // Check whether there is a valid emulator configuration on Windows
      if (system != null && Platform.isWindows) {
        bool hasValidEmulator = true;

        if (system.id == 'switch') {
          final emulatorsList =
              await EmulatorRepository.getStandaloneEmulatorsBySystemId(
                'switch',
              );
          hasValidEmulator = false;

          // Check the user-selected one first
          for (final emu in emulatorsList) {
            if (emu['is_user_default'].toString() == '1') {
              final path = emu['emulator_path']?.toString();
              if (path != null && path.trim().isNotEmpty) {
                hasValidEmulator = true;
              }
              break;
            }
          }

          // If the user has not selected one, check the system default
          if (!hasValidEmulator &&
              !emulatorsList.any(
                (e) => e['is_user_default'].toString() == '1',
              )) {
            for (final emu in emulatorsList) {
              if (emu['is_default'].toString() == '1') {
                final path = emu['emulator_path']?.toString();
                if (path != null && path.trim().isNotEmpty) {
                  hasValidEmulator = true;
                }
                break;
              }
            }
          }
        } else {
          // For RetroArch and other systems, check whether the paths can be resolved.
          final resolvedPaths = await resolveUniversalPaths(
            system,
            game: game,
            ensureExists: false,
          );
          if (resolvedPaths.isEmpty) {
            hasValidEmulator = false;
          }
        }

        if (!hasValidEmulator) {
          NeoSyncProvider._log.w(
            'No valid emulator path configured for ${system.realName} in Windows, marking as missingEmulator',
          );
          _updateGameSyncState(
            game.romname,
            game.name,
            neo_sync.GameSyncStatus.missingEmulator,
          );
          return;
        }
      }

      // Find ALL local save files for this game (saves and states)
      final localSaveFiles = await _findGameSaveFiles(game);

      // With no local files, check whether there are cloud files to download
      if (localSaveFiles.isEmpty) {
        // Look for cloud files belonging to this game
        final cloudFiles = await _getCloudSaveFilesForGame(game);

        if (cloudFiles.isNotEmpty) {
          // Download every file from the cloud
          bool allDownloadsSucceeded = true;
          for (final cloudFile in cloudFiles) {
            final downloadSuccess = await _autoDownloadCloudSave(
              game,
              cloudFile,
            );
            if (!downloadSuccess) {
              allDownloadsSucceeded = false;
            }
          }

          // After downloading, the state updates automatically
          // But do NOT overwrite it when a quota-exceeded error is already set
          final currentState = _gameSyncStates[game.romname];
          if (currentState?.status != neo_sync.GameSyncStatus.quotaExceeded) {
            final status = allDownloadsSucceeded
                ? neo_sync.GameSyncStatus.upToDate
                : neo_sync.GameSyncStatus.upToDate;
            _updateGameSyncState(game.romname, game.name, status);
          }
          return;
        } else {
          // There are no local files and none in the cloud
          _updateGameSyncState(
            game.romname,
            game.name,
            neo_sync.GameSyncStatus.noSaveFound,
          );
          return;
        }
      }

      // There are local files; check the sync state of each one
      bool allUploadsSucceeded = true; // Track if any uploads failed
      bool quotaExceededDuringProcessing = false;
      bool allCloudDownloadsSucceeded = true;

      final cloudFiles = await _getCloudSaveFilesForGame(game);

      // 1. Check each local file against the cloud
      for (final localFile in localSaveFiles) {
        // OPTIMIZATION: if it is shared and already processed this session, skip the active sync
        if (isSharedSystem &&
            _processedMultiEmulatorFilesInSession.contains(
              localFile.filePath,
            )) {
          continue;
        }

        // Find the matching cloud file by name (relativePath is already the namespace)
        final cloudFile = cloudFiles.firstWhere(
          (cf) => cf.fileName == localFile.relativePath,
          orElse: () => NeoSyncFile(
            id: '',
            fileName: '',
            filePath: '',
            fileSize: 0,
            gameName: '',
            uploadedAt: DateTime.now(),
            userId: '',
            checksum: '',
          ),
        );

        if (cloudFile.fileName.isEmpty) {
          // It does not exist in the cloud, upload it
          try {
            final uploadSuccess = await _autoUploadLocalSave(game, localFile);
            if (!uploadSuccess) allUploadsSucceeded = false;
            if (uploadSuccess && isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(localFile.filePath);
            }
          } on QuotaExceededException {
            quotaExceededDuringProcessing = true;
            allUploadsSucceeded = false;
          }
        } else {
          // Both exist, compare them
          final syncStatus = await _calculateGameSyncStatus(
            localFile,
            cloudFile,
          );

          if (syncStatus == neo_sync.GameSyncStatus.localOnly) {
            try {
              final success = await _autoUploadLocalSave(game, localFile);
              if (!success) allUploadsSucceeded = false;
              if (success && isSharedSystem) {
                _processedMultiEmulatorFilesInSession.add(localFile.filePath);
              }
            } on QuotaExceededException {
              quotaExceededDuringProcessing = true;
              allUploadsSucceeded = false;
            }
          } else if (syncStatus == neo_sync.GameSyncStatus.cloudOnly) {
            try {
              final success = await _autoDownloadCloudSave(game, cloudFile);
              if (!success) allCloudDownloadsSucceeded = false;
              if (success && isSharedSystem) {
                _processedMultiEmulatorFilesInSession.add(localFile.filePath);
              }
            } on QuotaExceededException {
              quotaExceededDuringProcessing = true;
              allCloudDownloadsSucceeded = false;
            }
          } else if (syncStatus == neo_sync.GameSyncStatus.upToDate) {
            // If it is up to date, mark it processed so it is not checked again
            if (isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(localFile.filePath);
            }
          }
        }
      }

      // 2. Check the cloud files that do not exist locally
      for (final cloudFile in cloudFiles) {
        // Resolve the local paths to check whether they were already processed
        final localPaths = await resolveCloudFileToLocalPath(game, cloudFile);
        if (localPaths.isEmpty) continue;

        bool allProcessed = localPaths.isNotEmpty;
        if (isSharedSystem) {
          for (final path in localPaths) {
            if (!_processedMultiEmulatorFilesInSession.contains(path)) {
              allProcessed = false;
              break;
            }
          }
        } else {
          allProcessed = false; // Force a check when the system is not shared
        }

        if (allProcessed) {
          continue;
        }

        final existsLocally = localSaveFiles.any(
          (lf) => lf.relativePath == cloudFile.fileName,
        );

        if (!existsLocally) {
          try {
            final success = await _autoDownloadCloudSave(game, cloudFile);
            if (!success) allCloudDownloadsSucceeded = false;

            if (success && isSharedSystem) {
              for (final path in localPaths) {
                _processedMultiEmulatorFilesInSession.add(path);
              }
            }
          } on QuotaExceededException {
            quotaExceededDuringProcessing = true;
            allCloudDownloadsSucceeded = false;
          }
        }
      }

      // 3. Update the final state
      neo_sync.GameSyncStatus finalStatus;
      if (_quotaExceededActive || quotaExceededDuringProcessing) {
        finalStatus = neo_sync.GameSyncStatus.quotaExceeded;
      } else if (!allUploadsSucceeded || !allCloudDownloadsSucceeded) {
        NeoSyncProvider._log.w(
          'Sync had errors for ${game.name}, marking as upToDate',
        );
        finalStatus = neo_sync.GameSyncStatus.upToDate;
      } else {
        finalStatus = neo_sync.GameSyncStatus.upToDate;
      }

      _updateGameSyncState(game.romname, game.name, finalStatus);
    } catch (e) {
      NeoSyncProvider._log.w('Error detecting saves for ${game.name}: $e');
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.noSaveFound,
      );
    }
  }

  /// Gets the ROM name without its extension, for comparison against save files
  String _getRomNameWithoutExtension(String romname) {
    // Strip the file extension if there is one
    if (romname.contains('.')) {
      return romname.substring(0, romname.lastIndexOf('.'));
    }
    return romname;
  }

  Future<bool> _autoUploadLocalSave(
    GameModel game,
    LocalSaveFile localSave,
  ) async {
    try {
      final file = File(localSave.filePath);
      if (!file.existsSync()) return false;

      // 1. Get the system so its JSON paths can be resolved
      final system = await _getSystemForGame(game);
      if (system == null) return false;

      // Check whether the system has sync disabled
      if (!system.neosync.sync) {
        return false;
      }

      // 2. Determine the relative path in a universal way
      final savesPath = await _getRetroArchSavesPath();
      final statesPath = await _getRetroArchStatesPath();

      String basePath = file.parent.path;
      bool isState = false;

      if (statesPath != null && path.isWithin(statesPath, file.path)) {
        basePath = statesPath;
        isState = true;
      } else if (savesPath != null && path.isWithin(savesPath, file.path)) {
        basePath = savesPath;
        isState = false;
      }

      final relativePath = await _calculateSyncRelativePath(
        game,
        file,
        basePath,
        isState: isState,
        explicitSystemFolder: game.systemFolderName,
      );
      if (relativePath == null) {
        NeoSyncProvider._log.w(
          'Auto-upload skipped for ${game.name}: no resolvable sync path',
        );
        return false;
      }

      final parsed = CloudPathBuilder.parse(relativePath);
      // RetroArch saves use the v1-style relative path, which the cloud path
      // parser cannot see an emulator in, so derive the RetroArch slug from the
      // save's core folder (ground truth), falling back to the game metadata.
      final emulatorId =
          parsed?.emulatorSlug ??
          await _resolveRetroArchEmulatorSlug(file, basePath) ??
          _retroArchCoreSlugFromGame(game);
      final result = await _neoSyncService.syncFile(
        file,
        game.name,
        customFilename: relativePath,
        systemId: parsed?.system ?? game.systemFolderName,
        emulatorId: emulatorId,
        gameHash: await _resolveGameHashForUpload(game),
        isState: isState,
        scope: parsed?.scope,
      );

      if (result['success']) {
        return true;
      } else {
        final errorMessage = result['message']?.toString().toLowerCase() ?? '';
        if (errorMessage.contains('quota') &&
            errorMessage.contains('exceeded')) {
          _quotaExceededActive = true;
          throw QuotaExceededException('Storage quota exceeded', 1);
        }
        return false;
      }
    } on QuotaExceededException {
      rethrow;
    } catch (e) {
      NeoSyncProvider._log.w('Error auto-uploading save for ${game.name}: $e');
      return false;
    }
  }

  /// Automatically downloads a save from the cloud
  Future<bool> _autoDownloadCloudSave(
    GameModel game,
    NeoSyncFile cloudSave,
  ) async {
    try {
      // 1. Resolve the local path in a universal way
      final localPaths = await resolveCloudFileToLocalPath(game, cloudSave);
      if (localPaths.isEmpty) {
        NeoSyncProvider._log.w(
          'Auto-download: no path for ${cloudSave.fileName} '
          '(${game.name}); skipping',
        );
        return false;
      }

      // Check whether the system has sync disabled
      final system = await _getSystemForGame(game);
      if (system != null && !system.neosync.sync) {
        NeoSyncProvider._log.w(
          'Auto-download: sync disabled for ${system.realName}; '
          'skipping ${cloudSave.fileName}',
        );
        return false;
      }

      NeoSyncProvider._log.i(
        'Auto-download: ${cloudSave.fileName} -> ${localPaths.join(', ')}',
      );
      bool anySuccess = false;
      for (final localPath in localPaths) {
        final localFile = File(localPath);

        // 2. Create the directory if it does not exist
        await localFile.parent.create(recursive: true);

        // 3. Download the file
        await _downloadCloudFile(cloudSave, localFile);
        anySuccess = true;
      }

      return anySuccess;
    } on QuotaExceededException {
      rethrow;
    } catch (e) {
      NeoSyncProvider._log.w(
        'Error auto-downloading save for ${game.name}: $e',
      );
      return false;
    }
  }

  /// Finds ALL local save files for a specific game (saves and states)
  /// Whether [candidate] (a filename or full path, case-insensitive) refers to
  /// a save/state of the game with [romName].
  ///
  /// The ROM name must end at a word boundary (`.`, `_`, space, `[`, `(`, `/`),
  /// so a save like `mvsc2u.zip.eeprom` never matches the game `mvsc` the way a
  /// plain substring check would. A plain substring check is what uploaded the
  /// orphan Naomi EEPROM under the unrelated CPS2 "Clash of Super Heroes".
  bool _saveBelongsToRom(String candidate, String romName) {
    final g = romName.trim().toLowerCase();
    if (g.isEmpty) return false;
    final c = candidate.toLowerCase();
    if (c == g) return true;
    const boundaries = ['.', '_', ' ', '[', '(', '/'];
    for (final b in boundaries) {
      if (c.contains('$g$b')) return true;
    }
    // The ROM name as the final path segment (a game folder).
    return c.endsWith('/$g');
  }

  Future<List<LocalSaveFile>> _findGameSaveFiles(GameModel game) async {
    try {
      // 1. Get the system so its JSON paths can be resolved
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Check whether the system has sync disabled
      if (!system.neosync.sync) return [];

      // 2. Resolve the universal paths from the JSON
      final resolvedFolders = await resolveUniversalPaths(system, game: game);
      if (resolvedFolders.isEmpty) return [];

      // 3. Scan the files under those paths, in an Isolate so the UI is not blocked
      final List<File> allFiles = [];
      const int maxFileSize = 10 * 1024 * 1024; // 10MB

      // Execute heavy listing and filtering in background
      final List<String> filePaths = await Isolate.run(() {
        final List<String> paths = [];
        for (final folderPath in resolvedFolders) {
          final dir = Directory(folderPath);
          if (dir.existsSync()) {
            final files = dir.listSync(recursive: true).whereType<File>().where(
              (file) {
                try {
                  final size = file.lengthSync();
                  return size <= maxFileSize;
                } catch (e) {
                  return false;
                }
              },
            );
            paths.addAll(files.map((f) => f.path));
          }
        }
        return paths;
      });

      allFiles.addAll(filePaths.map((path) => File(path)));

      // 4. Filter the files according to the system
      final List<LocalSaveFile> matchingFiles = [];
      final gameRomName = _getRomNameWithoutExtension(
        game.romname,
      ).toLowerCase();

      // Identify whether this is a "shared memory cards" system
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      final statesPath = await _getRetroArchStatesPath();
      final savesPath = await _getRetroArchSavesPath();

      for (final file in allFiles) {
        try {
          final fileName = path.basename(file.path).toLowerCase();
          bool isMatch = false;

          if (isSharedSystem) {
            // For shared systems, any valid save/state file is a match
            // PS2: .ps2, DC: vmu_save
            if (system.folderName == 'ps2' && fileName.endsWith('.ps2')) {
              isMatch = true;
            } else if (system.folderName == 'dc' &&
                fileName.startsWith('vmu_save') &&
                fileName.endsWith('.bin')) {
              isMatch = true;
            }
          } else {
            // Standard systems match by ROM name with a word boundary, so
            // mvsc2u.zip.eeprom can never match the game "mvsc". The full path
            // is also checked in case the game name lives in the containing
            // folder instead of the file itself (e.g. Switch).
            final fullPathLower = file.path.toLowerCase();

            if (_saveBelongsToRom(fileName, gameRomName) ||
                _saveBelongsToRom(fullPathLower, gameRomName)) {
              isMatch = true;
            } else if (system.folderName == 'switch' &&
                game.titleId != null &&
                game.titleId!.isNotEmpty &&
                fullPathLower.contains(game.titleId!.toLowerCase())) {
              // Switch special case: match by Title ID in the path
              isMatch = true;
            }
          }

          if (isMatch) {
            final stat = await file.stat();

            String basePath = file.parent.path;
            bool isState = false;

            if (statesPath != null && path.isWithin(statesPath, file.path)) {
              basePath = statesPath;
              isState = true;
            } else if (savesPath != null &&
                path.isWithin(savesPath, file.path)) {
              basePath = savesPath;
              isState = false;
            }

            final relativePath = _calculateRelativePath(
              file,
              basePath,
              isState: isState,
            );

            matchingFiles.add(
              LocalSaveFile(
                filePath: file.path,
                fileName: path.basename(file.path),
                fileSize: stat.size,
                lastModified: stat.modified,
                gameName: isSharedSystem
                    ? '${system.realName} Shared'
                    : game.name,
                isSynced: false,
                relativePath: relativePath,
              ),
            );

            // Mark it processed when it is shared, to avoid re-checking it this session
            if (isSharedSystem) {
              _processedMultiEmulatorFilesInSession.add(file.path);
            }
          }
        } catch (e) {
          NeoSyncProvider._log.e('Error matching file: $e');
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e('Error in universal _findGameSaveFiles: $e');
      return [];
    }
  }

  /// Finds the local save file for a specific game (legacy method - returns first match)
  Future<LocalSaveFile?> _findGameSaveFile(GameModel game) async {
    final allFiles = await _findGameSaveFiles(game);
    return allFiles.isNotEmpty ? allFiles.first : null;
  }

  // ── Public reuse hooks for other sync providers (e.g. RomM) ───────────────

  /// Locates local save/state files for [game], reusing NeoSync's path
  /// resolution and filename matching. Each [LocalSaveFile.relativePath] is
  /// prefixed with `saves/` or `states/` so callers can tell them apart.
  Future<List<LocalSaveFile>> locateGameSaveFiles(GameModel game) =>
      _findGameSaveFiles(game);

  /// Resolves candidate local destination paths for a cloud file named
  /// [relativeName] (e.g. `saves/Game.srm` or `states/Game.state`) belonging to
  /// [game]. Returns an empty list if no destination can be resolved.
  Future<List<String>> resolveLocalTargetPaths(
    GameModel game,
    String relativeName,
  ) {
    final synthetic = NeoSyncFile(
      id: '',
      fileName: relativeName,
      filePath: relativeName,
      fileSize: 0,
      gameName: game.name,
      uploadedAt: DateTime.now(),
      userId: '',
    );
    return resolveCloudFileToLocalPath(game, synthetic);
  }

  /// Gets ALL cloud save files for a specific game
  Future<List<NeoSyncFile>> _getCloudSaveFilesForGame(GameModel game) async {
    try {
      // 1. Get the system so its characteristics can be resolved
      final system = await _getSystemForGame(game);
      if (system == null) return [];

      // Check whether the system has sync disabled
      if (!system.neosync.sync) return [];

      // 2. Load the cloud files if they are not loaded yet
      if (_files.isEmpty) {
        final result = await _neoSyncService.getAllFiles();
        if (result['success']) {
          _files = result['files'];
        } else {
          return [];
        }
      }

      final gameRomName = _getRomNameWithoutExtension(
        game.romname,
      ).toLowerCase();
      final List<NeoSyncFile> matchingFiles = [];

      // Identify whether this is a "shared memory cards" system
      final isSharedSystem =
          system.folderName == 'ps2' || system.folderName == 'dc';

      for (final cloudFile in _files) {
        final fileName = path.basename(cloudFile.fileName).toLowerCase();
        bool isMatch = false;

        if (isSharedSystem) {
          // For shared systems, filter strictly by system
          if (system.folderName == 'ps2' && fileName.endsWith('.ps2')) {
            isMatch = true;
          } else if (system.folderName == 'dc' &&
              fileName.startsWith('vmu_save') &&
              fileName.endsWith('.bin')) {
            isMatch = true;
          }
        } else {
          // Standard systems match by ROM name with a word boundary. The full
          // cloud path is checked too in case it lives in folders (e.g. Switch).
          final fullCloudPathLower = cloudFile.fileName.toLowerCase();

          if (_saveBelongsToRom(fileName, gameRomName) ||
              _saveBelongsToRom(fullCloudPathLower, gameRomName)) {
            isMatch = true;
          }
        }

        if (isMatch) {
          matchingFiles.add(cloudFile);
        }
      }

      return matchingFiles;
    } catch (e) {
      NeoSyncProvider._log.e(
        'Error getting cloud save files for ${game.name}: $e',
      );
      return [];
    }
  }

  /// Gets the cloud save file for a specific game (legacy method - returns first match)
  Future<NeoSyncFile?> _getCloudSaveForGame(
    GameModel game, {
    LocalSaveFile? localSave,
  }) async {
    final allFiles = await _getCloudSaveFilesForGame(game);
    return allFiles.isNotEmpty ? allFiles.first : null;
  }

  /// Computes a game's sync state from its local and cloud saves
  Future<neo_sync.GameSyncStatus> _calculateGameSyncStatus(
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
  ) async {
    if (localSave == null && cloudSave == null) {
      return neo_sync.GameSyncStatus.noSaveFound;
    }

    if (localSave == null && cloudSave != null) {
      return neo_sync.GameSyncStatus.cloudOnly;
    }

    if (localSave != null && cloudSave == null) {
      return neo_sync.GameSyncStatus.localOnly;
    }

    // Both have saves; check the sync state by comparing timestamps and hashes
    assert(localSave != null && cloudSave != null);

    try {
      // Read the local file to compute its hash
      final localFile = File(localSave!.filePath);
      if (!localFile.existsSync()) {
        return neo_sync.GameSyncStatus.localOnly; // The local file disappeared
      }

      final localBytes = await localFile.readAsBytes();
      final localHash = _neoSyncService.calculateFileHash(localBytes);

      // Compare the hashes when they are available
      final cloudHash = cloudSave!.checksum;
      final hashesMatch = cloudHash != null && localHash == cloudHash;

      // 1. If the hashes match → identical content
      if (hashesMatch) {
        return neo_sync.GameSyncStatus.upToDate;
      }

      // 2. If the hashes do NOT match (different content), evaluate the stored state.
      final syncState = await SyncRepository.getSyncState(
        NeoSyncProvider.kSyncProviderId,
        localSave.filePath,
      );

      final cloudTime = cloudSave.fileModifiedAtTimestamp ?? 0;
      final localTime = localSave.lastModified.millisecondsSinceEpoch;

      if (syncState != null) {
        final savedLocalTime = syncState['local_modified_at'] as int;
        final savedCloudTime = syncState['cloud_updated_at'] as int;

        // Tolerance of 2 seconds for local changes (FAT32/exFAT resolution)
        final localChanged = (localTime - savedLocalTime).abs() > 2000;
        final cloudChanged = cloudTime > savedCloudTime;

        if (localChanged && !cloudChanged) {
          return neo_sync.GameSyncStatus.localOnly; // Local ahead, upload
        } else if (!localChanged && cloudChanged) {
          return neo_sync.GameSyncStatus.cloudOnly; // Cloud ahead, download
        } else if (localChanged && cloudChanged) {
          // Both changed - always prefer local (upload)
          return neo_sync.GameSyncStatus.localOnly;
        } else {
          // Neither changed since the last sync, yet the hashes differ.
          // Fall back to comparing the raw timestamps when we cannot tell what happened.
          if (localTime > cloudTime) {
            return neo_sync.GameSyncStatus.localOnly;
          } else {
            return neo_sync.GameSyncStatus.cloudOnly;
          }
        }
      }

      // With NO stored state (first run, or it was cleared), fall back to the base logic
      const int toleranceMs = 2000;
      final timeDiff = (localTime - cloudTime).abs();

      if (timeDiff <= toleranceMs) {
        if (localTime > cloudTime) {
          return neo_sync.GameSyncStatus.localOnly;
        } else {
          return neo_sync.GameSyncStatus.cloudOnly;
        }
      }

      if (localTime > cloudTime) {
        return neo_sync.GameSyncStatus.localOnly;
      } else {
        return neo_sync.GameSyncStatus.cloudOnly;
      }
    } catch (e) {
      NeoSyncProvider._log.w('Error calculating sync status: $e');
      return neo_sync.GameSyncStatus.localOnly;
    }
  }

  /// Updates a game's sync state
  void _updateGameSyncState(
    String gameId,
    String gameName,
    neo_sync.GameSyncStatus status, {
    LocalSaveFile? localSave,
    NeoSyncFile? cloudSave,
  }) {
    final currentState = _gameSyncStates[gameId];
    final newState = neo_sync.GameSyncState(
      gameId: gameId,
      gameName: gameName,
      status: status,
      cloudEnabled: currentState?.cloudEnabled ?? true,
      localSave: localSave,
      cloudSave: cloudSave,
      lastSync: DateTime.now(),
    );

    _gameSyncStates[gameId] = newState;
    notify();
  }

  /// Updates a game's cloud sync configuration
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    try {
      // systemFolderName and filename resolution for this gameId is not yet implemented;
      // only local state is updated for now.
      final currentState = _gameSyncStates[gameId];
      if (currentState != null) {
        final newState = currentState.copyWith(cloudEnabled: enabled);
        _gameSyncStates[gameId] = newState;
      }

      if (enabled) {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.noSaveFound,
        );
      } else {
        _updateGameSyncState(
          gameId,
          currentState?.gameName ?? gameId,
          neo_sync.GameSyncStatus.disabled,
        );
      }
    } catch (e) {
      NeoSyncProvider._log.e('Error updating cloud sync for game $gameId: $e');
    }
  }

  // ==========================================
  // PUBLIC METHODS FOR INDIVIDUAL DOWNLOADS
  // ==========================================

  /// Gets the path of the RetroArch saves directory (public method)
  Future<String?> getRetroArchSavesPath() async {
    return _getRetroArchSavesPath();
  }

  /// Downloads a cloud file to a local file (public method)
  Future<void> downloadCloudFile(NeoSyncFile cloudFile, File localFile) async {
    return _downloadCloudFile(cloudFile, localFile);
  }

  /// Helper to calculate relative path for sync, with special handling for Dreamcast
  /// Syncs saves before a game starts (Steam-style)
  Future<void> syncGameSavesBeforeLaunch(
    GameModel game, {
    SyncDeadline? deadline,
  }) async {
    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    // Expose the deadline to the shared download path (_downloadCloudFile) so a
    // late download abandons its write once the launch has proceeded.
    _launchDeadline = deadline;
    try {
      // Detect the current saves
      await detectGameSaveFiles(game);

      final gameState = _gameSyncStates[game.romname];
      if (gameState == null) return;

      // Always proceed with sync (auto-resolve)

      // Only sync when it is necessary
      if (gameState.status == neo_sync.GameSyncStatus.localOnly &&
          gameState.localSave != null) {
        // Upload the local save that is not in the cloud
        final file = File(gameState.localSave!.filePath);
        if (file.existsSync()) {
          // Compute the correct relative path
          final savesPath = await _getRetroArchSavesPath();
          if (savesPath != null) {
            final relativePath = await _calculateSyncRelativePath(
              game,
              file,
              savesPath,
              explicitSystemFolder: game.systemFolderName,
            );
            if (relativePath == null) {
              NeoSyncProvider._log.w(
                'Pre-launch upload skipped for ${game.name}: no sync path',
              );
              return;
            }

            final parsed = CloudPathBuilder.parse(relativePath);
            final result = await _neoSyncService.syncFile(
              file,
              game.name,
              customFilename: relativePath,
              systemId: parsed?.system ?? game.systemFolderName,
              emulatorId: parsed?.emulatorSlug,
              gameHash: await _resolveGameHashForUpload(game),
              isState: false,
              scope: parsed?.scope,
            );

            if (result['success']) {
              // Update the state after the sync
              await detectGameSaveFiles(game);
            }
          }
        }
      } else if (gameState.status == neo_sync.GameSyncStatus.cloudOnly &&
          gameState.cloudSave != null) {
        // Download the save from the cloud
        await restoreCloudBackup(gameState.cloudSave!);
        // Update the state
        await detectGameSaveFiles(game);
      }
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Pre-launch sync failed: storage quota exceeded for ${game.name}',
      );
      // Move the game's state to quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in pre-launch sync for ${game.name}: $e');
    } finally {
      _launchDeadline = null;
    }
  }

  /// Syncs saves after a game closes (Steam-style)
  Future<void> syncGameSavesAfterClose(GameModel game) async {
    if (!isNeoSyncAuthenticated) return;
    if (game.cloudSyncEnabled != true) return;

    try {
      // Short pause to make sure the game has finished writing its saves
      await Future.delayed(const Duration(seconds: 1));

      // Detect the current saves (they may have changed while the game ran)
      await detectGameSaveFiles(game);

      final gameState = _gameSyncStates[game.romname];
      if (gameState == null || gameState.localSave == null) return;

      // Upload the local save (it may have been modified while the game ran)
      final file = File(gameState.localSave!.filePath);
      if (file.existsSync()) {
        // Compute the correct relative path
        final savesPath = await _getRetroArchSavesPath();
        if (savesPath != null) {
          final relativePath = await _calculateSyncRelativePath(
            game,
            file,
            savesPath,
            explicitSystemFolder: game.systemFolderName,
          );
          if (relativePath == null) {
            NeoSyncProvider._log.w(
              'Post-game upload skipped for ${game.name}: no sync path',
            );
            return;
          }

          final parsed = CloudPathBuilder.parse(relativePath);
          final result = await _neoSyncService.syncFile(
            file,
            game.name,
            customFilename: relativePath,
            systemId: parsed?.system ?? game.systemFolderName,
            emulatorId: parsed?.emulatorSlug,
            gameHash: await _resolveGameHashForUpload(game),
            isState: false,
            scope: parsed?.scope,
          );

          if (result['success']) {
            // Update the state after the sync
            await detectGameSaveFiles(game);
          }
        }
      }
    } on QuotaExceededException {
      NeoSyncProvider._log.e(
        'Post-game sync failed: storage quota exceeded for ${game.name}',
      );
      // Move the game's state to quota exceeded
      _updateGameSyncState(
        game.romname,
        game.name,
        neo_sync.GameSyncStatus.quotaExceeded,
      );
    } catch (e) {
      NeoSyncProvider._log.w('Error in post-game sync for ${game.name}: $e');
    }
  }

  /// Restores a backup from the cloud (downloads and overwrites the local copy)
  Future<void> restoreCloudBackup(NeoSyncFile cloudFile) async {
    try {
      final savesPath = await _getRetroArchSavesPath();
      if (savesPath == null) {
        throw Exception('RetroArch saves directory not found');
      }

      String targetPath;
      final fileName = cloudFile.fileName.replaceAll('\\', '/'); // Normalize

      // Dreamcast VMU specific handling
      if (fileName.toLowerCase().contains('vmu_save') &&
          fileName.toLowerCase().endsWith('.bin')) {
        final systemDir = await _getRetroArchSystemPath();
        targetPath = path.join(
          systemDir ?? savesPath,
          'dc',
          path.basename(fileName),
        );
      } else if (fileName.startsWith('saves/')) {
        // Relative to the root (one level up from savesPath)
        final rootPath = Directory(savesPath).parent.path;
        targetPath = path.join(rootPath, fileName);
      } else {
        // Relative to savesPath
        targetPath = path.join(savesPath, fileName);
      }

      final file = File(targetPath);
      NeoSyncProvider._log.i('Restore: ${cloudFile.fileName} -> ${file.path}');
      // Make sure the directory exists
      await file.parent.create(recursive: true);

      // Use the shared download method
      await _downloadCloudFile(cloudFile, file);
    } catch (e) {
      NeoSyncProvider._log.e('Restore: FAILED for ${cloudFile.fileName}: $e');
      rethrow;
    }
  }
}
