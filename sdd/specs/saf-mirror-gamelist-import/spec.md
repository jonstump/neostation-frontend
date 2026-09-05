---
status: draft
date: 2026-09-04
implements: [ADR-0003]
extends: [SPEC-0002]
---

# SPEC-0003: SAF Mirror Gamelist Import

## Graph Edges

- **Implements:** [ADR-0003](../../adrs/ADR-0003-mirror-saf-gamelist-media-into-app-storage.md) — mirror SAF platform-folder gamelists and media into app storage at import time
- **Extends:** [SPEC-0002](../in-folder-gamelist-import/spec.md) — in-folder gamelist metadata import

## Overview

SPEC-0002's in-folder import operates on ROM folders that resolve to a real filesystem path and reports Android Storage Access Framework (SAF) `content://` folders as skipped. This capability removes that limitation per ADR-0003: for a SAF folder, the importer lists each system subfolder once over SAF, reads `gamelist.xml` bytes through SAF into the same parser, mirrors the mapped media category folders into an app-storage directory, and records that mirror directory as the system's media root. The media resolver, caches, and widgets are unchanged because they only ever see ordinary files.

The mirror is read-only toward the SAF tree, size-skips files already copied so re-import is cheap, is guarded by a free-space check, and is removed by the existing reset. Real-path folders keep SPEC-0002's behaviour exactly.

## Requirements

### Requirement: SAF Discovery

For a configured ROM folder that is a `content://` tree with no readable real path, the importer SHALL enumerate its immediate system subfolders using the scanner's existing SAF listing, list each subfolder exactly once, and identify from that single listing whether it contains `gamelist.xml` and which mapped media category folders it contains. Subfolder names MUST resolve to systems through the same folder-alias resolution SPEC-0002 uses. The importer MUST NOT issue per-file existence probes against the SAF tree.

#### Scenario: SAF folder with exports

- **WHEN** a `content://` ROM folder contains `snes/` holding `gamelist.xml`, `covers/`, and `screenshots/`
- **THEN** `snes` is discovered as a SAF import source with those two category folders, using one listing of `snes/`

#### Scenario: Alias subfolder over SAF

- **WHEN** the SAF subfolder is named `segacd` and the local system's canonical folder is `scd` with `segacd` as an alias
- **THEN** it resolves to the `scd` system

#### Scenario: No gamelists in the SAF tree

- **WHEN** no subfolder of the SAF ROM folder contains `gamelist.xml` or any mapped category folder with files
- **THEN** the folder contributes nothing and the result's no-gamelists outcome is set, and the folder is no longer counted as skipped for SAF

### Requirement: Gamelist Read Over SAF

The importer SHALL read `gamelist.xml` bytes through the SAF whole-file read and feed them to the same parser and matching core SPEC-0002 uses. A gamelist that cannot be read or parsed MUST be isolated: the system is counted as skipped with the reason logged, and the import continues.

#### Scenario: Parse from SAF bytes

- **WHEN** `snes/gamelist.xml` in a SAF tree contains a `<game>` whose `<path>` basename matches a scanned ROM
- **THEN** that ROM's empty metadata columns are filled exactly as in a real-path import

#### Scenario: Unreadable gamelist

- **WHEN** reading `snes/gamelist.xml` over SAF fails
- **THEN** `snes` is counted as skipped, the failure is logged with the URI, and other systems still import

### Requirement: Media Mirror

For each SAF import source, the importer SHALL copy the files in its mapped media category folders (the SPEC-0002 category set: `covers`, `3dboxes`, `marquees`, `screenshots`, `titlescreens`, `fanart`, `videos`, `images`, `thumbnails`) into `<user data>/imported_media/<system folder>/<category>/`, preserving filenames. Unmapped folders MUST NOT be copied. A destination file whose size equals the source size MUST be skipped. Copies MUST stream so large video files are not held in memory. The importer MUST report progress per system and per file count. The importer MUST NOT create, modify, move, or delete anything in the SAF tree.

#### Scenario: First mirror

- **WHEN** `snes/covers/` holds 300 images and `snes/manuals/` holds 20 PDFs
- **THEN** 300 files are written under `imported_media/snes/covers/` and nothing from `manuals/` is copied

#### Scenario: Second run skips unchanged files

- **WHEN** the mirror runs again and all 300 destination files match their source sizes
- **THEN** zero bytes are copied and the result reports 300 files skipped

