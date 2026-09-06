---
status: implemented
date: 2026-09-04
implements: [ADR-0001]
---

# SPEC-0001: RomM Existing ROM Linking

## Graph Edges

- **Implements:** [ADR-0001](../../adrs/ADR-0001-link-existing-roms-to-romm-by-filename.md) — link pre-existing local ROMs to RomM entries by filename instead of only at download time

## Overview

NeoStation resolves every RomM feature for a game (save and state sync, the pending-upload sweep, playtime, and the cloud status badge) through one row in `app_romm_rom_map`, keyed by ROM filename and system folder. Today that row is written only when a ROM finishes downloading through the app, so ROMs that were already on the device stay permanently unlinked and show a grey cloud.

This capability establishes the link for pre-existing ROMs by filename, per ADR-0001. It adds two entry points that share one matching rule: the "already downloaded" paths in the RomM browser and bulk sync write the link instead of stopping, and an idempotent link pass runs after each connect to match the whole local library against the server. The rule matches on RomM's `fs_name` (including the multi-disc `.m3u` equivalence the app already uses) within the local system that the RomM platform resolves to.

Renamed files, hash-based matching, and a manual per-game link picker are out of scope. See ADR-0001 for the rejected and complementary options.

## Requirements

### Requirement: Filename Equivalence Rule

The system SHALL treat a local library entry and a RomM ROM as the same game when all of the following hold:

- The RomM ROM's platform resolves to a local system via the existing slug and alias resolution.
- The local entry belongs to that system, under any of the system's folder aliases.
- The local entry's filename equals the RomM `fs_name`, compared case-insensitively, or equals one of the multi-disc playlist names the app already recognises for that ROM (the `fs_name` plus `.m3u`, and the extension-stripped stem plus `.m3u`).

The rule MUST be implemented once and shared by every consumer in this spec and by the existing "already downloaded" check, so the downloaded badge and the link decision cannot disagree. The rule MUST NOT read file contents.

#### Scenario: Exact filename match

- **WHEN** the local library contains `Chrono Trigger (USA).sfc` under the `snes` folder and the RomM server has a ROM with `fs_name` `Chrono Trigger (USA).sfc` on a platform that resolves to the `snes` system
- **THEN** the rule reports a match

#### Scenario: Case differs

- **WHEN** the local filename is `chrono trigger (usa).sfc` and the RomM `fs_name` is `Chrono Trigger (USA).sfc`
- **THEN** the rule reports a match and the mapping is written with the local entry's canonical filename

#### Scenario: Multi-disc playlist

- **WHEN** a multi-file RomM ROM has `fs_name` `Final Fantasy VII (USA)` and the local library indexes `Final Fantasy VII (USA).m3u`
- **THEN** the rule reports a match

#### Scenario: Folder alias

- **WHEN** the local ROM sits under `segacd/` and the resolved system's canonical folder is `scd` with `segacd` listed as an alias
- **THEN** the rule reports a match

#### Scenario: Unresolved platform

- **WHEN** a RomM platform's slug and `fs_slug` resolve to no local system
- **THEN** the rule reports no match for any ROM on that platform and the platform is counted as unresolved

### Requirement: Link on Already Downloaded

When a user confirms a ROM in the RomM browser, or bulk sync enumerates a ROM, and the ROM is found on disk by the existing "already downloaded" check, the system MUST write the `app_romm_rom_map` row for that local file instead of only notifying or skipping.

The browser path MUST tell the user the ROM was linked rather than repeating the "already downloaded" message when a new row was written. Bulk sync MUST count linked ROMs separately from ROMs that were already linked, and MUST NOT queue them for download.

The browser path SHOULD fill the game's metadata and media gaps from RomM on confirm (the fill-gaps import from SPEC-0005 replaced the original "no scraped metadata" gate). Bulk sync MUST NOT fetch media for linked ROMs.

#### Scenario: Browser confirm on an existing file

- **WHEN** the user confirms a ROM whose file exists locally and no mapping row exists
- **THEN** a mapping row is written for the local filename and system folder, the user sees a "linked" notification, and the game's sync status is refreshed

#### Scenario: Browser confirm on an already linked file

- **WHEN** the user confirms a ROM whose file exists locally and a mapping row already exists
- **THEN** no row is written and the user sees the existing "already downloaded" notification

#### Scenario: Bulk sync enumerates an existing file

- **WHEN** bulk sync enumerates a ROM that exists locally
- **THEN** the ROM is linked if unlinked, counted as linked or already-linked, and is not added to the download queue

### Requirement: Connect-Time Link Pass

After a disconnected-to-connected transition the system MUST run a link pass that, for every RomM platform resolving to a local system, pages the server's ROMs for that platform and applies the Filename Equivalence Rule against the local library index, writing a mapping row for each match that has none.

The pass MUST run on the existing connect-time schedule and MUST complete before the pending-upload sweep starts, so games linked by the pass are swept in the same connect.

