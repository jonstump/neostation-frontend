---
status: draft
date: 2026-09-04
implements: [ADR-0002]
---

# SPEC-0002: In-Folder Gamelist Metadata Import

## Graph Edges

- **Implements:** [ADR-0002](../../adrs/ADR-0002-import-in-folder-gamelist-metadata.md) — import gamelist.xml metadata found inside ROM platform folders

## Overview

NeoStation imports gamelist metadata and artwork today only from the ES-DE layout: a user-picked root with `gamelists/<system>/gamelist.xml` and `downloaded_media/<system>/<category>/<stem>.<ext>`. RomM's metadata export and Batocera libraries put `gamelist.xml` and the media folders directly inside each platform folder next to the ROMs. This capability adds an in-folder discovery mode to the existing importer and replaces the single global media root with a per-system media root, so a library copied to the device with its exports in place imports metadata and artwork with no restructuring. See ADR-0002.

The importer core (gamelist parsing, basename matching against the scanned library, fill-gaps merge, `esde_imported` provenance, convention-based media lookup) is reused unchanged. Media is referenced in place and never written. The first delivery targets ROM folders that resolve to real filesystem paths; SAF-only folders on Android are detected and reported, not imported. Establishing RomM save-sync links is out of scope and is covered by SPEC-0001.

## Requirements

### Requirement: In-Folder Gamelist Discovery

The importer SHALL support an in-folder discovery mode that, for every configured ROM folder, enumerates the immediate system subfolders and treats each subfolder containing a `gamelist.xml` as an importable system whose gamelist file is `<romfolder>/<system>/gamelist.xml` and whose media root is `<romfolder>/<system>/`. Enumeration MUST use the same subdirectory listing the ROM scanner uses. System subfolder names MUST resolve to NeoStation systems through the existing folder-alias resolution. The existing ES-DE root mode MUST remain available and unchanged.

#### Scenario: RomM export copied to the device

- **WHEN** a configured ROM folder contains `snes/gamelist.xml` with sibling `snes/covers/` and `snes/screenshots/` folders, and the user runs the in-folder import
- **THEN** the `snes` system is imported from that gamelist with `<romfolder>/snes/` recorded as its media root

#### Scenario: Multiple ROM folders

- **WHEN** two configured ROM folders each contain system subfolders with gamelists
- **THEN** systems from both folders are imported and counted

#### Scenario: Alias subfolder

- **WHEN** a platform folder is named `segacd` and the local system's canonical folder is `scd` with `segacd` as an alias
- **THEN** the gamelist is imported for the `scd` system

#### Scenario: Unmatched subfolder

- **WHEN** a subfolder named `foo` contains a `gamelist.xml` but resolves to no system
- **THEN** it is counted as unmatched and skipped without error

#### Scenario: No gamelists anywhere

- **WHEN** no configured ROM folder contains any `<system>/gamelist.xml`
- **THEN** the import completes with a result stating that no in-folder gamelists were found, distinct from the ES-DE "not an ES-DE folder" result

### Requirement: Per-System Media Root

The system SHALL record a media root per system instead of one global media root. For in-folder systems the media root MUST be the absolute path of the platform folder. For ES-DE systems the existing folder-name-under-global-root behaviour MUST be preserved. Media candidate paths MUST be built from the per-system media root as `<media root>/<category>/[<subdir>/]<stem>.<ext>`, and the in-folder mode MUST NOT require the ES-DE root path setting to be set.

#### Scenario: In-folder candidate path

- **WHEN** the `snes` system's media root is `/roms/snes` and the game `Chrono Trigger.sfc` has no NeoStation-owned cover
- **THEN** `/roms/snes/covers/Chrono Trigger.png` (and the other supported extensions) are tried as cover candidates

#### Scenario: ES-DE candidate path unchanged

- **WHEN** a system was imported from an ES-DE root at `/esde` with media folder name `snes`
- **THEN** `/esde/downloaded_media/snes/covers/<stem>.png` is still tried exactly as before

#### Scenario: No ES-DE root configured

- **WHEN** the ES-DE root path setting is empty and an in-folder system has a media root recorded
- **THEN** that system's media candidates are still resolved

### Requirement: Media Category Mapping

