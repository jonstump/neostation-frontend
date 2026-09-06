---
status: implemented
date: 2026-09-04
implements: [ADR-0004]
extends: [SPEC-0001]
---

# SPEC-0004: RomM Manual Link Picker

## Graph Edges

- **Implements:** [ADR-0004](../../adrs/ADR-0004-manual-romm-link-picker-with-provenance.md) — manual per-game RomM link picker with link provenance
- **Extends:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — RomM existing ROM linking

## Overview

SPEC-0001 links local ROMs to RomM entries by filename and never overwrites an existing mapping. Files renamed locally and files that match more than one RomM ROM stay unlinked. This capability lets the user link, relink, or unlink one game through a search-backed picker in the game settings Manage tab, modelled on the RetroAchievements match picker, and records link provenance in `app_romm_rom_map` so download and automatic writers never replace a manual choice. See ADR-0004.

The picker searches the connected RomM server scoped to the game's system, shows enough detail to disambiguate (name, platform, `fs_name`), writes the mapping as manual, and refreshes sync state. The Manage tab shows the current link state. The connect-time pass reports manual rows it would otherwise have targeted as conflicts.

## Requirements

### Requirement: Link Provenance Column

The system SHALL add a nullable `link_source` column to `app_romm_rom_map` by a versioned migration, holding one of `download`, `auto`, or `manual`. Existing rows MUST be left null and MUST be treated as automatic. The download path MUST write `download`, the "already downloaded" paths and the connect-time pass MUST write `auto`, and the picker MUST write `manual`. The migration MUST be idempotent with a column-existence guard.

#### Scenario: Migration on an existing map

- **WHEN** the migration runs on a database that already has mapping rows
- **THEN** the column exists, every existing row has a null source, and a second run makes no changes

#### Scenario: Sources written by each writer

- **WHEN** a ROM is downloaded, another is linked by the connect pass, and a third is linked by the picker
- **THEN** their rows carry `download`, `auto`, and `manual` respectively

### Requirement: Manual Rows Are Never Replaced by Automatic Writers

The repository SHALL enforce that a row with `link_source = manual` is never replaced or removed by the download path, the "already downloaded" paths, or the connect-time pass. Insert-if-absent behaviour from SPEC-0001 MUST be unchanged. The download path's replace MUST become replace-unless-manual. A manual write MUST replace any existing row for the same filename and system folder.

#### Scenario: Re-download keeps the manual link

- **WHEN** a game with a manual link to rom id 12 is re-downloaded from RomM as rom id 40
- **THEN** the row still points at 12 with source `manual`, and the download completes

#### Scenario: Manual write replaces an automatic row

- **WHEN** the user picks rom id 40 for a game whose row points at 12 with source `auto`
- **THEN** the row points at 40 with source `manual`

#### Scenario: Pass leaves manual rows alone

- **WHEN** the connect-time pass matches a file whose row is manual to a different id
- **THEN** the row is unchanged and the conflict is logged with both ids and the source

### Requirement: Link Picker Dialog

The system SHALL provide a "Link to RomM" action in the game settings Manage tab, available only while RomM is connected, that opens a picker dialog registered as its own gamepad navigation layer. The picker MUST pre-fill the search with a cleaned title derived from the game's extension-stripped name (region, language, revision, and similar bracketed or parenthesised tags removed), MUST fall back to the cleaned title automatically when a raw query returns no results, MUST debounce searches against the server's name search scoped to the RomM platform ids that resolve to the game's system, MUST list results with name, platform, and `fs_name`, MUST indicate the currently linked ROM if any, MUST write the mapping as `manual` on confirm and refresh the game's sync state, and MUST close without changes on B. Every element MUST be reachable and operable by D-pad or controller, including the text field and escaping it with B.

#### Scenario: Link a renamed file

- **WHEN** the user opens the picker for `ct-final.sfc` under `snes`, searches "Chrono Trigger", and confirms the SNES result
- **THEN** a mapping row is written for `ct-final.sfc` in `snes` with that rom id and source `manual`, and the game's sync status is recomputed

#### Scenario: Tagged filename pre-fill

- **WHEN** the user opens the picker for `Chrono Trigger (USA) [EN,FR].nds`
- **THEN** the search field is pre-filled with `Chrono Trigger` and the first results are for that title

#### Scenario: Raw query finds nothing

- **WHEN** the user types a query containing tags that yields no results
- **THEN** the picker retries once with the cleaned form of that query and shows those results, marking that the query was cleaned

#### Scenario: Scoped search

- **WHEN** the game's system resolves to two RomM platform ids
- **THEN** the search request carries exactly those platform ids

#### Scenario: Cancel

- **WHEN** the user presses B in the picker
- **THEN** the dialog closes and no row is written or changed

#### Scenario: Disconnected

- **WHEN** RomM is not connected
- **THEN** the "Link to RomM" row is disabled and the picker cannot be opened

### Requirement: Unlink Action

The system SHALL provide an "Unlink from RomM" action in the Manage tab, available only when a mapping row exists, that removes the mapping regardless of its source, refreshes the game's sync state, and requires confirmation. After unlinking, automatic linking MAY relink the game by filename on a later connect.

#### Scenario: Unlink a manual row

- **WHEN** the user confirms unlink for a manually linked game
- **THEN** the row is removed and the game's sync status returns to disabled

#### Scenario: No row

- **WHEN** the game has no mapping row
- **THEN** the unlink action is not available

### Requirement: Link State Display

The Manage tab SHALL show the game's current RomM link state as one of: not linked, linked automatically, or linked manually, with the linked ROM's name when known.

#### Scenario: Manual state shown

- **WHEN** a game's row has source `manual`
- **THEN** the Manage tab shows it as linked manually with the ROM name

#### Scenario: Legacy null source

- **WHEN** a game's row has a null source
- **THEN** the Manage tab shows it as linked automatically

### Requirement: Search Screen Entry

The search screen's result actions SHOULD offer the link picker for a remote RomM result when a local game exists in the resolved system, in addition to the existing go-to and play actions.

#### Scenario: Link from search

- **WHEN** a RomM search result has a matching local game and the user chooses link
- **THEN** the picker opens pre-selected on that result, and confirming writes a manual row

### Requirement: Localized User-Facing Text

Every new user-visible string (rows, picker title, hints, states, confirmation, empty results) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "manual link failed: RomM search failed: connection refused")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Error logs MUST carry their context as `key=value` pairs in the message (this repo's `LoggerService` takes strings; a structured API is not required)

#### Scenario: Search fails

- **WHEN** the server search fails while the picker is open
- **THEN** the picker shows a localized error state, logs the failure, and remains usable for another search

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Database access MUST go through the shared `SqliteService` connection via a repository; there is no connection pool in this app
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Manual write

- **WHEN** the picker writes a mapping
- **THEN** it is written through the repository with a parameterized statement that also sets the source
