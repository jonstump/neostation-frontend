---
status: draft
date: 2026-09-06
implements: [ADR-0015]
requires: [SPEC-0009, SPEC-0010, SPEC-0013]
---

# SPEC-0015: RomM Collections Push

## Graph Edges

- **Implements:** [ADR-0015](../../adrs/ADR-0015-push-local-collections-to-romm.md) — push NeoStation collections to RomM, one origin per collection
- **Requires:** [SPEC-0009](../romm-collection-sync/spec.md) — provenance columns and mirror
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — version gates
- **Requires:** [SPEC-0013](../romm-play-state-writeback/spec.md) — `collectionsWrite` scope group

## Overview

A local collection can be pushed to RomM; it then records origin `local` and its later name, artwork, and membership changes push through an outbox. Mirrored collections keep origin `romm` and keep pulling. See ADR-0015.

## Requirements

### Requirement: Origin Column

A versioned, guarded, idempotent migration SHALL add `user_collections.romm_origin TEXT` (`'romm'` | `'local'` | null). The mirror MUST set `'romm'` when it creates or adopts a collection; a push MUST set `'local'`; unlink MUST clear it with the other provenance. `CollectionModel` SHALL expose `rommOrigin` and `isPushedToRomm`.

#### Scenario: Legacy mirror rows

- **WHEN** the migration runs on a database with mirrored collections
- **THEN** rows with `romm_collection_id` set get `'romm'`, others null

### Requirement: Collection Write Calls

`RommService` SHALL provide `createCollection(name, {artworkPath})` (multipart `POST /api/collections`), `updateCollection(id, {name, artworkPath, romIds})` (multipart `PUT`, `rom_ids` as a JSON array string when given), `addCollectionRoms(id, romIds)` / `removeCollectionRoms(id, romIds)` (JSON `POST|DELETE /api/collections/{id}/roms`), and `deleteCollection(id)`. Add/remove MUST fall back to `updateCollection(romIds: full set)` when `supports(collectionRomsAddRemove)` (4.9.0) is `unsupported`. Every call MUST return early when `hasScope(collectionsWrite)` is `denied`. A 500 on create with a duplicate name MUST map to `RommErrorKind.alreadyExists`.

#### Scenario: Old server membership change

- **WHEN** a member is added on a 4.8.0 server
- **THEN** one `PUT` with the full `rom_ids` is sent

### Requirement: Push Action

The collection menu SHALL offer "Push to RomM" for a connected server on collections with no provenance, excluding the favourites collection. It MUST create the RomM collection, set membership to the linked members' ROM ids, record provenance and origin `local`, and report created plus linked and unlinked member counts.

#### Scenario: Push with unlinked members

- **WHEN** a collection of five games has three linked
- **THEN** the RomM collection is created with three ROMs and the outcome reads "3 pushed, 2 not linked"

### Requirement: Follow-Up Pushes

For a `local`-origin collection the system SHALL queue, in `app_romm_collection_outbox` (versioned migration; one row per collection with pending name, artwork flag, and a membership-dirty flag), on rename, image change or clear, and member add or remove; the flush (with the props flush) MUST send one name update, one artwork update, and one membership replacement (or add/remove diff on 4.9.0+) per dirty collection. `romm`-origin collections MUST NOT queue.

#### Scenario: Offline edits

- **WHEN** two games are added and the collection renamed while disconnected
- **THEN** after reconnect one name update and one membership update are sent

### Requirement: Delete

Deleting a `local`-origin collection SHALL ask whether to delete it on RomM too; when confirmed, `deleteCollection` runs (queued if offline). Deleting a `romm`-origin collection MUST NOT touch RomM.

#### Scenario: Keep on server

- **WHEN** the user declines
- **THEN** the local collection is deleted and no request is sent

### Requirement: Origin Badge

The collections browser SHALL distinguish pushed collections from mirrored ones (glyph plus semantics label) and the unlink action SHALL apply to both, clearing origin.

#### Scenario: Unlink pushed

- **WHEN** a pushed collection is unlinked
- **THEN** it becomes an ordinary local collection and edits no longer queue

### Requirement: Localized User-Facing Text

Every new string MUST be an `AppLocale` key with all twelve translations.

#### Scenario: Missing translation

- **WHEN** a key lacks a value in one language file
- **THEN** the analyzer fails the build

### Requirement: Error Handling Standards

Errors MUST carry context (collection id, status), MUST NOT be swallowed (a failed flush row stays and is logged once), key=value logging.

#### Scenario: Deleted on server

- **WHEN** a push answers 404
- **THEN** provenance and origin are cleared, the row is dropped, and one warning names the collection

### Requirement: Database Operation Standards

Columns and the outbox MUST come from versioned migrations per `lib/data/datasources/CLAUDE.md`; statements parameterized; membership reads through `CollectionRepository`.

#### Scenario: Migration idempotent

- **WHEN** the migration runs twice
- **THEN** the column and table exist once
