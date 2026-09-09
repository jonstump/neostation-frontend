---
status: draft
date: 2026-09-06
implements: [ADR-0014]
requires: [SPEC-0001, SPEC-0010, SPEC-0013]
---

# SPEC-0014: RomM ROM Upload

## Graph Edges

- **Implements:** [ADR-0014](../../adrs/ADR-0014-upload-local-roms-to-romm-in-chunks.md) — upload local ROMs to RomM through its chunked upload session
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — link pass and platform resolution
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gate
- **Requires:** [SPEC-0013](../romm-play-state-writeback/spec.md) — optional scope groups (`romsWrite`, `tasksRun`)

## Overview

NeoStation uploads a local ROM to RomM's platform folder through the chunked upload session, reading the file by byte range (SAF on Android), requests a library scan when allowed, and lets the link pass connect the file once indexed. See ADR-0014.

## Requirements

### Requirement: Upload Source

The system SHALL provide `RomUploadSource.open(romPath)` returning total size and `read(offset, length)`, backed by random-access `dart:io` on desktop and `SafDirectoryService.readRange` for `content://` paths, executed in a background isolate initialized with the root isolate token. It MUST NOT read the whole file into memory. A path it will not upload MUST be refused as a typed `RomUploadRefusedException` whose reason is one of `{multiFile, discContainer, missing, empty, unsendableName}`: a directory, a SAF tree URI, or an `.m3u` playlist is `multiFile`; anything on `RetroAchievementsHashService.isDiscContainer`'s list (`.cue`, `.chd`, `.gdi`, …) is `discContainer`; a path that does not resolve to a file is `missing`; a zero-byte file, or a SAF document whose size cannot be read, is `empty`. A folder's own document URI built under a tree (`…/tree/<id>/document/<folder>`) contains `/document/`, passes the tree-URI probe, and is refused as `empty` because `getFileSize` answers 0 for a directory; callers MUST accept that outcome for a folder and MUST NOT treat the probe as a directory stat.

The upload name MUST consist only of printable ASCII (0x20–0x7E). `dart:io`'s `HttpHeaders` rejects any other code unit in a header value (the production client is `IOClient`, which sets every header through it), and RomM 4.8.0 does not decode `x-upload-filename` (its web client sends raw Latin-1 bytes a browser allows and `dart:io` cannot), so a percent-encoded name would be stored mangled, unrecognisable in RomM and never matched by SPEC-0001's name-based link pass. `RomUploadSource.validateUploadName` MUST refuse any other name as `unsendableName` before a request is sent, and the surfaces MUST list such a game as skipped with that reason rather than failed.

#### Scenario: SAF file

- **WHEN** the path is a `content://` document of 25 MiB
- **THEN** three reads of 10, 10, and 5 MiB return the file's bytes in order

#### Scenario: Accented file name

- **WHEN** the game's upload name is `Pokémon.gba`
- **THEN** no request is sent, the refusal reason is `unsendableName`, and the summary lists the game as skipped with that reason

#### Scenario: Folder document URI

- **WHEN** the path is a folder's document URI built under a SAF tree
- **THEN** it is refused as `empty` and nothing is read

### Requirement: Chunked Upload Session

`Future<bool> RommService.uploadRom(source, {platformId, fileName, onProgress, shouldCancel})` SHALL validate the upload name first (REQ "Upload Source"), then `POST /api/roms/upload/start` with headers `x-upload-platform`, `x-upload-filename`, `x-upload-total-size`, `x-upload-total-chunks` where chunks = `ceil(size / 10 MiB)`; then `PUT /api/roms/upload/{id}` per chunk in order with `x-chunk-index` and the raw bytes, every chunk but the last exactly 10 MiB, retrying a chunk that fails on transport or a 5xx up to three times with backoff `1 s × 2^attempt` (a 4xx is not retried); then `POST .../complete` with a timeout of at least 600 s. On retry exhaustion, a source read that comes up short, or `shouldCancel` answering true (checked before every chunk, during a backoff, and before `complete`) it MUST `POST .../cancel` (best effort: logged, never thrown) and fail with a distinct error kind, `uploadFailed` or `uploadCancelled`. A disconnect or a `configure()` of the service while a session is open MUST cancel the session the same way: the service keeps a connection generation counter that bumps on both, and a session whose generation is stale sends `cancel` and fails with `uploadCancelled`.