#### Scenario: Changed file re-copied

- **WHEN** one source image's size differs from its mirrored copy
- **THEN** only that file is copied again

#### Scenario: SAF tree untouched

- **WHEN** a SAF import completes
- **THEN** no write, create, move, or delete call was made against any `content://` URI

### Requirement: Mirror Media Root

The importer SHALL record the mirror directory for a system, not the SAF platform folder, as that system's `esde_media_root`. Media resolution MUST then work through the unchanged SPEC-0002 per-system media root path, and NeoStation's own media directory MUST keep precedence over mirrored art.

#### Scenario: Cover resolves from the mirror

- **WHEN** `snes` was mirrored and `Chrono Trigger.sfc` has no NeoStation-owned cover
- **THEN** `<user data>/imported_media/snes/covers/Chrono Trigger.png` is offered as a cover candidate

#### Scenario: Own media still wins

- **WHEN** a game later gets a ScreenScraper cover in NeoStation's media directory
- **THEN** that cover is used and the mirrored one is not

### Requirement: Storage Budget Guard

Before copying, the importer SHALL sum the sizes of the files it would copy for the SAF folder from the listing data, subtract files that already match, and compare against free space on the user-data volume. If free space is insufficient, the importer MUST NOT start copying for that folder, MUST record a distinct budget-refused outcome with the required and available byte counts, and MUST still import metadata from the gamelists.

#### Scenario: Insufficient space

- **WHEN** the pending copy needs more bytes than are free
- **THEN** no files are copied, the result names the shortfall, and metadata rows are still written

#### Scenario: Sufficient space

- **WHEN** free space exceeds the pending copy
- **THEN** the mirror proceeds

### Requirement: Reset and Re-import

The existing import reset SHALL delete the mirror directory of every system whose `esde_media_root` lies under `<user data>/imported_media/` and then clear the column, in addition to its SPEC-0002 behaviour. Reset MUST NOT delete anything outside `<user data>/imported_media/` and MUST NOT touch the SAF tree. Re-running a SAF import after reset MUST rebuild the mirror.

#### Scenario: Reset removes the mirror

- **WHEN** the user runs the import reset after a SAF import
- **THEN** `<user data>/imported_media/snes/` is removed, the column is cleared, and the ROM folder is unchanged

#### Scenario: Real-path root untouched by reset deletion

- **WHEN** a system's media root points at a real platform folder from SPEC-0002
- **THEN** reset clears the column but deletes no files

### Requirement: Real-Path Precedence

A ROM folder that resolves to a readable real path MUST be imported exactly per SPEC-0002 with no mirror. Only folders that SPEC-0002 would have skipped as SAF take the mirror path. The result MUST state, per folder, which path was used.

#### Scenario: Mixed folders

- **WHEN** one configured ROM folder is a real path and another is SAF-only
- **THEN** the first records platform folders as media roots and the second records mirror directories, and the summary reports one of each

### Requirement: Result Reporting

The import result SHALL extend SPEC-0002's result with, per SAF folder: files copied, files skipped as unchanged, bytes copied, systems mirrored, and the budget-refused outcome when it occurs. The settings summary from SPEC-0002 MUST show these counts and MUST word the empty and refused outcomes distinctly. Every new user-visible string MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Summary after a mirror

- **WHEN** a SAF import copies 280 files and skips 20
- **THEN** the summary shows both counts and the byte total

#### Scenario: Strings localized

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "SAF mirror failed: could not read covers/Game.png: permission denied")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: One file fails to copy

- **WHEN** one media file cannot be read over SAF
- **THEN** it is counted as failed with the URI logged, and the remaining files still copy

### Requirement: Concurrency Safety

The mirror runs as a long background task inside the single-threaded event loop and MUST follow safe concurrency patterns:

- Cancellation MUST be checked between files so a user-initiated cancel stops promptly and leaves already-copied files in place
- Only one import MAY run at a time; a second start while one is running MUST be refused with a named reason
- The result MUST report a cancelled run distinctly from a completed one

#### Scenario: Cancel mid-mirror

- **WHEN** the user cancels after 100 of 300 files
- **THEN** no further files are copied, the 100 remain, and the result reports cancellation

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Connection lifecycle MUST be explicitly managed — connections MUST be returned to the pool after use, with timeouts configured
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Media root write

- **WHEN** a system's mirror directory is recorded
- **THEN** it is written through the repository with a parameterized statement
