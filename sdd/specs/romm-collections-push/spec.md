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

A versioned, guarded, idempotent migration SHALL add `user_collections.romm_origin TEXT` (`'romm'` | `'local'` | null). The mirror MUST set `'romm'` when it creates or adopts a collection; a push MUST set `'local'`; unlink MUST clear it with the other provenance. `CollectionModel` SHALL expose `rommOrigin` and `isPushedToRomm`. The mirror MUST NOT adopt a collection whose origin is already `'local'`: syncing the RomM collection the user pushed would otherwise flip its origin to `'romm'`, replace its membership from the server, and drop its queued edits at the next flush. The run MUST fetch no page and write nothing for it, log one `reason=local_origin` line, and report `skippedLocalOrigin` with the local id in its summary; the sync outcome surfaces that as a localized "managed from this device and was not updated from RomM" line (SPEC-0009 REQ "Sync Dialog And Outcome"). A row with no origin (pre-migration) is still adopted as `'romm'`.

#### Scenario: Legacy mirror rows

- **WHEN** the migration runs on a database with mirrored collections
- **THEN** rows with `romm_collection_id` set get `'romm'`, others null

#### Scenario: Sync of a pushed collection

- **WHEN** the user syncs from the RomM tab the collection this device pushed
- **THEN** no page is fetched, origin and members are untouched, and the outcome says the collection is managed from this device

### Requirement: Collection Write Calls

`RommService` SHALL provide `getCollection(id)`, `createCollection(name, {artworkPath})` (multipart `POST /api/collections`), `updateCollection(id, {required romIds, name, artworkPath, removeArtwork})` (multipart `PUT`; `?remove_cover=true` when `removeArtwork` clears the image), `addCollectionRoms(id, romIds)` / `removeCollectionRoms(id, romIds)` (JSON `POST|DELETE /api/collections/{id}/roms`), and `deleteCollection(id)` (a 404 counts as done). `rom_ids` is required on every `PUT`, sent as a sorted JSON array string: RomM declares it a required form field on every version (`Form(...)` on 4.8+, an unguarded `data["rom_ids"]` read before), so a `PUT` without it answers 422 or 500 and is never a rename — the original wording ("`rom_ids` as a JSON array string when given") described a request no server accepts, found blocking at the #216 review. Add/remove MUST fall back to `getCollection` plus one `updateCollection(romIds: union or difference)` when `supports(collectionRomsAddRemove)` (4.9.0) is `unsupported`, logging its own once-per-connection `reason=fallback_full_replace` line rather than the "feature gated" one, since the edit still goes out. Every call MUST return null or false without a request when `hasScope(collectionsWrite)` is `denied` (logged once per connection), and a 403 MUST settle the group as denied like the favourites calls. A 500 on create MUST map to `RommErrorKind.alreadyExists` only when the body's `detail` or `message` (or the raw body) says "already exists" or "duplicate", or names the collection as a whole word (`(^|[^a-z0-9])name([^a-z0-9]|$)`, so a one-letter name inside "Internal Server Error" does not match); any other 500 stays `other`, so a database outage does not tell the user to pick another name.

#### Scenario: Old server membership change

- **WHEN** a member is added on a 4.8.0 server
- **THEN** one `PUT` with the full `rom_ids` is sent

#### Scenario: Generic 500 on create

- **WHEN** the create answers 500 with a body of `Internal Server Error`
- **THEN** the error kind is `other`, not `alreadyExists`

### Requirement: Push Action

