---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-09-06
decision-makers: [Jon Stump]
extends: [ADR-0010, ADR-0013]
related: [ADR-0001]
---

# ADR-0018: Move RomM save-sync bookkeeping to the server's device negotiation, in phases

## Context and Problem Statement

`RomMSyncProvider` reimplements conflict detection on the client. `_syncGame` pairs a local save with a remote one by filename after stripping RomM's datetime tag, compares the local mtime against the recorded `local_modified_at` with a two-second tolerance and the remote `updated_at` against the recorded `cloud_updated_at`, prefers local on a double change, writes a `.romm-conflict-` backup when the remote diverged, and keeps its own ledger in `app_neo_sync_state`. The connect-time sweep retries pending uploads from that ledger. It works, and it is the part of the integration with the most special cases.

RomM grew a server-side model in 4.7.0 and finished it in 5.0.0: a registered device (`POST /api/devices`), `POST /api/sync/negotiate` that takes the device's saves (`rom_id`, `file_name`, `slot`, `content_hash`, `updated_at`, size) and answers per save with `upload`, `download`, `conflict`, or `no_op` and a reason, using `device_save_syncs.last_synced_at` per device, `POST /api/saves/{id}/downloaded` to record a completed transfer, `session complete` to close the round, and `GET /api/saves/summary` for the latest per slot. Pairing is by `(rom_id, slot)` and the client already uploads with the `autosave` slot. Upstream issue misobadev/neostation-frontend#368 proposes the same move. States have no device pairing on RomM; only saves do. Should NeoStation move its bookkeeping server-side, and how?

## Decision Drivers

* The server knows what every device has seen; the client only knows itself. Conflicts detected server-side are real ones, not clock artefacts.
* NeoStation must keep working against 4.x servers and against NeoSync, whose provider shares `ISyncProvider`.
* The move must not lose the safety net that exists today: the conflict backup file and the core-mismatch state guard.
* Scopes `devices.read`/`devices.write` are new optional groups (ADR-0013); a device id is per install.
* States are outside the server model; the client path stays for them.

## Considered Options

* Adopt device negotiation for saves on RomM 5.0.0+, in three phases, keeping the client reconcile for states and for older servers
* Keep the client-side reconcile and only use `saves/summary` to cut listing cost
* Full switch: negotiation for everything, delete the client ledger

## Decision Outcome

Chosen option: "Adopt device negotiation for saves on RomM 5.0.0+, in three phases", because it hands the hard part to the component that has the information, while each phase is independently shippable and reversible. This ADR records the direction; each phase gets its own spec when it is picked up.

1. **Phase 1, register and report.** On connect to a server that supports `deviceSync` (5.0.0) with the `devices` group granted, register the install once (`POST /api/devices` with `name`, `platform`, `client: "neostation"`, `client_version`, `allow_existing: true`), persist the returned `device_id`, send `device_id` on save uploads, and call `POST /api/saves/{id}/downloaded` after every successful download and upload. No decision changes. This seeds the server's per-device history so Phase 2 has data.
2. **Phase 2, negotiate saves.** For saves, replace `_syncGame`'s decision with one `POST /api/sync/negotiate` per game (or per batch in the sweep) and act on the operations: `upload`, `download`, `no_op`; on `conflict`, keep today's behaviour (backup remote beside local, upload local) until a conflict UI exists. Close the round with `sessions/{id}/complete`, carrying the play sessions of the round. States keep the client reconcile. `app_neo_sync_state` remains for states and for the NeoSync provider.
3. **Phase 3, retire the save ledger.** Once Phase 2 has run on the user's devices for a release, drop the save rows from `app_neo_sync_state` for the RomM provider and the sweep's save half; keep `retryPendingUploads` for states only.
4. **Older servers and NeoSync.** Below 5.0.0, or when the devices group is denied, the current code path runs unchanged; the choice is per connection, made once from ADR-0010's capabilities and ADR-0013's groups.

### Consequences

* Good, because conflicts become the server's word, based on what each device saw, with no mtime tolerance.
* Good, because each phase is small and Phase 1 changes no behaviour visible to the user.
* Good, because it aligns with the direction upstream already asked for (#368).
* Bad, because two reconcile paths coexist for a while (saves negotiated, states client-side), with the ledger still needed.
* Bad, because RomM's `negotiate` cancels the device's other in-progress sessions; two NeoStation launches racing on one device id would step on each other. The provider serializes sync per connection already.
* Neutral, because `client_device_identifier` is populated by pairing flows, not by `POST /api/devices`; the fingerprint `(mac, hostname, platform)` may collide across reinstalls, and `allow_existing` makes that a reuse, which is what we want.

### Confirmation

* Phase 1 spec: device registered once, id persisted, `device_id` on uploads, `downloaded` after transfers; nothing else changes (existing sync tests pass).
* Phase 2 spec: negotiate operations mapped to actions in fakes; conflict keeps backup semantics; states untouched.
* Governing comments at each decision point and on the gate.

## Pros and Cons of the Options

### Phased adoption for saves

* Good, because reversible per phase and gated per connection.
* Good, because the server's history replaces heuristics.
* Bad, because two paths coexist for a while.

### Client reconcile plus summary

* Good, because small.
* Bad, because the heuristics stay, and conflicts remain guesses.

### Full switch

* Good, because one path.
* Bad, because states have no server model, NeoSync still needs the ledger, and 4.x servers would lose sync.

## Architecture Diagram

```mermaid
sequenceDiagram
    participant C as RomMSyncProvider
    participant R as RomM
    Note over C: Phase 1
    C->>R: POST /api/devices (allow_existing)
    R-->>C: device_id (persisted)
    C->>R: POST /api/saves?device_id=… (uploads)
    C->>R: POST /api/saves/{id}/downloaded (after any transfer)
    Note over C: Phase 2 (saves only)
    C->>R: POST /api/sync/negotiate {device_id, saves[]}
    R-->>C: operations: upload | download | conflict | no_op
    C->>C: act; conflict → backup remote, upload local
    C->>R: POST /api/sync/sessions/{id}/complete (+play sessions)
    Note over C: states: client reconcile unchanged
```

## More Information

* RomM: `backend/endpoints/device.py`, `sync.py`, `saves.py`, `handler/sync/comparison.py`; device sync since 4.7.0, `(rom_id, slot)` pairing and `device_syncs` since 5.0.0; `rom_ids` scoping on negotiate is master only.
* NeoStation: `lib/sync/providers/romm_provider.dart` (`_syncGame`, `_guardDivergedRemote`, `retryPendingUploads`, `_saveSlot`), `app_neo_sync_state`.
* Upstream issue misobadev/neostation-frontend#368. No spec yet; Phase 1 becomes a spec when scheduled.
