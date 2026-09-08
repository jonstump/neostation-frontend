---
status: draft
date: 2026-09-06
implements: [ADR-0011]
requires: [SPEC-0001, SPEC-0004, SPEC-0010]
---

# SPEC-0011: RomM Hash-Based Linking

## Graph Edges

- **Implements:** [ADR-0011](../../adrs/ADR-0011-link-local-roms-to-romm-by-hash.md) — link local ROMs to RomM entries by content hash
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — the connect-time link pass this spec adds a stage to
- **Requires:** [SPEC-0004](../romm-manual-link-picker/spec.md) — the manual picker that gains a match-by-hash action
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — the version gate for the by-hash endpoint

## Overview

The connect-time link pass gains a second stage: games still unlinked after filename matching are matched by crc32 (confirmed by md5 and size when both sides have them) against the hashes RomM already includes in the platform pages the pass enumerates. Local fingerprints come from the columns the ScreenScraper path persists, topped up with the cheap zip-central-directory crc32 for games that lack one. The manual picker gains "Match by hash", which fingerprints the one file fully and asks `GET /api/roms/by-hash`. See ADR-0011.

## Requirements

### Requirement: Hash Fields On The ROM Model

`RommRom` and `RommRomFile` SHALL parse `crc_hash`, `md5_hash`, `sha1_hash`, and `ra_hash` (and `chd_sha1_hash` on the file model) as nullable strings normalized to lowercase hex with surrounding whitespace removed; an empty string MUST become null. `RommRom` SHALL expose `allCrc32` and `allMd5`: the ROM-level value plus every file-level value, deduplicated.

#### Scenario: Page with hashes

- **WHEN** a ROM in a list page carries `crc_hash: "1A2B3C4D"` and one file with `crc_hash: "1a2b3c4d"` and `md5_hash: null`
- **THEN** `allCrc32` is `{"1a2b3c4d"}` and `allMd5` is empty

### Requirement: Local Fingerprints In The Link Index

The link pass's local index SHALL carry each game's persisted `rom_crc32`, md5 (`ss_hash`), and `rom_size` from `user_roms`, exposed on the game model the pass reads. For games that are unlinked after the filename stage and have no persisted crc32 and are not marked fingerprint-skipped, the pass SHALL compute the cheap fingerprint (`FingerprintEffort.cheapOnly`, the enum value that already existed — this spec originally named it `cheap`: zip central directory only, no read for other files), bounded by a per-pass cap of 500 files, and MUST persist the result (or the skip reason) through the existing fingerprint columns so a later pass pays nothing for that game. A file whose cheap fingerprint would cost a full read — a bare ROM, an archive on a packed-archive system, or a zip whose tail the central-directory reader cannot parse — is answered as deferred: it MUST NOT be fingerprinted, parked, persisted, or charged to the cap, so the same files are deferred again on every pass by design until the scraper's full path fingerprints them. Computation MUST run off the UI isolate and MUST check the pass's stop signal between files.

#### Scenario: Zipped unscraped library

- **WHEN** 40 unlinked zipped games have no persisted crc32
- **THEN** the pass reads each zip's central directory, persists 40 crc32 values, and matches with them in the same run

#### Scenario: Cap reached

- **WHEN** 900 unlinked games lack a fingerprint
- **THEN** the pass fingerprints 500, persists them, logs the remainder, and the next pass continues with the rest

### Requirement: Hash Matching Stage

After the filename stage, for each system group the pass SHALL match every still-unlinked local game that has a crc32 against the group's enumerated ROMs by crc32 equality against `allCrc32`. When both sides have an md5, the md5 MUST also agree; when both sides have a size and the local file is a bare (unpacked) file, the sizes MUST agree. The size veto MUST NOT apply to archives: RomM's `fs_size_bytes` and `file_size_bytes` are the stored archive's size, while its hashes and the local `rom_size` describe the inner image, so a size veto on an archive would reject every correct match. On a packed-archive system (arcade sets) the local size is the archive's, so the veto is lost there as well; that is harmless, because RomM's inner-content crc32 does not match the archive's crc32 in the first place. A local game whose crc32 matches more than one distinct RomM ROM id MUST be skipped and reported as an ambiguity. A filename match MUST take precedence over a hash match for the same game. Two local games matching the same RomM ROM MAY both link to it. Matching MUST happen in memory against the pages already fetched; the stage MUST NOT issue additional requests.

