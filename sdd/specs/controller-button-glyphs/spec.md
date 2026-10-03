---
status: draft
date: 2026-10-03
implements: [ADR-0023]
requires: []
---

# SPEC-0022: Controller Button Glyphs

## Graph Edges

- **Implements:** [ADR-0023](../../adrs/ADR-0023-one-source-for-controller-button-glyphs.md) — one source for controller button glyphs, with a layout style the user can pick

## Overview

Button hints are drawn by one widget from a UI action and the active glyph style, instead of 89 hard-coded Xbox asset paths. The style follows the connected controller by default and can be pinned in settings. See ADR-0023.

## Requirements

### Requirement: Actions Not Buttons

A `GamepadAction` enum SHALL name every action the UI hints at: confirm, back, context (X), favourite (Y), previousTab, nextTab, leftTrigger, rightTrigger, modifier (Select), start, dpad, dpadUp, dpadDown, dpadLeft, dpadRight, leftStick, rightStick. A `GamepadGlyph` widget SHALL take an action and draw the glyph the glyph service resolves for it. After this spec, no file under `lib/` other than the glyph service MUST reference `assets/images/gamepad/`.

#### Scenario: Footer hint

- **WHEN** a footer draws its confirm hint
- **THEN** it builds `GamepadGlyph(GamepadAction.confirm)` and the Xbox style draws the A glyph

### Requirement: Styles

The service SHALL offer four styles: `xbox`, `nintendo`, `playstation`, `positional`. Each style MUST map every `GamepadInputType` the UI hints at to an asset (or, for `positional`, a drawn diamond with the position lit) and to a spoken name for text. `nintendo` MUST show A and B, and X and Y, in swapped positions with Nintendo naming; `playstation` MUST use the shapes; `positional` MUST use no letters.

#### Scenario: Nintendo confirm

- **WHEN** the style is `nintendo` and the action is confirm
- **THEN** the glyph drawn is the button in the right-hand position, labelled A, as on a Switch

#### Scenario: Positional

- **WHEN** the style is `positional` and the action is back
- **THEN** a diamond is drawn with its bottom position lit and no letter

### Requirement: Binding Comes From The Navigator

The service SHALL resolve an action to an input type from one binding table that the navigator also reads, so a hint and the press it describes cannot disagree. When ADR-0025 lands, that table is the user's map; until then it is the navigator's defaults.

#### Scenario: Default binding

- **WHEN** no user map exists
- **THEN** confirm resolves to `buttonA` and back to `buttonB`

### Requirement: Auto Style With A Pin

The active style SHALL be `auto` by default. `auto` SHALL pick `nintendo` for a controller whose vendor id is Nintendo's and for Android device models known to carry a Nintendo-layout pad (the Retroid Pocket Nova included), `playstation` for Sony's vendor id, and `xbox` otherwise. Settings > Controller SHALL offer the style as a cycle chip (auto, Xbox, Nintendo, PlayStation, positional), stored in `user_config.gamepad_glyph_style`, and a pinned style MUST win over detection. A change MUST redraw every visible hint without a restart.

#### Scenario: Nova on auto

- **WHEN** the app runs on a Retroid Pocket Nova with the style on auto
- **THEN** hints use the Nintendo style

#### Scenario: Pin wins

- **WHEN** a Switch Pro controller is connected and the style is pinned to Xbox
- **THEN** hints use the Xbox style

### Requirement: Text Follows The Style

Every localized string that names a button SHALL take the name from the style's naming table through a placeholder (`{confirm}`, `{back}`, …) rather than spelling the letter in the translation.

#### Scenario: PlayStation text

- **WHEN** the style is `playstation` and a string reads "Press {confirm} to play"
- **THEN** it renders "Press Cross to play" in English

### Requirement: Localized User-Facing Text

The setting's title, subtitle and five style names MUST be `AppLocale` keys with values in all twelve language files. Button names per style MUST be localized where a language names them differently.

#### Scenario: Keys present

- **WHEN** the analyzer runs
- **THEN** every new key has a value in every language file

### Requirement: Error Handling Standards

An action the active style has no glyph for MUST fall back to the Xbox glyph and log once per action at warning, never throw.

#### Scenario: Missing asset

- **WHEN** a style set lacks the right-trigger asset
- **THEN** the Xbox right-trigger glyph is drawn and one warning names the style and action

### Requirement: Database Operation Standards

`gamepad_glyph_style` SHALL be added in a versioned migration above every slot in use, guarded with `PRAGMA table_info`, added to the `CREATE TABLE`, read through `ConfigModel.readString` with default `auto`, and covered by a migration test.

#### Scenario: Upgrade

- **WHEN** a database from before the column is opened
- **THEN** the column exists afterwards with `auto` and re-running the migration is a no-op

### Requirement: Concurrency Safety

Style resolution MUST be synchronous from cached state; detection runs when a controller connects and when the config changes, never during build.

#### Scenario: Build cost

- **WHEN** a screen with twenty hints builds
- **THEN** no I/O happens in build