The collection menu SHALL offer "Push to RomM" for collections with no provenance while `RommProvider.canPushCollections` holds — connected and the `collectionsWrite` group not `denied` (`unknown` is allowed, like `playtimeSyncAvailable` and the write calls themselves: an old server or a restored token leaves the group `unknown`, and hiding the entry there would leave those users no way in; a 403 settles the group and the outcome says the login cannot write collections; SPEC-0018's maintenance menu stays strict on `granted` because its actions rescan or prune a library). The entry takes the slot "Unlink from RomM" occupies for a linked collection, so the two never appear together. The favourites collection is excluded by construction rather than by a special case: SPEC-0013's favourites collection is RomM's, found by its `is_favorite` flag and never by name (`ensureFavouritesCollection`), favourites here are a flag on the ROM, and the only local row that can stand for it is a `romm`-origin mirror of it, which the provenance rule already keeps off the entry; a local collection that happens to be named "Favorites" cannot become the favourites target (verified at the #217 review). The push MUST create the RomM collection (with the local image as `artwork` when its file exists), record provenance and origin `local` right after the create and before the membership call, then set membership to the linked members' ROM ids (`POST .../roms` on 4.9.0+, one `PUT rom_ids` below), record the pushed set as the outbox baseline (`recordPushedRomIds`, so a later rename repeats what the server holds rather than re-resolving), and report created plus linked and unlinked member counts. Writing provenance before membership means a membership failure leaves a linked collection whose members are queued (`members_dirty`) for the flush to finish, instead of an orphan on the server that the next push would answer "already exists" for; the original "create → membership → provenance" order read as strict and is superseded. `alreadyExists` MUST surface as a localized "a collection with this name already exists" line and a denied scope (null from the service, or a 403) as "this login cannot write collections"; the list reloads either way so the badge appears as soon as the row is linked.

#### Scenario: Push with unlinked members

- **WHEN** a collection of five games has three linked
- **THEN** the RomM collection is created with three ROMs and the outcome reads "3 pushed, 2 not linked"

#### Scenario: Membership call fails

- **WHEN** the create succeeds and the membership call fails
- **THEN** the collection is linked with origin `local`, its members are queued dirty, and the next flush sends them

### Requirement: Follow-Up Pushes

For a `local`-origin collection the system SHALL queue, in `app_romm_collection_outbox` (versioned migration; one row per collection: `name_dirty`, `artwork_dirty`, `members_dirty`, `delete_remote`, `last_pushed_rom_ids`, `updated_at`, plus `romm_server_url` and `romm_collection_id` copied from the collection's provenance at queue time — without them a queued delete has no target once the local row is gone, and a row for a server other than the connected one cannot be told apart), on rename, image change or clear, and member add or remove. `romm`-origin collections MUST NOT queue; the origin rule lives inside `RommCollectionOutboxService.queue`, so the hooks may call it on every collection. Queuing MUST trigger a flush through `CollectionsService.onRommOutboxQueued`, a static callback `main.dart` wires to `RommProvider.flushCollectionOutbox()`; the secondary engine never sets it, so its rows wait for the next scheduled flush; a queue or trigger failure is logged and never fails the edit.

The flush (with the props flush, and on every connect path) MUST send, per dirty collection, **one** `PUT` carrying every dirty aspect — `name` when dirty, `artwork` or `remove_cover` when dirty, and always `rom_ids`: the resolved current members when `members_dirty`, else the `last_pushed_rom_ids` baseline (what the server holds, so a rename changes nothing else), else the resolved members — with one exception: a members-only change against a 4.9.0+ server with a baseline goes out as the add/remove diff, which leaves a RomM-side membership edit alone where a replace would overwrite it. The original "one name update, one artwork update, and one membership replacement" is not what RomM accepts (REQ "Collection Write Calls"). The baseline MUST be recorded after any request that carried members, before the dirty flags clear, and the initial push MUST seed it. Re-sending the baseline overwrites a RomM-side membership edit made since the last push (already an accepted ADR-0015 consequence); a `GET` first, as the below-4.9.0 fallback does, would preserve it at one extra request and was not taken.

A successful push MUST keep the row with its flags cleared as the holder of `last_pushed_rom_ids`; only a remote delete, a 404, or an unlink drops it, and `listDirty` / `pendingCount` count only rows with a flag set. A `clearDirty` MUST leave an edit made during the push dirty (guarded on `updated_at`). A row whose scope group is `denied` MUST be **kept** without a request (logged once per connection) — unlike SPEC-0013 REQ "Flush", which drops a gated play-state row so it is not replayed against a later account. The two outboxes differ because a play-state row is a fact about *this* account's session and is meaningless under another, whereas a rename, image, or membership edit is the user's own work on a collection this device created and should land as soon as a connection can carry it; the only gate on this path is the `collections.write` scope group. The costs, accepted: a kept row is re-read (and its members re-resolved) on every flush until the scope arrives, and if a different account on the same server connects, the push goes out under that account and settles as a 403. A row for another server MUST be kept untouched; a row whose collection is gone, unlinked, or re-mirrored MUST be dropped unsent; any other failure keeps the row with one warning and clears nothing it carried; a call without a status MUST stop the run, and so MUST a disconnect between rows.

#### Scenario: Offline edits

- **WHEN** two games are added and the collection renamed while disconnected
- **THEN** after reconnect one `PUT` is sent carrying the new name and the full resolved `rom_ids`, and the baseline is refreshed

#### Scenario: Rename only

- **WHEN** a pushed collection with a baseline is renamed
- **THEN** one `PUT` is sent carrying the name and the baseline `rom_ids`, and no members are re-resolved

#### Scenario: Members only on 4.9.0

- **WHEN** one game is added to a pushed collection with a baseline on a 4.9.0 server
- **THEN** one `POST .../roms` with that ROM id is sent and the baseline is refreshed

#### Scenario: Scope denied at flush

- **WHEN** the connected login lacks `collections.write`
- **THEN** the row is kept, no request is sent, and one info line per connection names the gate

### Requirement: Delete

Deleting a `local`-origin collection SHALL ask whether to delete it on RomM too: a second `ConfirmActionDialog` after the usual delete confirmation, with "Delete on RomM" / "Keep on RomM" (B = keep). The answer travels as `deleteOnRomm:` through `CollectionsProvider.delete` → `CollectionsService.deleteCollection`, not as a callback the service invokes. When confirmed the remote delete MUST go through the outbox — `queue(id, deleteRemote: true)` *before* the local row is deleted (the row copies the provenance, so the flush still knows its target) plus an immediate flush — rather than a direct service call even when connected, so there is one code path and one 404 rule; offline deletes wait for a connection. Declining MUST discard any row queued earlier for that collection and delete only the local row. Deleting a `romm`-origin collection MUST NOT touch RomM: a mirror is never asked and never queues a delete whatever the flag says.

#### Scenario: Keep on server

- **WHEN** the user declines
- **THEN** the local collection is deleted and no request is sent

### Requirement: Origin Badge

The collections browser SHALL distinguish pushed collections from mirrored ones: `kRommPushedGlyph` (`cloud_upload`) with a localized "Pushed to RomM" semantics label, distinct from `kRommMirrorGlyph`; a pushed collection MUST never fall back to the mirror glyph even though the model's `isRommMirror` is true for it (it has a RomM id). The unlink action SHALL apply to both, clearing origin with the provenance and discarding the collection's outbox row; its confirmation text differs by origin (`collectionUnlinkPushedConfirm` for a pushed one: its changes stop pushing, its games stay here and on RomM).

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
