---
status: draft
date: 2026-09-05
implements: [ADR-0005]
extends: [SPEC-0001]
requires: [SPEC-0004]
---

# SPEC-0005: RomM Metadata Fetch

## Graph Edges

- **Implements:** [ADR-0005](../../adrs/ADR-0005-romm-as-metadata-source-for-linked-games.md) — RomM as a metadata source for linked games
- **Extends:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — RomM existing ROM linking
- **Requires:** [SPEC-0004](../romm-manual-link-picker/spec.md) — RomM manual link picker (Manage tab rows and picker confirm)

## Overview

Games linked to RomM (a row in `app_romm_rom_map`) can have their metadata and artwork pulled from the RomM server on demand, per game from the Manage tab and per system from the system settings dialog, with a fill-gaps default that never overwrites metadata from ScreenScraper, ES-DE, or manual edits, and an explicit replace mode. Link confirmations in the picker, the search screen, and the RomM browser fill gaps for that one game. A `metadata_source` column records which source wrote each row. See ADR-0005.

The connect-time link pass from SPEC-0001 still fetches nothing. RomM is not added to the ScreenScraper options screen.

## Requirements

### Requirement: Metadata Source Provenance

The system SHALL add a nullable `metadata_source` column to `user_screenscraper_metadata` by a versioned migration, holding one of `screenscraper`, `romm`, `esde`, or `manual`. Legacy rows MUST stay null. Every metadata writer MUST set the column: ScreenScraper scrapes write `screenscraper`, RomM writes `romm`, the ES-DE and in-folder importers write `esde`, and the manual metadata editor writes `manual`. Fill-gaps writers MUST set the column only when they insert a row; replacing writers MUST set it on every write.

#### Scenario: Migration

- **WHEN** the migration runs on a database with existing metadata rows
- **THEN** the column exists, every existing row is null, and a second run makes no changes

#### Scenario: Fill-gaps into an existing row keeps the source

- **WHEN** a row written by ScreenScraper has an empty genre and a RomM fill-gaps fetch supplies one
- **THEN** the genre is filled and the source stays `screenscraper`

#### Scenario: Replace sets the source

- **WHEN** a RomM replace fetch runs on a row written by ScreenScraper
- **THEN** the row's source becomes `romm`

### Requirement: RomM Metadata Writer With Two Modes

The system SHALL provide one RomM metadata writer that reads a linked game's server detail once and writes in one of two modes. In **fill-gaps** mode it MUST write only metadata columns that are null or blank and only media files that do not exist, MUST leave `is_fully_scraped` and `metadata_source` unchanged on an existing row, and MUST mark a newly inserted row fully scraped with source `romm`. In **replace** mode it MUST write every mapped column and replace every mapped media file, and MUST set `is_fully_scraped` and source `romm`. Both modes MUST map name, English description, genres, developer from companies, players, release date, and rating scaled from RomM's 0 to 100 onto the app's 0 to 20 scale, and MUST NOT write `publisher` or non-English descriptions. Media MUST cover the existing set: cover, fan art, wheel, one screenshot, video.

#### Scenario: Fill gaps preserves populated data

- **WHEN** a game has a ScreenScraper description in English and French, a publisher, and a cover, and a fill-gaps fetch runs
- **THEN** the French description, the publisher, and the cover are unchanged, and only empty columns and missing media are written

#### Scenario: Replace overwrites

- **WHEN** a replace fetch runs on the same game
- **THEN** the English description, genre, developer, players, release date, rating, and all mapped media are replaced, the French description is cleared, and the publisher is left empty

#### Scenario: Rating scale

- **WHEN** RomM reports an average rating of 85
- **THEN** the row's rating is 17

#### Scenario: No detail available

- **WHEN** the server returns no detail for the linked id
- **THEN** nothing is written and the outcome is reported as not found

### Requirement: Per-Game Fetch Action

The Manage tab SHALL offer "Fetch metadata from RomM", enabled only when the game is linked and RomM is connected. Confirming MUST let the user choose fill gaps or replace, MUST name in the replace choice that non-English descriptions are cleared and the publisher is not provided, MUST run the writer once, MUST refresh artwork caches the way Force Rescrape does, and MUST report the outcome with a localized notification. The action MUST be reachable by controller with the existing Manage tab indices unchanged.

