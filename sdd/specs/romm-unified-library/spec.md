---
status: draft
date: 2026-09-06
implements: [ADR-0020]
requires: [SPEC-0001, SPEC-0008, SPEC-0010]
---

# SPEC-0019: RomM Unified Library

## Graph Edges

- **Implements:** [ADR-0020](../../adrs/ADR-0020-show-romm-library-inside-the-local-library.md) — show the RomM library inside the local library from a persisted, offline-first catalog
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — link map, platform resolution, filename matching, and the connect-time walk
- **Requires:** [SPEC-0008](../romm-browse-performance-and-search/spec.md) — cover decode width and image handling
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — heartbeat probe for reachability

## Overview

With "Show RomM library in my systems" on, every RomM ROM whose platform resolves to a local system appears in that system's game list, marked as remote when it is not on the device, downloadable in place, and rendered from a persisted catalog and an on-disk cover cache so the library works offline. Lists have a `downloaded` or `all` scope that defaults to `downloaded` while the server is unreachable; the catalog refreshes when the connection returns. See ADR-0020.

## Requirements

### Requirement: Catalog Tables

A versioned, guarded, idempotent migration SHALL add `app_romm_catalog(server_url TEXT NOT NULL, romm_rom_id INTEGER NOT NULL, platform_id INTEGER NOT NULL, system_folder TEXT NOT NULL, name TEXT NOT NULL, fs_name TEXT NOT NULL, fs_extension TEXT, fs_size_bytes INTEGER, has_multiple_files INTEGER NOT NULL DEFAULT 0, path_cover_small TEXT, path_cover_large TEXT, url_cover TEXT, ra_id INTEGER, genres TEXT, release_year TEXT, server_updated_at TEXT, seen_at TEXT NOT NULL, PRIMARY KEY(server_url, romm_rom_id))` with an index on `(server_url, system_folder)`, and `app_romm_catalog_platforms(server_url TEXT NOT NULL, platform_id INTEGER NOT NULL, system_folder TEXT NOT NULL, name TEXT NOT NULL, rom_count INTEGER NOT NULL DEFAULT 0, refreshed_at TEXT, PRIMARY KEY(server_url, platform_id))`. `RommCatalogRepository` SHALL provide batched upsert (chunk 500, one transaction per chunk), `deleteUnseen(serverUrl, platformId, before)`, `rowsForSystem(serverUrl, systemFolder)`, `systemsWithRows(serverUrl)`, `countForSystem`, `platformRefreshedAt`, and `clear(serverUrl)`.

#### Scenario: Migration

- **WHEN** the migration runs twice
- **THEN** both tables and the index exist once

#### Scenario: Upsert keeps identity

- **WHEN** a ROM is upserted with a new name
- **THEN** the same primary key row carries the new name and `seen_at`

### Requirement: Catalog Refresh Shares The Walk

`RommCatalogRefresh.run({reason})` SHALL page every RomM platform that resolves to a local system, in `RommPaging` page sizes with the page cap, upserting catalog rows per page and recording the platform in `app_romm_catalog_platforms`; after a platform completes it MUST delete rows for that platform not seen in this run; a platform whose paging fails MUST leave its rows untouched and be counted. The connect-time link pass (SPEC-0001) MUST consume the same pages through an injected per-ROM callback so the server is walked once. The refresh MUST be single-instance, MUST check the stop signal between pages, MUST run at most once per hour unless `reason` is `manual` or `reconnect`, MUST log one summary line (platforms, rows upserted, deleted, failed, elapsed), and MUST NOT block the UI.

#### Scenario: One walk

- **WHEN** a refresh runs on connect
- **THEN** each page is fetched once and both the catalog rows and the link claims come from it

#### Scenario: Deleted on server

- **WHEN** a ROM present in the catalog is absent from a completed platform walk
- **THEN** its row is deleted

#### Scenario: Hourly guard

- **WHEN** a second automatic refresh is requested 10 minutes after one completed
- **THEN** it is skipped with one info line