#### Scenario: Renamed file

- **WHEN** `Super Game (U).zip` is local with crc32 `deadbeef` and RomM has `Super Game (USA).zip` with `crc_hash deadbeef`
- **THEN** the game links to that ROM with source `hash`

#### Scenario: md5 disagrees

- **WHEN** crc32 matches but the local md5 and RomM's md5 differ
- **THEN** the game is not linked and the disagreement is counted

#### Scenario: Ambiguous crc32

- **WHEN** one local crc32 matches two RomM ROM ids
- **THEN** the game is skipped and listed among the pass's ambiguities

### Requirement: Hash Rows Follow The Link Rules

Rows written by the hash stage MUST use `putMappingsIfAbsent` with a new `RommLinkSource.hash` value stored as `link_source = 'hash'`. They MUST NOT overwrite an existing row, MUST NOT replace a manual row, and a conflict with an existing row MUST be reported through the existing conflict list. The picker's provenance text SHALL name a hash-linked row as such: "Linked by hash to {name}", matching the sibling automatic and manual lines on the Manage tab.

#### Scenario: Manual row survives

- **WHEN** a game has a manual row pointing at ROM 7 and the hash stage matches ROM 9
- **THEN** the row still points at ROM 7 and a conflict is reported

### Requirement: Pass Summary And Observability

`RommLinkPassSummary` SHALL add `hashRowsAdded`, `fingerprintsComputed`, `fingerprintsSkipped` (files parked with a persisted skip reason), `fingerprintsDeferred` (files whose cheap fingerprint would have cost a full read — bare ROMs, packed-archive sets, a zip the cheap parser declined — neither parked nor persisted nor charged to the cap, so a bare-ROM library reports the same count on every pass; these are not "skipped"), `fingerprintsRemaining` (unlinked games still without a fingerprint when the cap stopped the pass — the "logs the remainder" scenario), and `hashMismatches`, and the pass's single summary log line MUST include them. The hash stage MUST honour the pass's cancellation, single-instance, and scheduling guards unchanged.

#### Scenario: Summary line

- **WHEN** a pass links 3 games by filename and 5 by hash after computing 12 fingerprints
- **THEN** the summary reports rowsAdded 3, hashRowsAdded 5, fingerprintsComputed 12

### Requirement: ROM Lookup By Hash

`RommService.getRomByHash({crc32, md5, sha1})` SHALL GET `/api/roms/by-hash` with only the query parameters it was given (`crc_hash`, `md5_hash`, `sha1_hash`), each value passed through `normalizeRommHash` (trimmed, lowercased) before the request because RomM stores lowercase hex while the local `RomFingerprint.crc32` is uppercase by convention, through the shared auth-retry policy, and SHALL return the parsed `RommRom` on 200, null on 404, and throw `RommException` otherwise. It MUST return null without sending a request when `supports(RommFeature.romLookupByHash)` is `unsupported`, logging the gate once per connection.

#### Scenario: Hit

- **WHEN** called with crc32 `DEADBEEF` and an md5 and the server answers 200
- **THEN** the request carries `crc_hash=deadbeef` and `md5_hash` only, and the ROM is returned

#### Scenario: Old server

- **WHEN** the server is 4.4.0
- **THEN** no request is sent and null is returned

### Requirement: Match By Hash In The Picker