In-folder media folders MUST map to NeoStation media slots using the existing category map: `covers` and `3dboxes` to box art, `marquees` to wheel art, `screenshots` and `titlescreens` to screenshots, `fanart` to fan art, `videos` to video. The importer SHOULD additionally accept RomM's generic `images` folder as a screenshot source and `thumbnails` as a box-art source. Folders outside the map (`manuals`, `miximages`, `backcovers`, `bezels`, `physicalmedia`, and unknown names) MUST be ignored.

#### Scenario: Marquee lookup

- **WHEN** an in-folder system has `marquees/Game.png`
- **THEN** it is used as the wheel art candidate for `Game`

#### Scenario: Unsupported folder

- **WHEN** an in-folder system has only a `manuals/` folder
- **THEN** no media candidates come from it and no error is raised

### Requirement: Read-Only Media Reference

The importer and media resolution MUST NOT create, modify, copy, or delete any file under a ROM folder or platform folder. Media MUST be referenced in place. The existing structural test that restricts which files may build media candidates MUST continue to pass, and its read-only assertion MUST cover platform folders.

#### Scenario: Import leaves the platform folder untouched

- **WHEN** an in-folder import runs over a platform folder
- **THEN** the set of files under that folder, and their contents, are identical before and after the import

### Requirement: Fill-Gaps Merge and Provenance

Imported metadata MUST follow the existing fill-gaps rule: an existing non-empty metadata column is never overwritten. Rows created by the import MUST carry the existing `esde_imported` provenance so a later scrape can upgrade them. The existing reset action MUST clear rows and media roots created by either discovery mode.

#### Scenario: Existing description preserved

- **WHEN** a game already has a description and the gamelist provides a different one
- **THEN** the existing description is kept and empty columns are filled

#### Scenario: Reset clears in-folder imports

- **WHEN** the user runs the import reset after an in-folder import
- **THEN** rows with the import provenance that were never fully scraped are removed and in-folder media roots are cleared

### Requirement: Import Entry Point and Results

The system SHALL expose the in-folder import as an action in the existing directories settings area, gated on at least one configured ROM folder, reachable and confirmable by D-pad or controller like the existing ES-DE actions. The import MUST report progress per system and a result summary with systems found, matched, unmatched, and skipped; games imported and games with no library match; and media-only systems linked. Every new user-visible string MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Action gating

- **WHEN** no ROM folders are configured
- **THEN** the in-folder import action is not available

#### Scenario: Summary shown

- **WHEN** an in-folder import completes
- **THEN** the summary shows the counts above and the user can dismiss it with the controller

#### Scenario: Strings localized

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Real-Path Scope

The in-folder mode MUST operate on ROM folders that resolve to real filesystem paths. A ROM folder that is a SAF `content://` URI and cannot be resolved to a real path MUST be skipped, counted as skipped in the result, and named in the log; it MUST NOT cause the import to fail. The result MUST make it visible to the user that folders were skipped for this reason.

#### Scenario: SAF folder without real-path access

- **WHEN** a configured ROM folder is a `content://` tree and no real path can be resolved for it
- **THEN** the import skips that folder, continues with the others, and the summary shows one folder skipped

#### Scenario: SAF folder with real-path access

- **WHEN** a `content://` ROM folder resolves to a real path through the existing resolver
- **THEN** it is scanned like any other folder

### Requirement: Schema Migration

The per-system media root MUST be added by a versioned migration, never by an on-launch column check. The migration MUST be idempotent and guard the column's existence, and existing ES-DE media folder names MUST remain valid after it runs. A downgrade recreates the database per the repository's standing rule.

#### Scenario: Upgrade from a database with ES-DE imports

- **WHEN** the migration runs on a database that already has ES-DE media folder names recorded
- **THEN** those systems continue to resolve media exactly as before the upgrade

#### Scenario: Migration re-run

- **WHEN** the migration runs twice
- **THEN** the second run makes no changes and raises no error

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "in-folder import failed: could not read /roms/snes/gamelist.xml: permission denied")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Malformed gamelist

- **WHEN** one system's `gamelist.xml` cannot be parsed
- **THEN** that system is counted as skipped with the reason logged and the import continues with the remaining systems

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Connection lifecycle MUST be explicitly managed — connections MUST be returned to the pool after use, with timeouts configured
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Per-system batch write

- **WHEN** a system's metadata rows are written
- **THEN** they are written through the repository layer in one batch with parameterized statements
