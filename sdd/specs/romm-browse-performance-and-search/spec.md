---
status: implemented
date: 2026-09-05
implements: [ADR-0008]
---

# SPEC-0008: RomM Browse Cover Loading And In-Platform Search

## Graph Edges

- **Implements:** [ADR-0008](../../adrs/ADR-0008-romm-browse-cover-loading-and-platform-search.md) — faster RomM browsing with server thumbnails, fixed tiles, and in-platform search

## Overview

The RomM tab draws ROM tiles from the server's small cached cover, decoded at tile size, in rows of a fixed height that never reflow, using only Flutter's in-memory image cache; and it offers a search field above the ROM grid whenever a platform or collection is open, running the provider's scoped server-side search. See ADR-0008.

## Requirements

### Requirement: Tile Cover Source Order

`RommService` SHALL provide `tileCoverUrlCandidates(rom)` returning, in order, the absolute URLs for `path_cover_small`, `path_cover_large`, and `url_cover`, skipping null or empty entries and applying the same base-URL and auth-header rules as `coverUrlCandidates`. The grid and list tiles MUST draw from this order and MUST keep falling through the list on a failed load. Surfaces that show a single large cover MAY keep the large-first order.

#### Scenario: Server thumbnail present

- **WHEN** a ROM has `path_cover_small`, `path_cover_large`, and `url_cover`
- **THEN** the tile requests the small server file first and the provider URL last

#### Scenario: No server copies

- **WHEN** a ROM has only `url_cover`
- **THEN** the tile requests the provider URL and nothing else

### Requirement: Bounded Cover Fetching

Tile covers MUST be fetched through `RommService`'s own HTTP client under a shared concurrency bound, not through Flutter's process-wide `HttpClient` by way of `Image.network`/`NetworkImage`, which has no per-host connection limit and no production hook to give it one. A screenful of tiles MUST NOT be able to open one connection per tile to the RomM server, because those connections compete with the API request fetching the next page of games on the same host.

`RommService` SHALL remember, for the current server only, cover URLs the server **answered with nothing** — a `404`/`410`, or a `200` whose body is not an image — and tiles MUST skip a remembered dead URL rather than re-request it. A request that got no such answer — a timeout, a socket or TLS failure, a `5xx`, an auth rejection — MUST NOT be remembered, because it says nothing about whether the cover exists: treating the two alike lets one roamed Wi-Fi connection or one server restart blacklist every cover in flight and leave the grid grey for the rest of the session. The fetch SHALL therefore report *why* it produced no bytes, not merely that it did. The memory MUST be cleared when the service is reconfigured, so a different server — or a reconnect after the server has filled the gaps — is asked again, MUST be bounded so it cannot grow with the library, and MUST live in memory only, leaving REQ "In-Memory Cache Only" intact.

The bound MUST admit the most recently requested cover first. A scroll asks for every tile it passes, so a fair FIFO queue puts the covers on screen behind every tile already scrolled by; with a 30-second fetch timeout that is minutes of waiting for images no longer being looked at.

#### Scenario: A screenful of tiles

- **WHEN** forty tiles ask for their covers at once
- **THEN** no more than the bound are in flight at any moment, and every one of them still completes

#### Scenario: Scrolling while the bound is saturated

- **WHEN** more covers are requested than the bound allows in flight
- **THEN** the ones requested most recently are fetched first

#### Scenario: Scrolling back to a coverless ROM

- **WHEN** a ROM whose first cover source 404s is scrolled past, disposed, and scrolled back to
- **THEN** the tile goes straight to the next source instead of re-requesting the dead one

#### Scenario: A blip while the grid loads

- **WHEN** a cover request times out, drops its socket, or comes back `5xx`
- **THEN** the URL stays retryable and the next scrollback asks for it again

#### Scenario: Pointing at a different server

- **WHEN** the service is reconfigured for another RomM instance
- **THEN** URLs remembered as dead on the previous server are forgotten

### Requirement: Decode At Tile Size

Tiles MUST request the cover with a decode width equal to the tile's logical width times the device pixel ratio, rounded up, so the decoded bitmap is no larger than what is drawn, and MUST keep the previous image on screen while a recycled tile loads a new one. The calculation MUST be a pure function with a test.

#### Scenario: Grid tile

- **WHEN** a grid tile is 120 logical pixels wide on a 2.0 pixel-ratio display
- **THEN** the cover is decoded at 240 pixels wide

#### Scenario: List tile

- **WHEN** the list layout draws its 72-pixel cover
- **THEN** the decode width follows the same rule for 72 logical pixels

### Requirement: Fixed Tile Ratio

The ROM grid SHALL lay every row out from one constant height/width ratio and MUST NOT change any row's height after covers decode. Covers MUST be drawn with cover fit inside the fixed tile. The per-cover measurement and reflow path MUST be removed.

#### Scenario: Off-ratio cover

- **WHEN** a platform mixes IGDB covers with a custom 1:1 cover
- **THEN** every tile keeps the same height and the square cover is cropped to fill its tile

#### Scenario: Scroll back

- **WHEN** the user scrolls down a page and back up
- **THEN** no row has changed height

### Requirement: In-Memory Cache Only

Cover loading MUST use Flutter's `ImageCache` as its only cache and MUST NOT write cover files to device storage. The grid SHOULD set a cache extent of about one viewport so the next rows' covers begin loading during a scroll.

#### Scenario: No files written

- **WHEN** a platform of 500 ROMs is browsed end to end
- **THEN** no cover file exists under the app's data directory afterwards

### Requirement: In-Platform Search Field

When a platform or collection is open, the RomM tab SHALL show a search field above the ROM grid as the first selectable row. A MUST focus the field for typing, B MUST leave the field with the text kept, and Down from the field MUST move into the grid. Input MUST be debounced (about 400 milliseconds) into `RommProvider.searchRoms(term)`; clearing the field MUST restore the unfiltered list; a localized line MUST show the result count or that nothing matched. The term MUST survive opening a ROM and returning to the grid, and MUST be cleared when backing out to the platform list.

#### Scenario: Narrow a platform

- **WHEN** the user opens SNES, focuses the field, types "chrono", and waits
- **THEN** one scoped server search runs and the grid shows only SNES ROMs matching "chrono" with a count line

#### Scenario: Debounce

- **WHEN** the user types six characters within 400 milliseconds
- **THEN** exactly one search request is made

#### Scenario: Clear

- **WHEN** the user clears the field
- **THEN** the full platform list is loaded again

#### Scenario: Back out

- **WHEN** the user backs out to the platform list and reopens the platform
- **THEN** the field is empty and the full list shows

### Requirement: Localized User-Facing Text

Every new user-visible string (search hint, result count, no results) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "RomM search failed: platform 12 term 'chrono': timeout")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Error logs MUST carry their context as `key=value` pairs in the message (this repo's `LoggerService` takes strings; a structured API is not required)

#### Scenario: Search request fails

- **WHEN** the server search fails
- **THEN** the existing provider error surfaces in the tab and the field stays usable for another search

### Requirement: Concurrency Safety

Cover loading and searching run inside the single-threaded event loop and MUST follow safe concurrency patterns:

- A search result MUST be ignored if a newer term was submitted before it returned
- Cover loads MUST be cancelled or ignored for a tile that has been recycled to another ROM
- Shared caches MUST be touched only through their owners' existing methods

#### Scenario: Fast typing

- **WHEN** the user types "ch", pauses, then "rono" before the first search returns
- **THEN** the grid ends on the "chrono" results, never on the "ch" results