The manual link picker SHALL offer a "Match by hash" action when `supports(romLookupByHash)` is `supported` or `unknown` (the gate is read once, when the picker's controller is built). Activating it MUST compute the full fingerprint for the game's file in the background (`RomFingerprintService.computeInBackground`, respecting the system's packed-archive policy), call `getRomByHash`, and on a hit pin the result first in the list and move the highlight onto it; the hash hit is the picker's pinned row and MUST outrank a caller-supplied `preselected` ROM, and it MUST stay first through later searches. A later run that ends in a miss, a fingerprint skip, or a failure MUST drop the previous hit's pin, so the pinned row and the result line always describe the same run. On a miss it MUST show a localized "no match by hash" line; on a fingerprint skip (disc image, oversize, missing, extraction failure, read error) it MUST show the localized skip reason, translated rather than the fingerprint service's raw token; on a lookup failure it MUST show a localized error line. The action MUST be reachable by controller, MUST show a busy state while running, and MUST be cancellable with B: while a run is busy, B cancels the run and keeps the dialog open (the search results and any earlier pin intact, the late result discarded silently); only when nothing is running does B close the dialog.

#### Scenario: Hit

- **WHEN** the user presses "Match by hash" and the server returns a ROM
- **THEN** the ROM is preselected and confirming writes a manual row as today

#### Scenario: Miss

- **WHEN** the server answers 404
- **THEN** the picker shows the "no match by hash" line and keeps its search results

#### Scenario: Later miss drops the pin

- **WHEN** a run pinned ROM 41 and a second press over the same file ends in a miss
- **THEN** the pinned row is cleared, the "no match by hash" line shows, and ROM 41 is no longer first

#### Scenario: B while busy

- **WHEN** the user presses B while the fingerprint of a large ROM is being read
- **THEN** the run is cancelled, the dialog stays open with the spinner gone and the search results intact, and a second B closes it

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations; no hardcoded UI text. The picker's keys are `rommMatchByHash` (the action), `rommMatchByHashBusy`, `rommMatchByHashNoMatch`, `rommMatchByHashSkipped` (with a `{reason}` placeholder), `rommMatchByHashFailed`, and the five skip reasons the full fingerprint can produce — `rommMatchByHashReasonDisc`, `rommMatchByHashReasonOversize`, `rommMatchByHashReasonMissing`, `rommMatchByHashReasonExtractFailed`, `rommMatchByHashReasonError` — so the reason shown to the user is a translated string, never the service's raw token; plus the hash provenance label on the Manage tab.

#### Scenario: Missing translation

- **WHEN** a key is added to `app_locale.dart` without a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (fingerprint failures name the file; lookup failures name the status)
- Silent error swallowing MUST NOT occur: a fingerprint failure is persisted as a skip reason and counted; a lookup failure surfaces to the picker as a localized error
- A zip whose tail the cheap parser cannot read (truncated, zip64, spanned) is a declined cheap path, not a failure: it MUST be deferred — re-read on the next pass, never persisted — rather than parked, because a permanent park (`extract_failed`) would stop the scraper's full path from ever trying 7-Zip extraction, which usually succeeds where the hand parser declined
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Unreadable file

- **WHEN** a file cannot be read at all (an I/O error the fingerprint service raises)
- **THEN** the game is marked fingerprint-skipped with the reason, counted, and the pass continues

#### Scenario: Cheap path declines a zip

- **WHEN** a zip's tail cannot be parsed by the central-directory reader
- **THEN** the game is deferred — counted in `fingerprintsDeferred`, nothing persisted, nothing charged to the cap — the pass continues, and the next pass reads it again

### Requirement: Concurrency Safety

All concurrent operations MUST follow safe concurrency patterns:

- Fingerprint computation MUST run in a background isolate with the root isolate token so SAF reads work
- The pass's stop signal MUST be checked between fingerprints and between groups
- Shared state (the local index) MUST be built once per pass and not mutated from the isolate

#### Scenario: Disconnect mid-fingerprint

- **WHEN** the connection drops while fingerprints are being computed
- **THEN** the pass stops after the current file and reports stopped

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Fingerprint persistence MUST go through the repository that owns the fingerprint columns, parameterized, batched per pass
- Mapping rows MUST be written through `RommSaveMapRepository.putMappingsIfAbsent` in one transaction per group

#### Scenario: Batch persist

- **WHEN** 500 fingerprints are computed in one pass
- **THEN** they are written in batched, parameterized statements, not one statement per file