A 400 or 409 on `start` or `complete` whose detail contains the phrase "already exists" (RomM 4.8.0 answers `File {filename} already exists`) MUST map to `RommErrorKind.alreadyExists`; the upload route MUST require that phrase and MUST NOT use the collection route's whole-word file-name fallback, so `complete`'s other 400s (path validation, "Assembled file size mismatch") stay `uploadFailed`. A 403 MUST record a `romsWrite` scope denial and surface as `scopeDenied`.

It MUST return `false` without sending a request when `supports(romUpload)` is `unsupported` or `hasScope(romsWrite)` is `denied` (logged once per connection), and `true` after a successful `complete`, so a caller can tell "gated, nothing sent" from "uploaded", as `updateRomProps` does. `RommFeature.romUpload` is 4.8.0, verified against the release trees per SPEC-0010: `backend/endpoints/roms/upload.py` is absent at the 4.7.0 tag (whose `rom.py` carries only the older single-shot `POST /api/roms`) and declares all four session routes under `Scope.ROMS_WRITE` at 4.8.0. A second `uploadRom` while a session is open MUST throw `RommErrorKind.uploadBusy` rather than wait; `uploadInProgress` exposes the state.

#### Scenario: Retry then success

- **WHEN** chunk 2 fails once with a socket error
- **THEN** it is re-sent after 1 s and the session completes

#### Scenario: Collision

- **WHEN** `start` answers 400 "File X already exists"
- **THEN** the call fails with `alreadyExists` and no chunk is sent

#### Scenario: Other 400 on complete

- **WHEN** `complete` answers 400 "Assembled file size mismatch: expected X, got Y"
- **THEN** `cancel` is sent and the call fails with `uploadFailed`, not `alreadyExists`

#### Scenario: Disconnect mid-session

- **WHEN** the provider disconnects while chunk 3 of 5 is in flight
- **THEN** no further chunk is sent, `cancel` is sent, and the call fails with `uploadCancelled`

#### Scenario: Second upload while one is open

- **WHEN** `uploadRom` is called while a session is open
- **THEN** it throws `uploadBusy` at once and the open session is unaffected

#### Scenario: Gated server

- **WHEN** the server is 4.7.0
- **THEN** `uploadRom` returns `false` and no request is sent

### Requirement: Platform Mapping

