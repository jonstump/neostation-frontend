---
status: draft
date: 2026-09-06
implements: [ADR-0019]
requires: [SPEC-0004, SPEC-0005, SPEC-0008, SPEC-0010, SPEC-0013]
---

# SPEC-0018: RomM Library Extras

## Graph Edges

- **Implements:** [ADR-0019](../../adrs/ADR-0019-expose-romm-library-filters-search-and-maintenance.md) — expose RomM's library filters, random pick, metadata fix-up, and maintenance tasks
- **Requires:** [SPEC-0004](../romm-manual-link-picker/spec.md) — the picker hosting "Fix match"
- **Requires:** [SPEC-0005](../romm-metadata-fetch/spec.md) — replace-mode fetch after a fix
- **Requires:** [SPEC-0008](../romm-browse-performance-and-search/spec.md) — the browse screen
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gates and metadata-source flags
- **Requires:** [SPEC-0013](../romm-play-state-writeback/spec.md) — `romsWrite` and `tasksRun` groups

## Overview

The browse screen gains server-side filters and a random pick; the RomM match picker gains "Fix match on RomM" and "Change cover"; the connected RomM screen gains confirmed maintenance tasks. See ADR-0019.

## Requirements

### Requirement: Filter Parameters

`RommService.getRomsPage` SHALL accept `RommRomFilters {favorite, hasSaves, hasStates, hasRa, playable, duplicate, missing}` (nullable booleans) and send only the set ones as the query parameters of the same names. `getRandomRom({platformIds, collectionId, virtualCollectionId})` SHALL GET `/api/roms/random` and return `RommRom?` (null on empty), returning null without a request when `supports(randomRom)` (**5.2.0**) is `unsupported`.

*Amended:* this requirement said 4.8.0. `/api/roms/random` is absent from `backend/endpoints/` at `rommapp/romm` tags 4.7.0, 4.8.0, 4.9.0, 5.0.0 and 5.1.0, and first appears in 5.1.1-beta.2 (commit `1ee6cea0`, PR #4071). Both 5.1.1 betas are prereleases with no final, so **5.2.0** is the first release that answers it. At 4.8.0 the action would have been offered on every 4.8–5.1 server and 404'd on every press.

#### Scenario: Two filters

- **WHEN** `hasSaves: true` and `playable: true` are set
- **THEN** the query carries `has_saves=true&playable=true` and nothing else new

### Requirement: Filter Menu And Chips

The browse screen SHALL offer a filter menu on the header (favourites, with saves, with states, with achievements, playable, duplicates, missing files) for the current platform or collection; toggling a filter MUST reset paging and reload with the filters; active filters MUST show as chips under the search row and MUST clear when leaving the platform or collection. The menu MUST be reachable by controller and B MUST close it.

#### Scenario: Toggle and reload

- **WHEN** "with saves" is toggled on
- **THEN** the list reloads from offset 0 with `has_saves=true` and a chip reads "With saves"

### Requirement: Surprise Me

The browse screen SHALL offer "Surprise me" (Select+Y, mirroring the local random gesture, and an action on the ROM view's own header row) in a platform or collection, calling `getRandomRom` scoped to it and focusing the result in the list (loading pages until present, bounded by the existing page cap); a pick that cannot be reached within the cap MUST still be reported by name. Empty MUST show a localized message. Hidden when unsupported.

*Amended:* this said "a header action" and "or opening its card". The account header only renders at the library root, where there is no platform to scope a pick to, so the action lives on the ROM view's header row. And there is no card to open — `RommRomCard` is the grid tile, not a detail surface — so an unreachable pick is named in a toast.

#### Scenario: Random pick

- **WHEN** Select+Y is pressed in a platform
- **THEN** one ROM is returned and focused

### Requirement: Metadata Search And Apply

`RommService.searchRomMetadata(romId, searchTerm)` SHALL GET `/api/search/roms?rom_id=&search_term=` and parse `RommSearchResult` (provider ids, name, summary, cover URLs, platformId). `applyRomMatch(romId, result)` SHALL `PUT /api/roms/{id}` as multipart with the result's provider ids, `name`, and `url_cover`. `searchCovers(term)` SHALL GET `/api/search/cover`. `applyRomCover(romId, url)` SHALL `PUT` with `url_cover`. Writes MUST return early when `hasScope(romsWrite)` is `denied`; a 500 from search MUST map to `RommErrorKind.noMetadataSource`.

#### Scenario: Apply

- **WHEN** a result with `igdb_id 123` is applied
- **THEN** the multipart form carries `igdb_id=123`, `name`, `url_cover`, and the detailed ROM is returned

### Requirement: Fix Match In The Picker

The RomM match picker SHALL offer "Fix match on RomM" and "Change cover" on a linked game when connected, `hasScope(romsWrite)` is **not `denied`**, and the heartbeat reports at least one metadata source enabled (an absent or empty map does not gate, per ADR-0010's "unknown never gates"). "Fix match" MUST open a search prefilled with the game name, list results with name and cover, confirm before applying, apply, then run the metadata fetch in replace mode for the game. "Change cover" MUST list covers and apply the chosen URL, then refresh the local cover. Every control MUST be reachable by controller.

#### Scenario: Fix and refetch

- **WHEN** the user picks a result and confirms
- **THEN** the match is applied and the local metadata is replaced from RomM

### Requirement: Maintenance Tasks

`RommService.runTask(name)` SHALL `POST /api/tasks/run/{name}` and return the queued task id; 400 or a "already running" answer MUST map to `RommErrorKind.taskBusy`. The connected RomM screen's header menu SHALL offer "Server maintenance" with "Rescan library" (`scan_library`), "Sync folder scan" (`sync_folder_scan`), and "Clean up missing ROMs" (`cleanup_missing_roms`), each confirmed, shown only when `hasScope(tasksRun)` is **`granted`**, reporting queued or busy.

*Scope-gate rule (amended; applies to this REQ and REQ "Fix Match In The Picker").* `hasScope` returns `granted`, `denied` or `unknown`, and the two REQs deliberately differ:

- A **per-entry write the user confirms by name** gates on **not `denied`** — it follows ADR-0013's convention that only `denied` gates, the write is still refused server-side, and a 403 settles the group so the action then disappears.
- A **library-wide queued job** (rescan, folder sync, prune) gates on **`granted`** — it is not individually confirmable in its effects, so it earns the stricter reading.

Both REQs previously said "granted". The strict gate stays, but its former consequence does not. This clause used to read that `configure()` resets every group to `unknown`, only a fresh password grant negotiates them, and therefore **token-restored sessions and every API-key connection — which is what ADR-0007's pair-code and QR logins mint — never see the maintenance menu**, leaving those users to run maintenance from RomM's own web UI. That was true of the implementation and was reported as issue #168: pairing/QR is the primary login on a handheld, so "the strict gate" meant "the feature is unreachable for most users" rather than "the feature is guarded". Per the amended SPEC-0013 REQ "Optional Scope Groups", a non-password login now learns its groups from `oauth_scopes` on `GET /api/users/me`, so `granted` is reachable on every login path and the menu appears whenever the credential genuinely holds `tasks.run`. The gate is unchanged and still refuses to offer a library-wide queued job on `unknown`.

#### Scenario: Rescan

- **WHEN** "Rescan library" is confirmed
- **THEN** one task-run request is sent and the screen reports "queued"

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (endpoint, status), MUST NOT be swallowed, key=value logging; gated early returns logged once per connection.

#### Scenario: No provider

- **WHEN** search answers 500
- **THEN** the picker shows the localized "server has no metadata source" and one warning names the endpoint
