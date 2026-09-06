---
status: draft
date: 2026-09-05
implements: [ADR-0009]
requires: [SPEC-0001]
---

# SPEC-0009: RomM Collection Mirroring

## Graph Edges

- **Implements:** [ADR-0009](../../adrs/ADR-0009-mirror-romm-collections-into-local-collections.md) — mirror synced RomM collections into NeoStation collections
- **Requires:** [SPEC-0001](../romm-existing-rom-linking/spec.md) — RomM existing ROM linking (local-copy lookup and the link index)

## Overview

Syncing a RomM collection from the RomM tab creates or updates a NeoStation collection that mirrors it. The local collection records which RomM collection it mirrors, so a later sync updates the same collection; its membership is set from the RomM collection's ROMs that exist locally, once after the sync and again after the settle rescan has indexed the downloads. The collections browser marks mirrored collections and can unlink them. See ADR-0009.

## Requirements

### Requirement: Collection Provenance Columns

The system SHALL add nullable `romm_server_url`, `romm_collection_id`, `romm_collection_virtual`, and `romm_synced_at` columns to `user_collections` by a versioned, `PRAGMA table_info`-guarded, idempotent migration, MUST select them in every collection query, and MUST expose them on `CollectionModel`. Legacy rows MUST stay null.

#### Scenario: Migration

- **WHEN** the migration runs on a database with existing collections
- **THEN** the columns exist, every existing row is null, and a second run makes no changes

### Requirement: Mirror Service

The system SHALL provide `RommCollectionMirror` with injected functions for paging the RomM collection's ROMs, resolving a ROM to a local `rom_path`, and the repository operations. `run(collection)` MUST find the local collection by server URL and RomM collection id, MUST create one named after the RomM collection when none exists (recording provenance and the sync time), MUST set membership to exactly the resolved `rom_path`s (adding missing and removing stale members), MUST leave name, image, colours, and sort order untouched on an existing collection, MUST count unresolved ROMs without adding them, MUST refuse a concurrent run, MUST check cancellation between pages, and MUST return a summary of created, added, removed, kept, and unresolved with one summary log line.

#### Scenario: First sync creates

- **WHEN** "Best of SNES" is synced and no local collection mirrors it
- **THEN** a local collection "Best of SNES" is created with provenance and every locally resolvable ROM as a member

#### Scenario: Second sync updates

- **WHEN** the same RomM collection is synced again after one ROM was removed from it on the server and one new ROM is now local
- **THEN** the same local collection gains the new member, loses the removed one, and no second collection exists

#### Scenario: Renamed locally

- **WHEN** the user renamed the mirrored collection and syncs again
- **THEN** the local name is kept

#### Scenario: Unresolved ROMs

- **WHEN** three ROMs in the RomM collection are neither local nor downloaded
- **THEN** they are counted as unresolved and not added

### Requirement: Triggered By The Collection Sync

`RommProvider.syncSource` for a collection SHALL run the mirror after the bulk sync completes and MUST NOT run it when the user declined the plan. The provider MUST remember the synced collection and run the mirror again after the settle rescan has indexed that sync's downloads, so downloaded ROMs become members. The mirror MUST NOT run on connect or for platform syncs.

#### Scenario: Sync with downloads

- **WHEN** a collection of 10 ROMs is synced, 6 are local and 4 are downloaded
- **THEN** the collection holds 6 members right after the sync and 10 once the downloads are indexed

#### Scenario: Declined plan

- **WHEN** the user declines the sync plan
- **THEN** no local collection is created or changed

#### Scenario: Cancelled mid-download

- **WHEN** the user cancels after some downloads completed
- **THEN** the mirror runs for what is local and the indexed downloads still join after the settle

### Requirement: Sync Dialog And Outcome

The sync confirmation dialog for a collection SHALL include a localized line saying the collection will be created or updated in NeoStation, and the sync outcome notification SHALL include how many games the local collection holds.

#### Scenario: Confirmation line

- **WHEN** the plan for a collection sync is shown
- **THEN** it names the NeoStation collection that will be created or updated

### Requirement: Mirrored Collections In The Browser

The collections browser SHALL mark mirrored collections with a RomM indicator and SHALL offer "Unlink from RomM" in the collection's menu, reachable by controller, which clears the provenance columns and leaves the collection and its members unchanged. Rename, image, and delete MUST keep working on mirrored collections; a deleted mirrored collection MUST be recreated by the next sync.

#### Scenario: Unlink

- **WHEN** the user chooses Unlink from RomM on a mirrored collection
- **THEN** the indicator disappears, the games stay, and the next sync of that RomM collection creates a new local collection

#### Scenario: Delete then sync

- **WHEN** the user deletes a mirrored collection and syncs the RomM collection again
- **THEN** a new local collection is created

### Requirement: Localized User-Facing Text

Every new user-visible string (dialog line, outcome count, indicator label, unlink action and confirmation) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "collection mirror failed: RomM collection 12 page 3: timeout")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Error logs MUST carry their context as `key=value` pairs in the message (this repo's `LoggerService` takes strings; a structured API is not required)

#### Scenario: Page fetch fails

- **WHEN** a page request fails mid-run
- **THEN** the run stops before writing (membership is written once at the end, so nothing partial is left), logs the collection id and page, and the outcome reports the failure

### Requirement: Concurrency Safety

The mirror runs inside the single-threaded event loop after a sync and after a settle and MUST follow safe concurrency patterns:

- Cancellation MUST be checked between pages; an in-flight page completes
- Only one mirror run MAY be active at a time; a settle-triggered run that arrives while one is active MUST be queued, not dropped
- The collections provider MUST be refreshed through its existing reload after a run

#### Scenario: Settle during a run

- **WHEN** the settle fires while the post-sync mirror is still paging
- **THEN** a second run follows the first rather than overlapping it

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Database access MUST go through the shared `SqliteService` connection via a repository; there is no connection pool in this app
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Membership update

- **WHEN** the mirror adds and removes members
- **THEN** the changes go through `CollectionRepository` with parameterized statements in one transaction