### Requirement: Reachability

`RommProvider.reachability` SHALL be `online`, `offline`, or `unknown`. It MUST become `online` when the heartbeat probe succeeds or any request completes, `offline` when a request fails with a socket error or timeout, and `unknown` at startup with a saved connection until the first probe. While `offline`, the provider MUST re-probe the heartbeat every 60 seconds, doubling up to 5 minutes, and on success MUST set `online`, trigger a refresh with reason `reconnect`, and trigger the pending flushes (play sessions and any outboxes). Reachability changes MUST notify listeners once per change and MUST be logged once per change.

#### Scenario: Goes offline

- **WHEN** a catalog page request times out
- **THEN** reachability becomes `offline` and a re-probe is scheduled in 60 s

#### Scenario: Comes back

- **WHEN** a re-probe succeeds after two failures
- **THEN** reachability becomes `online`, one refresh with reason `reconnect` starts, and queued play sessions flush

### Requirement: Remote Entries In The Game Model

`GameModel` SHALL gain `rommRomId`, `remoteSizeBytes`, and `isRemote` (`romPath == null && rommRomId != null`), and `rommRomId` MUST take part in equality and hash so two remote entries sharing a filename stay distinct (local games, where it is null, are unaffected). Remote entries are built by `GameModel.fromCatalogRow(row, system, {displayName, showRomFileNameSubtitle})`, which takes the already-resolved display name rather than a name-settings object: the name formatter lives in `GameListService`, and a model cannot import a service, so the merge resolves the system's name settings once and passes the result in, applying the same per-system settings the local path does. `GameListService.loadGamesForSystem` MUST, when the feature toggle is on, append one `GameModel` per catalog row of the system that is not hidden behind a local game, where a row is hidden when the link map (`RommRomIdIndex`) points any local game of the system at its rom id, or when `RommLocalMatcher.matches` a local filename of the system (including hidden local games). Remote entries MUST carry name, system, RA id, genres, release year, and size from the catalog, MUST sort with the local rule (favourites first, then name), and MUST NOT appear in favourites, recently played, most played, or collection lists. The "all games" aggregate MUST include them under the same rule. With the toggle off, or no server configured, the list MUST be exactly what it was before this spec.

#### Scenario: Ten on the server, two local

- **WHEN** GBA has two local games linked to two of ten catalog rows
- **THEN** the GBA list has ten entries, eight of them remote

#### Scenario: Linked by filename only

- **WHEN** a local file's name matches a catalog row that has no link map entry
- **THEN** the row is hidden and the local game shows alone

#### Scenario: Deleted locally

- **WHEN** a local game that hid a catalog row is deleted and the list reloads
- **THEN** the catalog row appears as a remote entry

### Requirement: Remote-Only Systems

`buildSystemsList` SHALL, when the toggle is on, include systems that have catalog rows but no `user_detected_systems` row, ordered with the detected systems by the configured system sort (one comparator, `compareSystemsForCarousel`, shared by the provider and the builder), marked with a cloud glyph and a localized semantics label, with the catalog's row count as the card count. The `SystemModel` of a remote-only system is resolved from the full systems list (`SqliteConfigProvider.availableSystems`, every `app_systems` row) after the detected systems, through one `systemForFolder` resolver that the carousel and the grid both use when the user opens a system. Because the carousel has no per-view scope toggle, remote-only systems MUST follow the *opening* scope — the configured default, forced to `downloaded` while reachability is `offline` (`LibraryScope.initial`) — and a scope toggled inside a game list does not reach back to the carousel. Opening one MUST show its remote entries; downloading MUST create the system folder through the existing destination resolution.

#### Scenario: Server-only platform

- **WHEN** RomM has PC Engine ROMs and the device has no PC Engine folder
- **THEN** PC Engine appears in the carousel with the cloud glyph and lists remote entries

#### Scenario: Offline carousel

