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

The system SHALL provide `RomUploadSource.open(romPath)` returning total size and `read(offset, length)`, backed by random-access `dart:io` on desktop and `SafDirectoryService.readRange` for `content://` paths, executed in a background isolate initialized with the root isolate token. It MUST NOT read the whole file into memory. Multi-file games and disc containers MUST be refused with a reason.

#### Scenario: SAF file

- **WHEN** the path is a `content://` document of 25 MiB
- **THEN** three reads of 10, 10, and 5 MiB return the file's bytes in order

### Requirement: Chunked Upload Session

`RommService.uploadRom(source, {platformId, fileName, onProgress, shouldCancel})` SHALL `POST /api/roms/upload/start` with headers `x-upload-platform`, `x-upload-filename`, `x-upload-total-size`, `x-upload-total-chunks` where chunks = `ceil(size / 10 MiB)`; then `PUT /api/roms/upload/{id}` per chunk in order with `x-chunk-index` and the raw bytes, retrying a failed chunk up to three times with backoff `1 s × 2^attempt`; then `POST .../complete` with a timeout of at least 600 s. On retry exhaustion or `shouldCancel` it MUST `POST .../cancel` and fail with a distinct error. A 400 or 409 on `start` naming an existing file MUST map to `RommErrorKind.alreadyExists`. It MUST return early without a request when `supports(romUpload)` (4.8.0) is `unsupported` or `hasScope(romsWrite)` is `denied`.

#### Scenario: Retry then success

- **WHEN** chunk 2 fails once with a socket error
- **THEN** it is re-sent after 1 s and the session completes

#### Scenario: Collision

- **WHEN** `start` answers 400 "File X already exists"
- **THEN** the call fails with `alreadyExists` and no chunk is sent

### Requirement: Platform Mapping

`RommProvider.platformForSystem(system)` SHALL return the single RomM platform whose resolved local system is `system` (SPEC-0001's rule), null when none, and MUST log an ambiguity and return null when more than one platform resolves to it.

#### Scenario: No platform

- **WHEN** the server has no platform resolving to the system
- **THEN** the upload action reports the localized "no matching platform on the server" and starts nothing

### Requirement: Scan And Link After Upload

After a successful `complete`, when `hasScope(tasksRun)` is `granted`, the provider SHALL request `POST /api/tasks/run/scan_library` once per upload batch and report "scan requested"; otherwise it SHALL report "pending scan on the server". A rejected scan (RomM already scanning) MUST be reported as pending, not failed. The outcome MUST offer "Link now", which runs the connect-time link pass on demand.

#### Scenario: Scan allowed

- **WHEN** the group is granted and two files were uploaded
- **THEN** exactly one scan request is sent after the second completes

### Requirement: Upload Surfaces

The game context menu SHALL show "Upload to RomM" for an unlinked, single-file game while connected and the gate allows; the system settings dialog SHALL show "Upload games missing from RomM", which enumerates the system's unlinked single-file games, confirms the count and total size, and uploads them in sequence. Both MUST report per-file progress and cancel through the global notification and end with a summary (uploaded, skipped with reasons, failed). Every control MUST be reachable by controller.

#### Scenario: Bulk with a skip

- **WHEN** a system has three unlinked games, one multi-file
- **THEN** two upload with progress and the summary lists one skipped with its reason

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

Chunk reads MUST run in a background isolate with the root token; `shouldCancel` MUST be checked before every chunk; one upload batch MUST run at a time (single-instance guard) and MUST stop on disconnect.

#### Scenario: Disconnect mid-batch

- **WHEN** the connection drops between files
- **THEN** the current session is cancelled and the batch ends with the remaining files unreported as failed
