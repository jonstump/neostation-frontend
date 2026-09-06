---
status: draft
date: 2026-09-06
implements: [ADR-0017]
requires: [SPEC-0005, SPEC-0010, SPEC-0013]
---

# SPEC-0017: RomM Manuals And Notes

## Graph Edges

- **Implements:** [ADR-0017](../../adrs/ADR-0017-view-romm-manuals-and-notes-on-device.md) — view RomM manuals in-app and keep per-game notes on RomM
- **Requires:** [SPEC-0005](../romm-metadata-fetch/spec.md) — the ROM detail fetch that carries `path_manual`
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gates
- **Requires:** [SPEC-0013](../romm-play-state-writeback/spec.md) — playtime scope group for note writes

## Overview

A linked game with a RomM manual shows a "Manual" action that downloads it once into the media cache and opens a controller-driven viewer; the game info tab lists RomM notes for the game with create, edit, and delete for the user's own. See ADR-0017.

## Requirements

### Requirement: Manual Availability

`RommRom` SHALL parse `path_manual` and `has_manual`. `RommService.manualUrlFor(rom)` SHALL return `<base>/assets/romm/resources/<path_manual>` or null. The game info tab SHALL show "Manual" for a linked game whose detail has a manual, while connected or when the manual is cached.

#### Scenario: No manual

- **WHEN** `path_manual` is null
- **THEN** no action is shown

### Requirement: Manual Download And Cache

`RommService.downloadManual(rom, destPath, {onProgress, shouldCancel})` SHALL stream the manual into `<mediaCache>/manuals/<romId>.<ext>` via `.part` and rename. Opening a cached manual MUST NOT request the network; "Refresh" MUST re-download. A `.txt`, `.md`, or `.pdf` extension is accepted; others MUST be refused with a localized message.

#### Scenario: Second open

- **WHEN** the manual was downloaded earlier
- **THEN** the viewer opens from cache with no request

### Requirement: Manual Viewer

`ManualViewerScreen` SHALL register a `GamepadNavigationManager` layer in the same post-frame callback as its navigator initialize and pop it on dispose. For PDFs it SHALL render pages with a pdfium-backed Flutter renderer available on Android, Windows, Linux, and macOS; L1/R1 MUST turn pages, the D-pad MUST pan when zoomed, a button MUST cycle zoom, a page indicator MUST be visible, and B MUST leave. For `.txt` and `.md` it SHALL render scrollable text. A render failure MUST offer "Open externally".

#### Scenario: Page turn

- **WHEN** R1 is pressed on page 3 of 10
- **THEN** page 4 renders and the indicator reads 4/10

#### Scenario: Leave

- **WHEN** B is pressed
- **THEN** the viewer closes and the game info tab's focus returns to the Manual action

### Requirement: Notes API

`RommService` SHALL provide `listNotes(romId)` (GET, own and public), `createNote(romId, {title, content, isPublic})`, `updateNote(romId, noteId, {...})`, `deleteNote(romId, noteId)` with the JSON bodies RomM expects, through the auth-retry policy, parsing `RommNote` (id, title, content, isPublic, tags, userId, username, updatedAt, isMine). Reads MUST return early when `supports(romNotes)` (4.5.0) is `unsupported`; writes additionally when `hasScope(playtime)` is `denied`.

#### Scenario: Create

- **WHEN** a note "Moves" is created
- **THEN** the body is `{"title":"Moves","content":"...","is_public":false,"tags":[]}` and the list shows it as mine

### Requirement: Notes In The Game Info Tab

The game info tab SHALL list notes for a linked game while connected (title, first line, author for others' public notes), with "Add note" and, on own notes, "Edit" and "Delete" (confirmed). Title and content MUST be entered through the app's text-field flow (B escapes a focused field). A duplicate title on the same game MUST be refused locally with a localized message. Empty and error states MUST be localized; every control MUST be reachable by controller.

#### Scenario: Edit own note

- **WHEN** the user edits a note's content and confirms
- **THEN** `updateNote` is sent and the list refreshes

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (rom id, status), MUST NOT be swallowed (viewer render failures surface the fallback and log once), key=value logging.

#### Scenario: Manual 404

- **WHEN** the static file answers 404
- **THEN** the action reports the localized "manual not available" and one warning names the URL
