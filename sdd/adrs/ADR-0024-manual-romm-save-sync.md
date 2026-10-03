---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-10-03
decision-makers: [Jon Stump]
extends: [ADR-0010, ADR-0013]
related: [ADR-0018, ADR-0020]
---

# ADR-0024: Manual RomM save sync, per game, per system and for the library, reported in the tray

## Context and Problem Statement

RomM save sync runs on two hooks only: before a game launches and after it closes, one game at a time (`RomMSyncProvider._syncGame`). The one library-wide pass, `fullSync`, is the pending-upload sweep: it pushes saves that failed to go up earlier, never downloads, and nothing in the UI calls it; it runs on its own thirty seconds after connecting. A failure lands in the per-game cloud icon and in the log. The notification tray hears nothing.

When saves do not line up, the user cannot tell whether NeoStation, the link, or the RomM server is at fault, and there is nothing to press. Support threads turn into log exports. A manual sync that reports what it did and what refused, in the tray, is the missing tool.

## Decision Drivers

* A user must be able to make a sync happen now, and see the outcome, without a log.
* The manual pass must use the same rules as the automatic one, or a difference between them becomes the next thing to debug.
* A manual pass has no just-finished session to break a both-changed tie, so it must not overwrite another device's newer save.
* It must say *why* something failed in words that separate "us" from "the server": not linked, no saves found, server unreachable, server refused (status), auth.
* ADR-0018 (device negotiation) may replace the decision engine later; the buttons should survive that.

## Considered Options

* A "Sync saves now" action at three scopes — game, system, library — running the existing per-game sync in a bounded pass with a typed result, reported start-to-end in the tray
* Expose `fullSync` (the upload sweep) as the manual action
* A separate "diagnose sync" screen that only reports and never transfers

## Decision Outcome

Chosen option: "Sync saves now at three scopes, same engine, typed result, tray report", because it is both the troubleshooting tool and a real sync, and it is built from the pass that already exists.

1. **Scopes.** Per game from the context menu (beside Download and Upload); per system from the system's settings dialog, where the RomM metadata pass lives; whole library from the RomM settings section beside "Refresh RomM library now". RomM "platform" and local "system" are the same set for linked games, so the system scope stands for both.
2. **Engine.** Each game goes through `_syncGame` with the rules it has today: upload what moved locally, download what moved only on the server, states as well as saves. A both-changed save is a conflict: the manual pass reports it and leaves both copies, writing the remote beside the local as today's `.romm-conflict-` backup does, and never picks a winner.
3. **Result.** A `RommSaveSyncOutcome` per game (uploaded, downloaded, upToDate, conflict, notLinked, noSaves, failed(reason)) and a `RommSaveSyncSummary` with counts and the first few failures. The reason is typed: `unreachable`, `auth`, `refused(status)`, `localIo`, `notLinked`, `noSaves`.
4. **Reporting.** One tray notification from start to end: progress by game, then the summary; a failed run names the reason and, for `refused`, the status. Per game, the same words go into the per-game cloud state.
5. **Bounds.** At most three games in flight (`RommPaging.concurrency`, as the other RomM passes), one manual pass at a time across all scopes, cancellable between games, refused while a bulk sync or a link pass runs.
6. **Pending uploads.** The manual pass includes what the sweep does, so after a run nothing is left queued.
7. **ADR-0018.** When negotiation lands, `_syncGame`'s decision changes underneath; the scopes, the result type and the tray report stay.

### Consequences

* Good, because "press this and tell me what it says" becomes possible support advice.
* Good, because the per-game cloud icon and the tray say the same thing.
* Bad, because a library-wide run on a large linked library is a long walk of save folders; the two-phase local-first filter from the sweep keeps it bearable.
* Bad, because conflicts are reported, not resolved; a resolve UI is a later decision.
* Neutral, because states remain client-reconciled whatever ADR-0018 does.

### Confirmation

* Unit tests of the pass with a fake server: each outcome kind, the bound, cancellation, single instance, a refusal while a bulk sync runs.
* Tray reporting tests with the notification service's capture.
* On a device: a wrong API key gives `auth`, a stopped server gives `unreachable`, an unlinked game gives `notLinked`, and a good run reports counts.

## Pros and Cons of the Options

### Three scopes, same engine, typed result

* Good, because one set of rules; the tool and the sync are the same thing.
* Bad, because a library pass can be slow.

### Expose the upload sweep

* Good, because it exists.
* Bad, because it never downloads and so cannot answer "why is my save not here".

### A diagnose-only screen

* Good, because no risk of moving a file.
* Bad, because the user then still has to make the sync happen somehow.

## More Information

* `lib/sync/providers/romm_provider.dart`: `_syncGame`, `retryPendingUploads`, `_guardDivergedRemote`.
* Tray pattern: `RommCatalogRefresh` reporting in `romm_connect_content.dart`.
* Spec: SPEC-0023.
