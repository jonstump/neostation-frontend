---
status: draft
date: 2026-09-06
implements: [ADR-0013]
requires: [SPEC-0001, SPEC-0010]
---

# SPEC-0013: RomM Play State Write-Back

## Graph Edges

- **Implements:** [ADR-0013](../../adrs/ADR-0013-push-play-state-to-romm.md) — push per-game play state to RomM, with optional scope groups
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — the link map that resolves a game to a RomM ROM id
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gates

## Overview

NeoStation pushes `hidden`, favourite membership, and last-played to RomM for linked games through an outbox flushed with play sessions. Login negotiates optional scope groups so a denied group disables its feature instead of the login. See ADR-0013.

## Requirements

### Requirement: Optional Scope Groups

`RommService` SHALL define `RommScopeGroup {playtime, collectionsWrite, romsWrite, tasksRun, devices}` with their scope strings and SHALL request the read scopes plus every group whose feature is not `unsupported` per SPEC-0010. On a 403 from the combined grant it MUST probe each requested group alone (read scopes plus that group), record granted groups, and issue a final grant for the read scopes plus the granted union; it MUST NOT exceed `requested groups + 2` token POSTs per login. `hasScope(group)` MUST return `granted`, `denied`, or `unknown`; in API-key mode every group is `unknown` until a 403 on one of its endpoints marks it `denied` for the connection. `playtimeSyncAvailable` MUST be expressed through `hasScope(playtime)`.

#### Scenario: One group denied

- **WHEN** the account allows playtime but not collections.write
- **THEN** the login succeeds with the read scopes plus playtime, `hasScope(collectionsWrite)` is `denied`, and at most `requested groups + 2` token POSTs were sent — seven for the five groups in the enum today (combined, five probes, final)

#### Scenario: Bad credentials

- **WHEN** the password is wrong
- **THEN** the combined grant fails with 401 and no probes are sent

### Requirement: Props Update Call

`RommService.updateRomProps(romId, {hidden, updateLastPlayed})` SHALL PUT `/api/roms/{id}/props` with a bare JSON body containing only the given fields and `?update_last_played=true` when requested, through the shared auth-retry policy. It MUST return early without a request when `supports(romPropsBareBody)` (RomM 4.9.0) is `unsupported` or `hasScope(playtime)` is `denied`.

#### Scenario: Hide

- **WHEN** called with `hidden: true`
- **THEN** the body is `{"hidden": true}` and no query flag is sent

### Requirement: Favourites Collection

`RommService.ensureFavouritesCollection()` SHALL find the caller's collection with `is_favorite` and create one (`POST /api/collections?is_favorite=true`, name from the localized "Favourites") when none exists, caching the id for the connection. `addFavourite(romId)` / `removeFavourite(romId)` SHALL use `POST` / `DELETE /api/collections/{id}/roms` with `{"rom_ids": [romId]}`. Both MUST return early without a request when `supports(collectionRomsAddRemove)` (4.9.0) is `unsupported` or `hasScope(collectionsWrite)` is `denied`.

#### Scenario: First favourite

- **WHEN** no favourites collection exists and a game is favourited
- **THEN** one is created and the ROM is added in the same flush

### Requirement: Props Outbox

The system SHALL add `app_romm_props_outbox(rom_path PRIMARY KEY, hidden INTEGER NULL, favourite INTEGER NULL, touch_last_played INTEGER NOT NULL DEFAULT 0, updated_at TEXT)` by a versioned, guarded migration, with a repository that upserts (later values win per column), lists, and deletes rows. Hooks MUST upsert a row on `setGameHidden`, `unhideAllGames(ForSystem)`, `toggleFavorite`, and play-session end, only when the push toggle is on and the game has a link row.

#### Scenario: Coalescing

- **WHEN** a game is hidden, then unhidden, before a flush
- **THEN** one row exists with `hidden = 0`

#### Scenario: Unlinked game

- **WHEN** an unlinked game is favourited
- **THEN** no row is written

### Requirement: Flush

The outbox MUST flush together with the play-session flush and on the connect-time sweep: per row, one props call (when `hidden` or `touch_last_played` is set) and one favourites call (when `favourite` is set), deleting the row on success and keeping it on failure with one warning. A 404 for the ROM MUST delete the row. Rows MUST be processed in `updated_at` order and the flush MUST stop on disconnect.

#### Scenario: Server unreachable

- **WHEN** the flush fails with a socket error
- **THEN** rows remain and are retried on the next flush

### Requirement: Push Toggle

The RomM settings SHALL offer "Push play state to RomM", persisted in `user_config` (guarded migration column `romm_push_play_state`, default on), shown only when connected. When off, hooks MUST NOT queue rows and the existing outbox MUST be cleared.

#### Scenario: Toggle off

- **WHEN** the user turns the toggle off
- **THEN** pending rows are deleted and hiding a game queues nothing

### Requirement: Localized User-Facing Text

Every new string (toggle, favourites collection name, messages) MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST be wrapped with context (rom id, status), never swallowed (each failed row logged once per flush), and logged as key=value pairs; scope probe results MUST be logged once per login.

#### Scenario: Probe logging

- **WHEN** login negotiates groups
- **THEN** one info line lists granted and denied groups

### Requirement: Database Operation Standards

Outbox and config columns MUST come from versioned migrations following `lib/data/datasources/CLAUDE.md`; all statements parameterized; the flush deletes each row in its own statement after the server confirms.

#### Scenario: Migration idempotent

- **WHEN** the migration runs twice
- **THEN** the table and column exist once
