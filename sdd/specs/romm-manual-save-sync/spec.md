---
status: draft
date: 2026-10-03
implements: [ADR-0024]
requires: [SPEC-0010, SPEC-0013, SPEC-0019]
---

# SPEC-0023: Manual RomM Save Sync

## Graph Edges

- **Implements:** [ADR-0024](../../adrs/ADR-0024-manual-romm-save-sync.md) — manual RomM save sync, per game, per system and for the library, reported in the tray
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — the connection and its error types
- **Requires:** [SPEC-0013](../romm-play-state-writeback/spec.md) — scope groups
- **Requires:** [SPEC-0019](../romm-unified-library/spec.md) — the RomM settings section and tray reporting pattern

## Overview

A "Sync saves now" action at game, system and library scope runs the existing per-game save sync in a bounded pass, yields a typed outcome per game, and reports start-to-end in the notification tray. See ADR-0024.

## Requirements

### Requirement: Three Scopes

The action SHALL be offered: per game in the game context menu, below Download/Upload, for a local game linked to RomM; per system in the system settings dialog beside the RomM metadata pass; for the whole library in the RomM settings section beside "Refresh RomM library now". Each MUST be reachable by D-pad and MUST be absent, not inert, while RomM is disconnected.

#### Scenario: Unlinked game

- **WHEN** the context menu opens for a game with no RomM link
- **THEN** Sync saves now is still offered and reports notLinked when run

### Requirement: Same Engine

Every game in a manual pass SHALL go through the per-game sync the launch and close hooks use, covering saves and states. The pass MUST upload a save that moved locally and not on the server, download one that moved on the server and not locally, and MUST NOT overwrite either side when both moved: it reports a conflict and leaves the remote beside the local as the existing conflict backup.

#### Scenario: Both changed

- **WHEN** a save changed on this device and on the server since the last sync
- **THEN** the pass reports conflict for that game, both copies exist afterwards, and nothing was uploaded

### Requirement: Typed Outcome

The pass SHALL yield `RommSaveSyncOutcome` per game: uploaded(n), downloaded(n), upToDate, conflict, notLinked, noSaves, failed(reason), with reason one of unreachable, auth, refused(status), localIo. A `RommSaveSyncSummary` SHALL carry counts per kind and the first five failures with their game names and reasons.

#### Scenario: Server down

- **WHEN** the server does not answer
- **THEN** each attempted game reports failed(unreachable) and the pass ends early after the first, since every game would fail the same way

#### Scenario: Wrong key

- **WHEN** the server answers 401 or 403 to the first game
- **THEN** that game reports failed(auth) and the pass ends

### Requirement: Tray Reporting

A pass SHALL show one tray notification at start ("Syncing saves… 0 of N"), update it per game, and end with the summary ("Saves synced: 3 up, 1 down, 20 up to date, 1 conflict, 0 failed"). A pass that ended on unreachable or auth MUST say so in the final line. The per-game cloud state SHALL carry the same outcome words.

#### Scenario: Summary line

- **WHEN** a system pass finishes with two uploads and one conflict
- **THEN** the notification ends with the counts and the conflict is named

### Requirement: Bounds And Single Instance

At most `RommPaging.concurrency` games SHALL be in flight. One manual pass at a time across every scope; a second request while one runs MUST be refused with a notice, as MUST a request while a bulk sync or a link pass is running. The pass MUST be cancellable between games and MUST stop on disconnect.

#### Scenario: Two presses

- **WHEN** Sync saves now is pressed on a system while a library pass runs
- **THEN** a notice says a sync is already running and nothing new starts

### Requirement: Pending Uploads Included

A manual pass SHALL do what the pending-upload sweep does for every game it covers, so nothing stays queued after a successful run.

#### Scenario: Queued upload

- **WHEN** a game has an upload queued from a failed close hook and a manual pass covers it
- **THEN** the upload is attempted and the queue entry cleared on success

### Requirement: Localized User-Facing Text

Every new string (the three row titles, the progress and summary lines, each outcome and reason word, the busy notice) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the analyzer runs
- **THEN** every new key has a value in every language file

### Requirement: Error Handling Standards

Every failed outcome MUST be logged once with game, system, rom id, reason and status, key=value; the pass MUST never throw past its boundary; a failure in one game MUST NOT stop the others except unreachable and auth.

#### Scenario: One bad file

- **WHEN** one game's save folder is unreadable
- **THEN** it reports failed(localIo), one warning names the path, and the rest of the pass runs

### Requirement: Database Operation Standards

The pass SHALL read and write the existing sync ledger through its repository and MUST NOT add a column or table.

#### Scenario: Schema unchanged

- **WHEN** the feature is merged
- **THEN** `_databaseVersion` is unchanged

### Requirement: Concurrency Safety

The pass MUST run detached from the widget that started it, with cancellation checked between games, and MUST serialise with the launch and close hooks so a game is never synced twice at once.

#### Scenario: Launch during a pass

- **WHEN** the user launches a game while a library pass is on another game
- **THEN** the launch hook waits for the pass to pass that game or runs after it, never concurrently on the same game
