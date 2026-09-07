---
status: draft
date: 2026-09-06
implements: [ADR-0016]
requires: [SPEC-0001, SPEC-0010]
---

# SPEC-0016: RomM Screenshots

## Graph Edges

- **Implements:** [ADR-0016](../../adrs/ADR-0016-sync-in-game-screenshots-with-romm.md) — push emulator screenshots to RomM and show the RomM gallery back
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — link map
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gate for the gallery

## Overview

After a play session of a linked game, new RetroArch screenshots for that game are uploaded to RomM as user screenshots and recorded in a ledger; the details card shows the RomM gallery for the game. See ADR-0016.

## Requirements

### Requirement: Screenshot Directory From RetroArch Config

`RetroArchConfigService` SHALL parse `screenshot_directory` and `sort_screenshots_by_content_enable` from `retroarch.cfg`, store them on the RetroArch config table (versioned, guarded migration), and expose them on `RetroArchConfig`. When `sort_screenshots_by_content_enable` is true the collector MUST also look in the per-content subdirectory.

#### Scenario: Directory parsed

- **WHEN** `retroarch.cfg` sets `screenshot_directory = "/storage/emulated/0/RetroArch/screenshots"`
- **THEN** the config exposes that path

### Requirement: Collector

`ScreenshotCollector.collect(game, sessionStart)` SHALL list files in the screenshot directory (and the content subdirectory when enabled) with an image extension, whose name starts with **any** of the game's content stems, and whose modification time is at or after `sessionStart` minus 5 seconds, excluding files present in the ledger with the same size. The content stems are the ROM filename stem and, for a `.zip`, the stem of its largest member — RetroArch names captures after the content it loaded, which for an archive is the inner ROM. It MUST run off the UI isolate and MUST NOT read the contents of the *candidate screenshot* files. Reading an archive's central directory to derive its content stem is permitted: it is bounded (a few ranged reads), happens once per session end rather than per candidate, and is never on the launch path.

#### Scenario: Two new captures

- **WHEN** the session produced `Game-260906-101500.png` and `Game-260906-101800.png` and one older capture exists
- **THEN** exactly the two new files are returned

### Requirement: Upload And Ledger

The system SHALL add `app_romm_screenshot_map(rom_path, file_name, file_size, romm_screenshot_id, uploaded_at, PRIMARY KEY(rom_path, file_name))` by a versioned migration. `RommService.uploadScreenshot(romId, file)` SHALL `POST /api/screenshots?rom_id=` with multipart field `screenshotFile` through the shared auth-retry policy and return the parsed `RommScreenshot` (id, fileName, fileSizeBytes, downloadPath, isGallery, isPublic). At session end for a linked game, when the toggle is on, the provider MUST upload each collected file sequentially, record successes in the ledger, log one summary line, and never block the UI or the launch path.

#### Scenario: Retry next time

- **WHEN** one of two uploads fails with a socket error
- **THEN** the other is recorded, the failed one is not, and it uploads after the next session

#### Scenario: Too large

- **WHEN** the server answers 413
- **THEN** the file is recorded as skipped (size null) so it is not retried, and one warning names it

### Requirement: Gallery Strip

The details card's screenshot tab SHALL show a "RomM gallery" strip for a linked game while connected and `supports(screenshotGallery)` (5.0.0) is not `unsupported`, listing the game's `user_screenshots` (from `GET /api/roms/{id}`) as thumbnails loaded through the media cache with a decode width, newest first, with a full-screen view on confirm and B to return. Empty and error states MUST be localized. The strip MUST be reachable by controller.

#### Scenario: Gallery

- **WHEN** the game has three RomM screenshots
- **THEN** three thumbnails render and confirming one opens it full screen

### Requirement: Upload Toggle

The RomM settings SHALL offer "Upload screenshots to RomM" (`user_config.romm_upload_screenshots`, guarded migration, default on), shown only when connected.

#### Scenario: Toggle off

- **WHEN** the toggle is off
- **THEN** session end collects nothing

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (file, status), MUST NOT be swallowed (each failed upload logged once per session end), key=value logging.

#### Scenario: Directory missing

- **WHEN** the screenshot directory does not exist
- **THEN** the collector returns empty and logs one info line naming the path

### Requirement: Concurrency Safety

Collection and uploads MUST run after the playtime hooks in a detached task guarded by the provider's disposal and connection state; one upload pass per session end.

#### Scenario: Disconnect during pass

- **WHEN** the connection drops mid-pass
- **THEN** the pass stops and the remaining files stay unrecorded

### Requirement: Database Operation Standards

Ledger and config columns MUST come from versioned migrations per `lib/data/datasources/CLAUDE.md`; parameterized statements; ledger writes through a repository.

#### Scenario: Migration idempotent

- **WHEN** the migration runs twice
- **THEN** the table and columns exist once