- **WHEN** the app opens with reachability `offline` and the default scope `all`
- **THEN** the carousel shows no remote-only systems, and switching a game list to `all` does not add them to the carousel

### Requirement: Library Scope

The game views SHALL hold a scope, `all` or `downloaded`, initialized from the setting `romm_library_default_scope` except that while reachability is `offline` it MUST initialize to `downloaded`. `downloaded` MUST hide remote entries; remote-only systems are hidden by the carousel's opening scope under the same rule (REQ "Remote-Only Systems"), since the scope is per game view and the carousel has no toggle. The scope is a predicate over the merged in-memory list, so a toggle rebuilds without a database read. The toggle MUST be reachable from the game view three ways: the **Select + X** chord (free on this screen: X alone is the view-mode picker, Select + A is scrape, Select + Y is random), a tappable footer pill that shows the chord and the active scope name, and a "Switch library scope" item in the context menu. Switching to `all` while offline MUST show cached remote entries with downloads disabled, and the "offline, showing cached RomM library" text MUST be shown as a one-time localized notice on the switch and as a cloud-off mark on the footer pill whose tooltip carries the same line — not as a persistent line in the footer.

#### Scenario: Offline default

- **WHEN** the app starts with reachability `offline` and default scope `all`
- **THEN** the lists open in `downloaded`

#### Scenario: Toggle

- **WHEN** the user toggles scope in a system list
- **THEN** the list rebuilds without reloading from disk more than once and the footer reflects the scope

#### Scenario: Offline switch to all

- **WHEN** reachability is `offline` and the user presses Select + X in a list open in `downloaded`
- **THEN** the cached remote entries appear, the "offline, showing cached RomM library" notice shows once, and the footer pill wears the cloud-off mark with that line as its tooltip

### Requirement: Remote Entry Presentation

In the list, grid, and carousel a remote entry SHALL show a cloud-download badge in the favourite/collection badge family, its size in the subtitle (`{size}` formatted with the existing byte formatter), and the footer's primary action label "Download" instead of "Play". While a download tracker exists for its rom id the card MUST show progress (percent from the tracker, indeterminate when total unknown) and the footer MUST offer "Cancel"; a failed tracker MUST show a retry badge and "Retry" in the footer. When the settle rescan indexes the file the entry MUST become the local game without a manual reload.

#### Scenario: Downloading

- **WHEN** a remote entry's download is at 40 percent
- **THEN** the card shows 40 percent and the footer offers Cancel

#### Scenario: Indexed

- **WHEN** the settle rescan finishes for the system
- **THEN** the entry renders as a local game with Play

### Requirement: Download From The Library

Confirming a remote entry SHALL, when reachability is not `offline`, open a confirmation with name, size, and destination folder, then start `RommProvider.downloadRom` for it; a multi-disc ROM follows the existing unpack rule. When `offline` it MUST show a localized "not available offline" notice and start nothing. The context menu SHALL offer "Download" on remote entries and "Cancel download" while one runs. After completion a toast SHALL offer "Play now" once.

#### Scenario: Confirm and download

- **WHEN** the user confirms a remote entry online
- **THEN** the confirmation shows size and destination, and on accept the download starts

#### Scenario: Offline confirm

- **WHEN** the user confirms a remote entry offline
- **THEN** the notice shows and no request is sent

### Requirement: Cover Cache

`RommCoverCache` SHALL store small covers under `<mediaCache>/romm_covers/<serverHash>/<romId>.<ext>`, filling a missing entry on first render (through the existing cover URL candidates and auth headers) and prefetching covers for rows upserted by a refresh, bounded to 300 per refresh with concurrency 3, after the refresh completes. The cache MUST evict least-recently-used files above `romm_cover_cache_mb` (default 200) and MUST expose `pathFor(serverUrl, romId)` for build-time use. Cards MUST prefer a local game's scraped media over the cache and MUST decode with the SPEC-0008 width rule. The cache serves remote entries only: a local game without scraped media MUST show the placeholder, not the RomM cover of its linked ROM (the precedence helper `rommCoverPathFor` implements this literally, per #206; the fallback was considered and not taken). The cache MUST be cleared for a server on disconnect and on a change of server URL — the cover-cache half of REQ "Settings And Actions", delivered by #206; the catalog half of that clear belongs to the lists, scope, and settings story (#107).

