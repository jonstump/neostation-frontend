---
status: draft
date: 2026-09-05
implements: [ADR-0006]
extends: [SPEC-0005]
requires: [SPEC-0001]
---

# SPEC-0006: RomM-First Scrape With ScreenScraper Fallback

## Graph Edges

- **Implements:** [ADR-0006](../../adrs/ADR-0006-romm-first-scrape-with-screenscraper-fallback.md) — RomM-first scraping with ScreenScraper fallback
- **Extends:** [SPEC-0005](../romm-metadata-fetch/spec.md) — RomM metadata fetch (the writer, its modes, and provenance)
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — RomM existing ROM linking (the link rows the step resolves)

## Overview

Every scrape action, per game and bulk, tries RomM first when the app is connected to a RomM server and the game is linked, and falls back to ScreenScraper when RomM does not supply the game. With no RomM connection the actions behave exactly as before. A user with RomM but no ScreenScraper account can scrape from the same actions. See ADR-0006.

The RomM part is the SPEC-0005 writer, driven through an injectable step so `ScreenScraperService` stays free of provider imports. The explicit RomM actions from SPEC-0005 (Manage tab row, per-system pass, link-confirm fill-gaps) are unchanged.

## Requirements

### Requirement: RomM Scrape Step

The system SHALL define a RomM scrape step that `RommProvider` produces when connected and that is absent (`null`) when not connected. Given a scrape target (app system id, ROM filename with extension, system folder, overwrite flag) the step MUST resolve the game's `app_romm_rom_map` row, MUST return a "not linked" result when no row exists without contacting the server, and otherwise MUST run the SPEC-0005 writer in the mode mapped from the overwrite flag and return its outcome. For a bulk run the step MUST read the link index once and reuse it for every target. The step MUST NOT throw; failures are returned as outcomes.

#### Scenario: Disconnected

- **WHEN** RomM is not connected
- **THEN** the step is absent and every scrape entry point runs ScreenScraper exactly as before

#### Scenario: Not linked

- **WHEN** the step is asked for a game with no mapping row
- **THEN** it returns not linked and makes no request

#### Scenario: Bulk reuses the index

- **WHEN** a bulk run scrapes 300 games
- **THEN** the link index is read once and no per-game mapping query is made

### Requirement: Scrape Success Rule

The system SHALL treat the RomM step as having scraped a game only when the outcome wrote at least one metadata column or media file, or when the outcome shows the row already holds everything RomM offers (nothing written, at least one media file skipped as existing, nothing failed). Not linked, not found, a failed request, and an outcome that wrote nothing with nothing skipped MUST count as "RomM did not scrape the game" and MUST fall through to ScreenScraper.

#### Scenario: RomM delivered

- **WHEN** the step writes a description and a cover
- **THEN** ScreenScraper is not called and the result's source is `romm`

#### Scenario: RomM entry is empty

- **WHEN** the game is linked but the RomM entry has no summary, no genres, and no artwork
- **THEN** the step reports nothing written and ScreenScraper scrapes the game

#### Scenario: Already complete

- **WHEN** a fill-gaps step writes nothing because every column and media file already exists
- **THEN** the game counts as scraped by RomM and ScreenScraper is not called

### Requirement: Overwrite Mode Mapping

The system SHALL map the scrape's overwrite flag onto the writer's mode: overwrite MUST run replace mode, otherwise fill-gaps. ScreenScraper's own handling of the flag MUST be unchanged.

#### Scenario: Force Rescrape

- **WHEN** the user runs Force Rescrape on a linked game with RomM connected
- **THEN** the RomM writer runs in replace mode

#### Scenario: First scrape

- **WHEN** the grid chord scrapes a linked game that has no description yet
- **THEN** the RomM writer runs in fill-gaps mode

### Requirement: Per-Game Source Chain

`ScreenScraperService.scrapeSingleGame` SHALL accept an optional RomM step and, when present, MUST run it before any ScreenScraper work. When the step scraped the game the function MUST return success with source `romm` without checking ScreenScraper credentials. When the step did not scrape the game, or is absent, the function MUST proceed with the existing ScreenScraper flow unchanged, including the credentials check and its messages, and MUST return source `screenscraper`. The result MUST record whether RomM was attempted and fell through, so the caller can say so.

#### Scenario: No ScreenScraper credentials, RomM delivers

- **WHEN** no ScreenScraper credentials are saved, RomM is connected, and the game is linked with a populated entry
- **THEN** the scrape succeeds from RomM and no credentials message is shown

#### Scenario: No ScreenScraper credentials, RomM has nothing

