---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-09-06
decision-makers: [Jon Stump]
extends: [ADR-0009, ADR-0013]
related: [ADR-0010]
---

# ADR-0015: Push NeoStation collections to RomM, one origin per collection

## Context and Problem Statement

ADR-0009 mirrors a synced RomM collection into a local one, with provenance columns and managed membership, in one direction. A collection the user builds on the handheld stays on the handheld. RomM offers the write side: `POST /api/collections` (multipart: `name`, `description`, `artwork`), `PUT /api/collections/{id}` (multipart with `rom_ids` as a JSON string, replacing membership), `POST|DELETE /api/collections/{id}/roms` with `{"rom_ids": [...]}` since 4.9.0, `DELETE /api/collections/{id}`, all under `collections.write` with owner checks. How should a local collection reach RomM, and what happens when both sides change?

## Decision Drivers

* No two-way merge: the collection tables carry no version history on either side.
* The provenance columns and the mirror service exist; reuse them.
* Membership is expressed in RomM ROM ids; local members resolve through the link map, and unlinked members cannot be pushed.
* `collections.write` is an optional scope group (ADR-0013).
* Renames, artwork, and deletion need clear rules.

## Considered Options

* Explicit push with a recorded origin: a local collection pushed to RomM becomes NeoStation-origin, its later changes push; a mirrored RomM collection stays RomM-origin and keeps pulling
* Full two-way sync of every collection with last-writer-wins
* Push once, no follow-up (export)

## Decision Outcome

Chosen option: "Explicit push with a recorded origin", because it keeps each collection under exactly one writer, reuses the provenance the mirror already stores, and turns the mirror's one-way street into two one-way streets that cannot collide. Concretely:

1. **Origin column.** A versioned migration adds `user_collections.romm_origin TEXT` (`'romm'` set by the mirror, `'local'` set by a push, null otherwise). `isRommMirror` stays as is; `isPushedToRomm` is `romm_origin == 'local'`.
2. **Push action.** "Push to RomM" in the collection menu for collections with no provenance: `POST /api/collections` with the name (and the local image as `artwork` when present), then provenance recorded with origin `local`, then membership set from the linked members (`PUT` with `rom_ids` on 4.4–4.8, `POST .../roms` on 4.9.0+), then the pushed set recorded as the outbox baseline. Unlinked members are counted in the outcome. (Amended with #217: provenance is written before the membership call, so a failed membership call leaves a linked collection whose members are queued, not an orphan on the server that the next push answers "already exists" for.)
3. **Follow-up pushes.** On a local-origin collection every edit goes through a small outbox so offline edits flush later, one row per collection. `PUT /api/collections/{id}` requires `rom_ids` on every RomM version, so the flush sends one `PUT` per dirty collection carrying the dirty name and/or artwork (`remove_cover` for a cleared image) and always `rom_ids` — the resolved members when membership is dirty, else the last pushed set the row holds; a members-only change on 4.9.0+ with a baseline goes out as the `POST|DELETE .../roms` diff instead. Delete → ask "also delete on RomM?" and `DELETE /api/collections/{id}` through the same outbox when confirmed. (Amended with #216: the original "rename → `PUT name`; image change → `PUT artwork`" described requests RomM answers 422 or 500; re-sending the baseline on a rename overwrites a RomM-side membership edit since the last push, which is the consequence below.)
4. **RomM-origin collections unchanged.** Mirrors keep pulling per ADR-0009; edits to their membership still get overwritten on the next sync; the unlink action clears both provenance and origin. The mirror declines to adopt a `local`-origin collection and reports the skip, so syncing a pushed collection from the RomM tab cannot flip its writer (#216).
5. **Gates.** `collections.write` group not `denied` (`unknown` allowed, since a restored token or an old server leaves it unknown and a 403 settles it; the group carries no version gate, see ADR-0013); add/remove endpoints gated on `collectionRomsAddRemove` (4.9.0), the `GET` + `PUT rom_ids` fallback below. A scope-denied outbox row is kept until a connection can carry it, unlike ADR-0013's play-state rows, because the edit is the user's own work on a collection this device created.

### Consequences

* Good, because a curated handheld collection appears in RomM's web UI and stays current.
* Good, because mirror and push share the columns, the repository, and the menu.
* Bad, because a RomM-side edit to a NeoStation-origin collection is overwritten by the next local push; the origin badge tells the user which side owns it.
* Bad, because unlinked members never reach RomM; the outcome says how many, and ADR-0011 shrinks that set.
* Neutral, because favourites (ADR-0013) use the same endpoints but are not a pushed collection; they are excluded from the menu.

### Confirmation

* Migration test; repository tests for origin.
* Service tests: create with and without artwork; membership replace vs add/remove by version; rename; delete.
* Provider tests: push records origin; member change on local-origin flushes; on romm-origin does not; unlink clears both.
* Layout tests: menu item present only for unprovenanced collections; origin badge.
* Governing comments on the column, the push, the hooks, the menu.

## Pros and Cons of the Options

### Explicit push with recorded origin

* Good, because one writer per collection; no merge.
* Good, because the existing provenance carries it.
* Bad, because the user must choose a direction per collection.

### Full two-way sync

* Good, because edits anywhere land everywhere.
* Bad, because neither side has per-member history; last-writer-wins on membership loses removals silently.

### Push once, no follow-up

* Good, because minimal.
* Bad, because the copy drifts immediately and the user has no way to update it.

## Architecture Diagram

```mermaid
flowchart TD
    subgraph local["NeoStation collection"]
        O{"romm_origin"}
    end
    O -- "'romm' (ADR-0009)" --> Pull["mirror pulls membership on sync"]
    O -- "'local' (this ADR)" --> Push["outbox pushes name/artwork/membership"]
    O -- "null" --> Menu["menu: Push to RomM"]
    Menu --> Create["POST /api/collections (+artwork)"]
    Create --> Set["set provenance + origin local"]
    Set --> Members["PUT rom_ids | POST/DELETE /roms"]
    Members --> Base["record pushed set (outbox baseline)"]
    Push --> API["RomM collections API"]
```

## More Information

* RomM: `backend/endpoints/collections.py`; duplicate name per user answers 500 (mapped to `alreadyExists` only when the body reads as a duplicate); owner mismatch 403; `update_collection` declares `rom_ids` a required form field on every version (4.8.0 lines 375-408, master 431-464; `data["rom_ids"]` read unguarded on 4.4.0 and 3.10.0).
* NeoStation: `CollectionRepository` (provenance, `replaceMembers`), `CollectionsService` (`addGame`, `removeGame`, `renameCollection`, `setCollectionImage`), `RommSaveMapRepository.getRomIdIndex` for member resolution.
* Spec: SPEC-0015.