#### Scenario: Offline render

- **WHEN** a remote entry's cover was cached and the device is offline
- **THEN** the card shows the cover without a request

#### Scenario: Eviction

- **WHEN** the cache exceeds the cap after a prefetch
- **THEN** the least recently used files are removed until under the cap

### Requirement: Secondary Display And Search

Selecting a remote entry SHALL push its cached cover and a localized "not downloaded" state to the secondary display and MUST NOT attempt local media or video paths. The search screen SHOULD use the catalog for its remote rows when reachability is `offline`.

#### Scenario: Secondary display

- **WHEN** a remote entry is selected on a dual-screen device
- **THEN** the second screen shows the cached cover and the state line

### Requirement: Settings And Actions

General settings SHALL offer "Show RomM library in my systems" (`romm_show_library`, default off), "Default library scope" (`romm_library_default_scope`), and "RomM cover cache size" (`romm_cover_cache_mb`); the RomM connected settings SHALL offer "Refresh RomM library now" (a manual refresh that bypasses the hourly guard, reporting start and outcome through the notification tray), "Clear cached RomM library" (catalog rows and the cover cache), and an "as of {time}" line from the newest `refreshed_at`. Turning the toggle off MUST hide remote entries immediately without deleting the catalog; disconnecting or changing server MUST clear the catalog and cover cache for that server (the cover-cache clear shipped with #206 under REQ "Cover Cache"; the catalog clear is this requirement's, in #107).

Until the download flow lands (REQ "Remote Entry Presentation", REQ "Download From The Library", and REQ "Secondary Display And Search" are #108's), a remote entry MUST be inert on every per-game action: a launch, favourite, per-game settings, or scrape press — from the footer, the context menu, or a chord such as Select + A — MUST answer with a localized "Not downloaded" notice and MUST NOT write rows keyed to a file that is not on the device; the context menu MUST drop favourite, collections, settings, and scrape for a remote entry while keeping the view-level items (view mode, sort, library scope).

#### Scenario: Toggle off

- **WHEN** the toggle is turned off
- **THEN** lists rebuild without remote entries and the catalog rows remain

#### Scenario: Press on a remote entry before #108

- **WHEN** the user presses A, the favourite button, or Select + A on a remote entry
- **THEN** the "Not downloaded" notice shows and no launch, favourite row, or scrape happens

### Requirement: Localized User-Facing Text

Every new string (badges, footer labels, scope names, notices, settings, confirmations, semantics labels) MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (platform, page, rom id, status), MUST NOT be swallowed (a failed platform is counted and logged once per refresh; a failed cover fill is logged at debug and retried on next render), and MUST use key=value logging; reachability transitions MUST be logged once per change.

#### Scenario: Platform failure

- **WHEN** one platform's page 3 fails
- **THEN** the refresh continues with the next platform, the summary counts one failure, and the platform's rows are unchanged

### Requirement: Concurrency Safety

The refresh and the cover prefetch MUST run detached from the UI with the stop signal checked between pages and files; the merge in `GameListService` MUST be synchronous over in-memory data once the catalog rows are read; list rebuilds on scope change MUST NOT re-read the database.

#### Scenario: Disconnect mid-refresh

- **WHEN** the connection drops during a refresh
- **THEN** the refresh stops after the current page and rows written so far stay

### Requirement: Database Operation Standards

All catalog writes MUST be parameterized and batched in transactions; reads for a system MUST use the `(server_url, system_folder)` index; config columns MUST come from the same versioned migration per `lib/data/datasources/CLAUDE.md`.

#### Scenario: Large upsert

- **WHEN** 12,000 rows are upserted
- **THEN** they are written in chunks of 500, each in one transaction