`RommProvider.platformForSystem(system)` SHALL return the single RomM platform whose resolved local system is `system` (SPEC-0001's rule), null when none, and MUST log an ambiguity and return null when more than one platform resolves to it.

#### Scenario: No platform

- **WHEN** the server has no platform resolving to the system
- **THEN** the upload action reports the localized "no matching platform on the server" and starts nothing

### Requirement: Scan And Link After Upload

At the end of a batch in which at least one file completed, the provider SHALL request `POST /api/tasks/run/scan_library` exactly once, reading `hasScope(tasksRun)` at that moment (the end of the batch, not its start, so a group learned mid-batch counts); when nothing landed it MUST NOT request a scan. It SHALL report "scan requested" when the task was queued. Every other outcome of the scan request — the group not granted, the request gated, `taskBusy` (RomM already scanning), or any other failure — MUST be reported as "pending scan on the server", never as failed: the files are on the server either way.

The summary MUST offer "Link now", which runs the connect-time link pass (SPEC-0001) on demand. "Link now" and the summary live on the global notification, as its action (REQ "Upload Surfaces"), not in a dialog: a dialog needs a live context minutes after the surface that started the batch has closed. The link pass reaches the browse provider through a hook (`onLinkRequested`) installed by the sync layer, so the browse provider does not import it.

#### Scenario: Scan allowed

- **WHEN** the group is granted and two files were uploaded
- **THEN** exactly one scan request is sent after the second completes

#### Scenario: Nothing landed

- **WHEN** every file in the batch was skipped as already on the server
- **THEN** no scan request is sent and the summary shows no scan line

#### Scenario: Scan refused

- **WHEN** the scan request answers `taskBusy` or fails for any other reason
- **THEN** the summary reads "pending scan on the server" and the batch is not reported as failed

### Requirement: Upload Surfaces

`RommProvider.uploadToRomm(game)` and `uploadMissingForSystem(system)` SHALL return a `RommUploadSummary`; neither takes a ROM-folder argument, because the game rows carry `rom_path` and the batch never resolves a folder. The gate `canUploadRoms` is connected, not offline, `supports(romUpload)` not `unsupported`, and `hasScope(romsWrite)` not `denied`; `unknown` counts as offered, as for collection push.

The game context menu SHALL show "Upload to RomM" for a local, unlinked (the ROM map is read before the menu is built), single-file game while the gate allows; the system settings dialog SHALL show "Upload games missing from RomM", which enumerates the system's games excluding hidden and linked ones, keeps playlists and disc images in so the summary lists them as skipped with the reason, confirms the count and total size of what will be sent, and uploads them in sequence. Whether the settings row is offered is decided from the gate's value when the dialog opens (the row count must be settled before the keys are allocated); a gate that opens or closes while the dialog is up only enables or disables the row.

Both surfaces MUST report per-file progress through the global notification, whose row MAY carry a `GlobalNotificationAction {label, onPressed}` rendered as a pill: a tap or A on the highlighted row fires it and leaves the row listed, X still dismisses, and `update()` clears it unless re-passed. Cancel rides that action while the batch runs, and "Link now" replaces it on the summary when anything landed. The summary MUST list uploaded, skipped with reasons (`alreadyExists` and every `RomUploadRefusal` are skips, not failures), and failed. Every control MUST be reachable by controller.

#### Scenario: Bulk with a skip

- **WHEN** a system has three unlinked games, one multi-file
- **THEN** two upload with progress and the summary lists one skipped with its reason

#### Scenario: Hidden game

- **WHEN** a system has an unlinked game marked hidden
- **THEN** the bulk action neither counts nor uploads it

#### Scenario: Link now from the summary

- **WHEN** the user presses A on the summary notification's "Link now" pill
- **THEN** the link pass runs and the row appends how many games were linked

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (file, chunk index, status), MUST NOT be swallowed (each failed file logged once and listed in the summary), and MUST use key=value logging.

#### Scenario: Retry exhaustion

- **WHEN** a chunk fails four times
- **THEN** cancel is sent, the file is listed as failed with the cause, and one warning line names file and chunk

### Requirement: Concurrency Safety

Chunk reads MUST run in a background isolate with the root token; `shouldCancel` MUST be checked before every chunk. One upload session MUST run at a time in the service and one batch at a time in the provider (single-instance guards); neither queues: a second `uploadRom` throws `RommErrorKind.uploadBusy` and a second batch throws `RommUploadBusyException` before touching anything. A batch MUST stop on disconnect (`!isConnected || reachability == offline`, checked before every file), and `disconnect()` cancels the running batch.

#### Scenario: Disconnect mid-batch

- **WHEN** the connection drops while a file is in flight
- **THEN** the current session is cancelled, that file is listed as cancelled, and the batch ends as disconnected with the remaining files unreported as failed

#### Scenario: Second batch

- **WHEN** a batch is running and another surface starts one
- **THEN** the second throws `RommUploadBusyException` and the running batch is unaffected
