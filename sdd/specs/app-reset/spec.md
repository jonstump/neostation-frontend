---
status: draft
date: 2026-10-03
implements: [ADR-0022]
requires: []
---

# SPEC-0021: In-App Reset

## Graph Edges

- **Implements:** [ADR-0022](../../adrs/ADR-0022-reset-the-app-from-inside-the-app.md) — reset the app to first run from inside the app

## Overview

Settings > About gains a "Reset NeoStation" row that, after a typed confirmation, deletes everything the app wrote and relaunches into the setup wizard. ROM, save and BIOS files stay. See ADR-0022.

## Requirements

### Requirement: Reset Entry Point

Settings > About SHALL show a "Reset NeoStation" row as its last row, reachable by D-pad, with a subtitle saying it returns the app to first-run setup. Selecting it SHALL open the confirmation dialog. The row MUST be available whether or not the database opened, so a broken install can reach it.

#### Scenario: Row present

- **WHEN** the user opens Settings > About
- **THEN** the last row is Reset NeoStation and the cursor can reach it

### Requirement: Typed Confirmation

The dialog SHALL list what will be deleted (library database, scraped metadata and artwork, cached RomM covers, saved logins, settings, the log) and what will be kept (ROM, save, state and BIOS files), and SHALL contain a text field. The destructive button MUST stay disabled until the field holds the word RESET, compared case-insensitively. B MUST close the dialog without resetting, including out of the focused field first. The dialog MUST register its own gamepad layer.

#### Scenario: Wrong word

- **WHEN** the field holds "reset please"
- **THEN** the button stays disabled

#### Scenario: Backing out

- **WHEN** the field is focused and the user presses B twice
- **THEN** the field loses focus, then the dialog closes, and nothing was deleted

### Requirement: What A Reset Removes

`ResetService.resetAll` SHALL delete: every credential the app stored (RomM, ScreenScraper, RetroAchievements, NeoSync, through `CredentialStore`); every `SharedPreferences` key the app wrote, the custom user-data path included; the SQLite database and its journal; the media cache directory, the RomM cover cache included; the log file; and on Android every persisted SAF URI permission the app holds. It MUST NOT delete any file it did not create: ROMs, saves, states, BIOS, or anything else inside a custom user-data folder that is not the database, the media cache or the log.

#### Scenario: Custom user-data folder

- **WHEN** the user-data folder is a custom folder that also holds a `roms` directory
- **THEN** the database, media cache and log under it are deleted and `roms` is untouched

#### Scenario: Default folder

- **WHEN** the user-data folder is the app's own
- **THEN** its contents are deleted and the folder is left empty

### Requirement: Order And Resilience

Clearers SHALL run in this order: credentials, preferences, database, media cache, log, SAF grants. Each MUST be independent: a clearer that throws is logged with what it was clearing and the next one still runs. `resetAll` SHALL return a summary of what was cleared and what failed, and MUST NOT throw.

#### Scenario: Locked media file

- **WHEN** one file in the media cache cannot be deleted
- **THEN** the rest of the cache, the log and the grants are still cleared and the summary names the file

### Requirement: Relaunch

After `resetAll` the app SHALL NOT continue on the current state. On Android it SHALL finish and relaunch its activity; on desktop it SHALL restart the process where the platform allows and otherwise exit after a notice that says to start it again. The next launch MUST run the setup wizard from its first step.

#### Scenario: Android

- **WHEN** the reset completes on Android
- **THEN** the app relaunches and the wizard's first step is shown

### Requirement: Gamepad Navigation

The row and every control in the dialog MUST be reachable by D-pad. The field MUST be focusable with A and left with B. The dialog's layer MUST be popped when it closes.

#### Scenario: Pad only

- **WHEN** the user reaches the row, presses A, types RESET on the soft keyboard, presses B to leave the field, moves to the button and presses A
- **THEN** the reset runs

### Requirement: Localized User-Facing Text

Every new string (row title and subtitle, dialog title, the two lists, the field hint, the button, the desktop restart notice) MUST be an `AppLocale` key with a value in all twelve language files. The word RESET itself MUST be the same in every language, shown in the hint.

#### Scenario: Keys present

- **WHEN** the analyzer runs
- **THEN** every new key has a value in every language file

### Requirement: Error Handling Standards

Every clearer MUST log what it is clearing and the outcome with key=value context (store, path or key, error). No secret value MUST appear in a log line.

#### Scenario: Credential delete fails

- **WHEN** the secure store refuses a delete
- **THEN** one warning names the credential key and the error, never the value

### Requirement: Database Operation Standards

The reset MUST close the database before deleting its file, and MUST NOT add a column, table or migration.

#### Scenario: Open database

- **WHEN** the reset starts while the database is open
- **THEN** it is closed first and the file is deleted without an error