- **WHEN** no ScreenScraper credentials are saved and the step did not scrape the game
- **THEN** the result is the existing "no ScreenScraper credentials" failure

#### Scenario: Fell through

- **WHEN** the game is linked, RomM returns not found, and ScreenScraper succeeds
- **THEN** the result's source is `screenscraper` and it records that RomM was attempted

### Requirement: Bulk Source Chain

`startMetadataScraping` SHALL accept an optional RomM step. The candidate query, batching, worker threads, cancellation, and quota handling MUST be unchanged. Each worker MUST run the step for its ROM before the ScreenScraper fetch and MUST skip ScreenScraper for that ROM when the step scraped it. The run MUST be allowed to start when RomM is connected and no ScreenScraper credentials exist, in which case every ROM the step does not scrape MUST be counted as failed without a ScreenScraper request. With neither RomM connected nor ScreenScraper credentials the run MUST refuse as today. The run MUST count games scraped by RomM and by ScreenScraper separately and MUST show both counts in the summary dialog; progress text MUST name the source in use for the current ROM.

#### Scenario: Mixed library

- **WHEN** a bulk run covers 120 candidates of which 100 are linked with populated RomM entries
- **THEN** 100 are scraped by RomM, 20 by ScreenScraper, and the summary shows both counts

#### Scenario: RomM only

- **WHEN** RomM is connected, no ScreenScraper credentials exist, and the run has 10 candidates of which 8 are linked
- **THEN** the run starts, 8 are scraped by RomM, 2 are counted as failed, and no ScreenScraper request is made

#### Scenario: Neither source

- **WHEN** RomM is not connected and no ScreenScraper credentials exist
- **THEN** the run refuses with the existing behaviour

#### Scenario: Cancel

- **WHEN** the user cancels during a bulk run
- **THEN** the run stops between batches exactly as today, regardless of which source was active

### Requirement: Entry Point Consistency

The Force Rescrape action, the grid and carousel scrape chord, the details-card scrape, and the Scraper screen's bulk start SHALL all pass the provider's current step into the scrape functions. The per-game sites MUST NOT pre-check ScreenScraper credentials themselves; the Scraper screen's bulk start MUST allow starting when RomM is connected. Notifications and the bulk summary MUST name the source used ("scraped from RomM", "scraped from ScreenScraper", or "RomM had nothing, scraped from ScreenScraper"). The hardcoded strings at the per-game sites ("Scraping completed", "Please log in to ScreenScraper in the Scraping tab first.", "Error: System ID is missing.") MUST be replaced with localized keys.

#### Scenario: Force Rescrape names the source

- **WHEN** Force Rescrape completes from RomM
- **THEN** the notification says the game was scraped from RomM

#### Scenario: Fallback is visible

- **WHEN** a details-card scrape fell through to ScreenScraper
- **THEN** the notification says RomM had nothing and the game was scraped from ScreenScraper

### Requirement: Cooperation With Provenance And Modes

Rows written by the step MUST carry source `romm` and rows written by ScreenScraper MUST carry `screenscraper`, per SPEC-0005. A bulk run in `new_only` mode MUST skip rows RomM completed on an earlier run, and a run in `all` mode MUST re-run the chain for every candidate.

#### Scenario: New-only after a RomM run

- **WHEN** a bulk run completed a game from RomM and the user runs another bulk scrape in new-only mode
- **THEN** that game is not a candidate

### Requirement: Localized User-Facing Text

Every new user-visible string (source names in notifications, progress text, summary counts, replaced hardcoded strings) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "scrape failed: RomM step for rom 42 failed: timeout; ScreenScraper: game not found")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Step fails then ScreenScraper fails

- **WHEN** the RomM request times out and ScreenScraper reports not found
- **THEN** the result carries the ScreenScraper failure, the RomM failure is logged with the rom id, and the notification reports the ScreenScraper failure

### Requirement: Concurrency Safety

The bulk run executes the step inside the existing worker threads and MUST follow safe concurrency patterns:

- Cancellation MUST be checked where it is today; a step in flight completes and its write is kept
- The step MUST be safe to call concurrently from several workers (no shared mutable state beyond the read-only link index)
- Cache invalidation after the run MUST go through the owners' existing methods once, as today

#### Scenario: Concurrent workers

- **WHEN** four workers run the step at once
- **THEN** each writes only its own game's row and media and the link index is not mutated

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Connection lifecycle MUST be explicitly managed — connections MUST be returned to the pool after use, with timeouts configured
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Link index read

- **WHEN** the bulk step reads the link index
- **THEN** it uses the repository's existing parameterized query