#### Scenario: Fill gaps from the Manage tab

- **WHEN** the user chooses fill gaps for a linked game whose row has an empty description
- **THEN** the description is filled from RomM, the card shows any newly downloaded artwork, and a notification reports what was filled

#### Scenario: Not linked

- **WHEN** the game has no mapping row
- **THEN** the action is disabled

### Requirement: Per-System Fetch Pass

The system settings dialog SHALL offer "Fetch metadata from RomM" for that system, enabled only when RomM is connected. The pass MUST let the user choose fill gaps or replace up front, MUST iterate the system's games and fetch only those with a link, MUST fetch details with bounded concurrency equal to the bulk-sync concurrency constant, MUST report progress in the global notification, MUST be cancellable between games, MUST refuse a second concurrent pass with a named reason, MUST isolate per-game failures, and MUST end with a summary of linked, filled, replaced, unlinked skipped, not found, and failed counts. Games without a link MUST be counted, never fetched.

#### Scenario: Mixed system

- **WHEN** a system has 120 games of which 100 are linked and the user chooses fill gaps
- **THEN** 100 detail fetches run at the bounded concurrency, 20 games are counted as unlinked, and the summary reports the counts

#### Scenario: Cancel

- **WHEN** the user cancels after 40 of 100 games
- **THEN** no further fetches start, the 40 written games keep their metadata, and the summary reports cancellation

#### Scenario: Second pass refused

- **WHEN** a pass is running and the user starts another on any system
- **THEN** the second is refused with a localized notice

#### Scenario: One detail fetch fails

- **WHEN** one game's detail request fails
- **THEN** it is counted as failed with the id logged and the pass continues

### Requirement: Fill Gaps On Link Confirm

The system SHALL run the writer in fill-gaps mode for the single game when a link is confirmed in the picker, from the search screen's link action, or by the RomM browser's "already downloaded" confirm. The browser path's "no metadata row at all" gate MUST be removed in favour of fill-gaps. The connect-time link pass MUST NOT fetch metadata.

#### Scenario: Picker confirm fills gaps

- **WHEN** the user confirms a manual link for a game with an ES-DE-imported row that lacks a genre
- **THEN** the genre is filled from RomM and the ES-DE description is untouched

#### Scenario: Connect pass unchanged

- **WHEN** the connect-time pass links 400 games
- **THEN** no detail requests are made

### Requirement: Cooperation With ScreenScraper

RomM writes MUST cooperate with ScreenScraper's scrape modes: a fill-gaps write into an existing row MUST NOT change whether ScreenScraper's `new_only` mode considers the game, and a RomM-completed row MUST count as fully scraped so `new_only` skips it. The scrape candidate queries MUST join metadata on both filename and system id so an identically named ROM in another system is not suppressed.

#### Scenario: New-only after fill gaps

- **WHEN** a game had no row, RomM fill-gaps inserted one, and the user runs a ScreenScraper scrape in new-only mode
- **THEN** that game is skipped

#### Scenario: Same filename in two systems

- **WHEN** `Game.zip` exists under two systems and only one has a metadata row
- **THEN** new-only mode still scrapes the other

### Requirement: Localized User-Facing Text

Every new user-visible string (actions, mode choice, warnings, progress, summary, notices) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "RomM metadata fetch failed: detail request for rom 42 failed: timeout")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Media download fails

- **WHEN** the cover download fails after the metadata columns were written
- **THEN** the columns stay written, the media failure is logged with the URL, and the outcome reports partial success

### Requirement: Concurrency Safety

The per-system pass runs as a long background task inside the single-threaded event loop and MUST follow safe concurrency patterns:

- Cancellation MUST be checked between games; in-flight fetches complete and their writes are kept
- Only one pass MAY run at a time across all systems
- Cache invalidation MUST go through the owning objects' existing methods after the pass, once

#### Scenario: Dispose during a pass

- **WHEN** the dialog that started the pass is closed
- **THEN** the pass continues in the background with progress in the notification, and completion is still reported

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Connection lifecycle MUST be explicitly managed — connections MUST be returned to the pool after use, with timeouts configured
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Fill-gaps write

- **WHEN** the writer fills gaps in a row
- **THEN** it reads the row and updates only the empty columns through the repository with parameterized statements
