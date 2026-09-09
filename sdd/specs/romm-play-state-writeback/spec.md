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

`RommService` SHALL define `RommScopeGroup {playtime, collectionsWrite, romsWrite, tasksRun, devices}` with their scope strings and SHALL request the read scopes plus every group whose feature is not `unsupported` per SPEC-0010. Only `playtime` carries a version gate (`RommFeature.playSessions`); `collectionsWrite`, `romsWrite`, `tasksRun`, and `devices` carry none and are requested on every server. `collectionsWrite` was gated on `collectionRomsAddRemove` (4.9.0) while favourites were its only consumer, which settled the group as `denied` on a 4.8 server before any request and made SPEC-0015's "member added on 4.8.0 → one `PUT` with the full `rom_ids`" scenario unreachable; the scope itself exists on 4.8 and `POST|PUT|DELETE /api/collections` predate 4.9.0, only the `/roms` add/remove endpoints are 4.9.0, so the gate moved to the calls: the favourites and collection-membership calls keep their own `supports(collectionRomsAddRemove)` check (#216). The cost is one more probe POST on a non-admin 4.8 password login. On a 403 from the combined grant it MUST probe each requested group alone (read scopes plus that group), record granted groups, and issue a final grant for the read scopes plus the granted union; it MUST NOT exceed `requested groups + 2` token POSTs per login. Note that the probe run is the **ordinary** path, not an exceptional one: `tasks.run` is admin-only in RomM's scope tiering, so any non-admin password login 403s the combined grant and pays for the probes. The scenario below reads as an edge case and is not one. `hasScope(group)` MUST return `granted`, `denied`, or `unknown`. In API-key mode — which is also what ADR-0007's pair-code and QR logins mint, and what a token restored from the database presents — there is no grant to negotiate, so the groups are learned from the `oauth_scopes` list RomM returns on `GET /api/users/me`: a group MUST be `granted` when every scope in it is present and `denied` otherwise. The verification MUST NOT cost an extra request when it runs as part of `authenticate()`, which already fetches that body, and MUST be bounded per connection on the rule SPEC-0010 REQ "Probe Before The Token Grant" defines: a rejected credential is never retried; a badly-answered request is retried under a cap; an unanswered one is retried, identified by how the failure was raised rather than by a missing status code; and a failure that reaches no server without being a dropped connection MAY be bounded like a badly-answered one. A cap MUST hold against a server that alternates healthy and failing answers, so a count that resets on success MUST be paired with a ceiling that does not. This clause originally read "at most once per connection", which the implementation exceeded from the day the re-arm shipped. A missing, malformed, or **empty** `oauth_scopes` is not an answer: every group MUST stay `unknown` and a per-endpoint 403 settles it as before. (A server that does not report scopes must not be read as one that grants none — `unknown` is deliberately permissive for the groups expressed as "not `denied`", so denying on a non-answer would disable working features.) This replaces the original rule that every group stayed `unknown` in API-key mode until a 403; that rule made `granted` unreachable on every non-password login, which is what issue #168 reported. `playtimeSyncAvailable` MUST be expressed through `hasScope(playtime)`.

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

The system SHALL add `app_romm_props_outbox(rom_path PRIMARY KEY, hidden INTEGER NULL, favourite INTEGER NULL, touch_last_played INTEGER NOT NULL DEFAULT 0, updated_at TEXT)` by a versioned, guarded migration, with a repository that upserts (later values win per column), lists, and deletes rows. Hooks MUST upsert a row on the hide path (`GameVisibilityService.setHidden` and its unhide-all counterpart, the single funnel above `GameRepository.setGameHidden` / `unhideAllGames(ForSystem)`, which stay plain repository methods), `FavoritesService.toggleFavorite`, and play-session end, only when the push toggle is on and the game has a link row.

#### Scenario: Coalescing

- **WHEN** a game is hidden, then unhidden, before a flush
- **THEN** one row exists with `hidden = 0`

#### Scenario: Unlinked game

- **WHEN** an unlinked game is favourited
- **THEN** no row is written

### Requirement: Flush

The outbox MUST flush together with the play-session flush and on the connect-time sweep, and it also runs from the sync provider's per-game `_syncPlaytime` — the third flush site, where the play-session flush already ran on the post-close sync: per row, one props call (when `hidden` or `touch_last_played` is set) and one favourites call (when `favourite` is set), deleting the row on success and keeping it on failure with one warning. A 404 for the ROM MUST delete the row. A row the service gates at flush time — the server below 4.9.0 for its feature, or its scope group `denied` — MUST be deleted without a request, with one info line per connection naming the gate: the hooks cannot know the connection's version or scopes while offline, so the gate ADR-0013 §4 describes is applied at the first place it is knowable, and a gated row is not kept for replay against a later account. Rows MUST be processed in `updated_at` order and the flush MUST stop on disconnect. A flush failure has no user-facing message: the flush is a background statistic with no UI surface, so the warning line of REQ "Error Handling Standards" is the whole report.

#### Scenario: Server unreachable

- **WHEN** the flush fails with a socket error
- **THEN** rows remain and are retried on the next flush

#### Scenario: Gated at flush

- **WHEN** a queued row is flushed against a 4.8.0 server
- **THEN** the row is deleted, no request is sent, and one info line names the gate

### Requirement: Push Toggle

The RomM settings SHALL offer "Push play state to RomM", persisted in `user_config` (guarded migration column `romm_push_play_state`, default on), shown only when connected. When off, hooks MUST NOT queue rows and the existing outbox MUST be cleared.

#### Scenario: Toggle off

- **WHEN** the user turns the toggle off
- **THEN** pending rows are deleted and hiding a game queues nothing

### Requirement: Localized User-Facing Text

Every new string (toggle, favourites collection name, messages) MUST be an `AppLocale` key with all twelve translations. No flush-failure message exists, because the flush has no UI surface (REQ "Flush"); one would need a surface first.

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
