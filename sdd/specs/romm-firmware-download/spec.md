---
status: draft
date: 2026-09-06
implements: [ADR-0012]
requires: [SPEC-0001]
---

# SPEC-0012: RomM Firmware Download

## Graph Edges

- **Implements:** [ADR-0012](../../adrs/ADR-0012-download-bios-firmware-from-romm.md) — download BIOS and firmware files from RomM into the emulator's system directory
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — platform-to-system resolution

## Overview

A per-system panel lists the firmware RomM holds for the system's platform, shows which files are already in the local BIOS destination, and downloads the selected ones into it. The destination is RetroArch's system directory when known, otherwise a BIOS folder the user picks once. See ADR-0012.

## Requirements

### Requirement: Firmware Model And Service

The system SHALL provide `RommFirmware` (id, platformId, fileName, fileSizeBytes, crc32, md5, sha1, isVerified, missingFromFs; hashes lowercase, empty → null) and `RommService.listFirmware(platformId)` (GET `/api/firmware?platform_id=`, through the shared auth-retry policy) and `downloadFirmware(firmware, {destFilePath, onProgress, shouldCancel})` (GET `/api/firmware/{id}/content/{file_name}`, streamed into `<dest>.part`, renamed on completion, `.part` removed on failure or cancel). A 403 MUST surface as `RommException` with kind `scopeDenied`.

#### Scenario: Listing

- **WHEN** the platform has three firmware files, one `missing_from_fs`
- **THEN** three models are returned and the missing one carries the flag

#### Scenario: Cancelled download

- **WHEN** `shouldCancel` returns true mid-stream
- **THEN** the `.part` file is removed and no destination file exists

### Requirement: BIOS Destination

The system SHALL resolve a BIOS destination per system: an explicitly chosen `user_config.bios_directory` when one is set and writable; otherwise the RetroArch `system_directory` when the RetroArch config is known and the directory is writable; otherwise none. `bios_directory` is added by a versioned, `PRAGMA table_info`-guarded, idempotent migration. The panel MUST always offer to pick a folder (native picker on desktop, SAF tree on Android) and MUST persist the choice. SAF trees MUST be translated to a real path with the existing `safUriToRealPath` before writing.

#### Scenario: RetroArch known, nothing chosen

- **WHEN** `retroarch.cfg` has a `system_directory` that exists and no `bios_directory` is set
- **THEN** the destination is that directory, and the panel says so while still offering the picker

#### Scenario: An explicit choice outranks RetroArch

- **WHEN** the user picks a BIOS folder while `retroarch.cfg` also supplies a writable `system_directory`
- **THEN** the chosen folder is the destination, and it survives reopening the panel

#### Scenario: Nothing known

- **WHEN** neither is set
- **THEN** the panel shows a "choose BIOS folder" action and downloads are disabled until one is chosen

### Requirement: Local Presence And Verification

For each listed file the panel SHALL report `present` when a file with the same name and size exists in the destination, `missing` otherwise, and `serverMissing` when `missingFromFs` is set. When a present file has a server md5, the panel SHALL offer "Verify", which MUST stream the local md5 off the UI isolate and report match or mismatch. Presence checks MUST NOT read file contents.

#### Scenario: Present and verified

- **WHEN** `scph5501.bin` exists with the server's size and its md5 matches
- **THEN** the row reads present, and Verify reports a match

### Requirement: Firmware Panel

The system settings dialog SHALL show a "BIOS files from RomM" row for systems whose RomM platform resolves while RomM is connected, opening a panel with one row per firmware file (name, size, verified flag, local state) and actions "Download" per missing file, "Download all missing", and "Verify" per present file. Downloads MUST run through the global notification with per-file progress, MUST be cancellable, and MUST refresh the row state on completion. Every control MUST be reachable by controller; B closes the panel.

#### Scenario: Download all missing

- **WHEN** two of four files are missing and the user chooses "Download all missing"
- **THEN** both download in sequence with progress, and both rows read present afterwards

#### Scenario: Scope denied

- **WHEN** the server answers 403 on the list
- **THEN** the panel shows the localized "account lacks firmware access" message and no rows

### Requirement: Localized User-Facing Text

Every new string (row title, panel title, states, actions, messages) MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling: errors wrapped with context at each layer (file name, status), no silent swallowing (a failed download is reported in the notification and logged once), structured key=value logging.

#### Scenario: Network failure mid-download

- **WHEN** the socket drops during a download
- **THEN** the `.part` is removed, the notification shows the failure, and one warning line names the file and cause

### Requirement: Database Operation Standards

The `bios_directory` column MUST be added by a versioned migration following `lib/data/datasources/CLAUDE.md`, read and written through `ConfigRepository`, with parameterized statements.

#### Scenario: Migration idempotent

- **WHEN** the migration runs twice
- **THEN** the column exists once and existing rows are null