The pass MUST match against the local library index (the scanned games table), not by probing the filesystem, so it costs no disk or SAF reads.

The pass MUST use the existing page size and page cap of bulk sync enumeration, and MUST NOT fetch media, metadata, saves, or states.

#### Scenario: Library copied from the server

- **WHEN** the device holds 400 ROMs copied from the RomM server with filenames intact, none linked, and the app connects to that server
- **THEN** after the pass, every ROM whose platform resolves to a local system has a mapping row, and the pending-upload sweep runs over them

#### Scenario: Nothing to link

- **WHEN** every local game already has a mapping row
- **THEN** the pass writes nothing and logs that zero rows were added

#### Scenario: Reconnect

- **WHEN** the app disconnects and reconnects
- **THEN** the pass runs again and produces the same mappings with no duplicates

### Requirement: Existing Mappings Are Never Overwritten

Neither entry point MUST overwrite an existing `app_romm_rom_map` row (SPEC-0004 later refined this: automatic writers never replace a row, and the download path replaces unless the row is manual). A row that already holds a `romm_rom_id` for a given filename and system folder MUST be left unchanged even when the pass matches that file to a different ROM.

#### Scenario: Manually chosen link survives the pass

- **WHEN** a mapping row exists for `Game.gba` in `gba` pointing at rom id 12, and the pass matches `Game.gba` to rom id 40
- **THEN** the row still points at rom id 12 and the conflict is logged

### Requirement: Ambiguous Matches Are Skipped

When more than one RomM ROM on platforms that resolve to the same local system matches one local file, the pass MUST NOT write a mapping for that file and MUST record the file and the candidate ROM ids in the pass summary log.

#### Scenario: Two platforms alias to one system

- **WHEN** RomM platforms `genesis` and `megadrive` both resolve to the local `genesis` system and each has a ROM named `Sonic.md`
- **THEN** the local `Sonic.md` is not linked and the ambiguity is logged with both ROM ids

### Requirement: Pass Scheduling and Guards

The pass MUST NOT start while a bulk ROM sync is running, MUST stop early when the provider is disposed or disconnects mid-run, and MUST NOT overlap with another instance of itself. A skipped run MUST NOT be rescheduled; the next connect picks it up.

#### Scenario: Bulk sync in progress

- **WHEN** the connect delay elapses while bulk sync is running
- **THEN** the pass is skipped and a log line says why

#### Scenario: Disconnect mid-run

- **WHEN** the server becomes unreachable after the pass has processed some platforms
- **THEN** the pass stops, keeps the rows already written, and logs partial completion

### Requirement: Sync Status Refresh After Linking

After a mapping row is written by either entry point, the system MUST invalidate any cached sync state for the affected game so that the cloud status badge and the "downloaded" cache reflect the link without restarting the app.

#### Scenario: Badge updates in place

- **WHEN** a game showing the grey cloud is linked by the browser path
- **THEN** the next status computation for that game returns a non-disabled state

### Requirement: Pass Observability

The pass MUST log one summary line per run containing the number of platforms processed, platforms unresolved, ROMs enumerated, rows added, rows already present, ambiguous files skipped, and elapsed time. Per-game "not linked" conditions MUST NOT be logged individually at info level.

#### Scenario: Summary present

- **WHEN** a pass completes or stops early
- **THEN** exactly one summary line with those counts is written to the log

### Requirement: Localized User-Facing Text

Every new user-visible string introduced by this capability (the "linked" notification and any bulk sync count label) MUST be defined as an `AppLocale` key with a value in all twelve language files. Log messages are exempt.

#### Scenario: New key present in every language

- **WHEN** the linked notification key is added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines it and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "link pass failed: platform enumeration failed: connection refused")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Error logs MUST carry their context as `key=value` pairs in the message (this repo's `LoggerService` takes strings; a structured API is not required)

#### Scenario: Server error during paging

- **WHEN** a platform page request fails with a server error
- **THEN** the pass logs the platform and error, skips that platform, continues with the next, and reports the failure count in the summary

### Requirement: Concurrency Safety

The pass runs as a background task inside the app's single-threaded event loop and MUST follow safe concurrency patterns:

- Cancellation MUST be checked between platforms and between pages so a dispose or disconnect stops the pass promptly
- The pass MUST have an explicit lifecycle: one running instance at a time, guarded the same way the upload sweep is guarded
- Shared mutable state touched by the pass (the downloaded-cache and sync-state caches) MUST be updated through their owning objects' existing invalidation methods, not mutated directly

#### Scenario: Dispose during a pass

- **WHEN** the sync provider is disposed while the pass is paging a platform
- **THEN** the pass exits before the next page request and writes no further rows

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Database access MUST go through the shared `SqliteService` connection via a repository; there is no connection pool in this app
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Batch insert per platform

- **WHEN** the pass has a set of new mappings for one platform
- **THEN** they are written through the repository layer with parameterized inserts that skip existing rows rather than replacing them
