# Design: RomM Manuals And Notes

## Context

See [SPEC-0017](spec.md), [ADR-0017](../../adrs/ADR-0017-view-romm-manuals-and-notes-on-device.md), [SPEC-0005](../romm-metadata-fetch/spec.md), [SPEC-0010](../romm-server-capabilities/spec.md), and [SPEC-0013](../romm-play-state-writeback/spec.md).

The details card has `GameDetailsGameInfoTab` (`lib/screens/game_screen/game_details_card/tabs/game_details_game_info_tab.dart`) and a `DetailTab` enum; full-screen routes must register a `GamepadNavigationManager` layer (CLAUDE.md). The media cache service stores downloaded images per game. `pubspec.yaml` has no PDF package. RomM: `path_manual` on the ROM schema, static manual route, notes CRUD since 4.5.0 (`title`, `content`, `is_public`, `tags`; unique `(rom, user, title)`).

## Goals / Non-Goals

### Goals
- Manual one press away, cached, controller-driven, all four platforms.
- Notes readable and editable on the device, shared with RomM's web UI.

### Non-Goals
- Uploading manuals; tags editing; public/private toggling beyond the create flag.

## Decisions

### Renderer choice deferred to implementation with hard constraints

**Choice**: a pdfium-backed Flutter renderer supporting Android, Windows, Linux, macOS; the story verifies platform matrix, license, and binary size before adding it, and records the choice in the PR.
**Rationale**: the ADR must not pin a package whose maintenance state may change; the constraints are what matter.

### Manual cached under the media cache

**Choice**: `manuals/<romId>.<ext>` in the existing media cache root; evicted with the game's media.
**Rationale**: same lifecycle as covers; no new storage location.

### Notes are fetched on tab open, not cached

**Choice**: list on open, refresh after writes; no local table.
**Rationale**: small payload, per user, and RomM is the source of truth.

## Architecture

```mermaid
sequenceDiagram
    participant T as GameDetailsGameInfoTab
    participant P as RommProvider
    participant S as RommService
    participant MC as media cache
    participant V as ManualViewerScreen
    participant R as RomM

    T->>P: manualFor(game)
    P->>MC: cached?
    alt not cached
        P->>S: downloadManual(rom, dest)
        S->>R: GET /assets/romm/resources/{path_manual}
    end
    P->>V: open(path, ext)
    V->>V: pushLayer; render; L1/R1 pages; B pops
    T->>S: listNotes(romId)
    S->>R: GET /api/roms/{id}/notes
    T->>S: createNote / updateNote / deleteNote
```

## Risks / Trade-offs

- **Binary size** → measured in the story; the renderer is the only new native dependency.
- **Unauthenticated static route** → documented; nothing client-side.
- **Text entry on a handheld** → existing text-field flow and on-screen keyboard.

## Migration Plan

No schema change.

## Open Questions

- Should the viewer remember the last page per manual? Cheap via SharedPreferences; decide in the story.
- Markdown rendering: plain text is acceptable for v1; a Markdown widget is optional.
