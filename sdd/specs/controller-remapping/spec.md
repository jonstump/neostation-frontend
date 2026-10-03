---
status: draft
date: 2026-10-03
implements: [ADR-0025]
requires: [SPEC-0022]
---

# SPEC-0024: Controller Remapping

## Graph Edges

- **Implements:** [ADR-0025](../../adrs/ADR-0025-remap-controller-buttons-for-the-ui.md) — let the user remap controller buttons for the UI, per controller
- **Requires:** [SPEC-0022](../controller-button-glyphs/spec.md) — the binding table and glyphs that follow it

## Overview

A per-controller map from input type to UI action, edited in Settings > Controller by pressing the button, with rules that keep confirm, back and the modifier available. Every screen dispatches through it and every hint follows it. See ADR-0025.

## Requirements

### Requirement: The Map Is The Dispatch Table

`GamepadBinding` SHALL hold, for the connected pad, one input type per remappable action, from the user's map when one exists and from the defaults otherwise. `GamepadNavigation` MUST resolve every callback through it. The modifier (Select) and Home MUST NOT be remappable.

#### Scenario: Swapped confirm and back

- **WHEN** the map binds confirm to `buttonB` and back to `buttonA`
- **THEN** on every screen A goes back and B confirms, and the chords still use Select

### Requirement: Rules

Each remappable action SHALL have exactly one input; confirm and back MUST always be bound and never to the same input; an input MUST NOT be bound to two actions. A capture that would break a rule MUST be refused with a localized reason and leave the map unchanged. "Reset to defaults" SHALL always be on the page and reachable with the defaults.

#### Scenario: Duplicate input

- **WHEN** the user captures `buttonA` for favourite while confirm is on `buttonA`
- **THEN** the capture is refused with a reason and confirm stays on `buttonA`

### Requirement: Per Controller

Maps SHALL be keyed by the pad's stable identity: vendor and product id, or the Android device model for a built-in pad. A pad with no map SHALL use the defaults. The page SHALL show which pad is being edited and offer "Copy from…" for another pad with a map.

#### Scenario: Two pads

- **WHEN** a Nova has a swapped map and a paired Xbox pad has none
- **THEN** the Xbox pad uses the defaults

### Requirement: Capture

Selecting an action's row SHALL enter capture: the next press on the pad being edited is taken, the press that selected the row MUST NOT be taken, and B during capture MUST cancel it (B's own press not being taken either). Capture MUST time out after ten seconds and MUST ignore other pads.

#### Scenario: Confirming press

- **WHEN** the user presses A on the row for favourite
- **THEN** capture starts and that A press is not recorded as favourite's input

### Requirement: Presets

The page SHALL offer presets that apply a whole map: "Xbox default" and "Nintendo swap" (confirm/back and context/favourite swapped). Applying one MUST replace the pad's map.

#### Scenario: Nintendo swap

- **WHEN** the user applies Nintendo swap
- **THEN** confirm is `buttonB`, back `buttonA`, context `buttonY`, favourite `buttonX`

### Requirement: Hints Follow

Every glyph and every button-naming string SHALL reflect the map through SPEC-0022's binding, with no change to the hint sites.

#### Scenario: Footer after a swap

- **WHEN** confirm is on `buttonB` and the style is Xbox
- **THEN** the confirm hint draws the B glyph

### Requirement: Gamepad Navigation

Every control on the page MUST be reachable by D-pad with the current map, including after a swap; B leaves the page unless capture is active, in which case it cancels capture.

#### Scenario: Pad only

- **WHEN** the user swaps confirm and back and then presses what is now back
- **THEN** the page is left

### Requirement: Localized User-Facing Text

The page's title, action names, preset names, capture prompt, refusal reasons, reset and copy rows MUST be `AppLocale` keys with values in all twelve language files.

#### Scenario: Keys present

- **WHEN** the analyzer runs
- **THEN** every new key has a value in every language file

### Requirement: Error Handling Standards

A map that fails to load MUST fall back to the defaults with one warning naming the pad; a map that fails to save MUST keep the previous map and tell the user.

#### Scenario: Corrupt row

- **WHEN** a stored row names an input the translator no longer knows
- **THEN** that action falls back to its default and one warning names the pad and action

### Requirement: Database Operation Standards

`user_gamepad_map(controller_id TEXT, action TEXT, input TEXT, updated_at TEXT, PRIMARY KEY(controller_id, action))` SHALL be added in a versioned migration above every slot in use, guarded with `PRAGMA table_info`, with a migration test; access only through a repository.

#### Scenario: Upgrade

- **WHEN** a database from before the table is opened
- **THEN** the table exists afterwards and re-running the migration is a no-op

### Requirement: Concurrency Safety

The binding MUST be read from memory on every event; loads and saves run off the event path and swap the table atomically.

#### Scenario: Save during navigation

- **WHEN** a map is being written while the user navigates
- **THEN** every event resolves against one consistent table
