---
status: draft
date: 2026-10-02
implements: [ADR-0021]
requires: [SPEC-0007, SPEC-0010, SPEC-0019]
---

# SPEC-0020: RomM Step In First-Run Setup

## Graph Edges

- **Implements:** [ADR-0021](../../adrs/ADR-0021-connect-to-romm-during-first-run-setup.md) — offer the RomM connection as an optional step of first-run setup
- **Requires:** [SPEC-0007](../romm-pairing-login/spec.md) — the pairing mode and QR scan the form carries
- **Requires:** [SPEC-0010](../romm-server-capabilities/spec.md) — the connect screen's capability surfaces (version line, password-login flag)
- **Requires:** [SPEC-0019](../romm-unified-library/spec.md) — the `romm_show_library` setting the step exposes

## Overview

The setup wizard gains an optional "Connect to RomM" step between the ES-DE import and the art pack. It hosts the same credential form as the RomM tab, extracted so both can use it, and once connected offers the unified-library switch. See ADR-0021.

## Requirements

### Requirement: Step Placement

The wizard SHALL show a RomM step after the ES-DE import step and before the art-pack step on every platform, making seven steps on Android and six on desktop. The step indicator MUST count it. The step MUST be reached whether or not a ROM folder was selected and whether or not the ES-DE import ran. The art-pack step MUST remain the last step.

#### Scenario: After the ES-DE step

- **WHEN** the user finishes or skips the ES-DE import step
- **THEN** the RomM step is shown, and the indicator marks it as the step before the last

#### Scenario: No ROM folder

- **WHEN** the user skipped folder selection
- **THEN** the RomM step is still offered

### Requirement: Shared Connect Form

The credential form (server URL, the authentication mode switch, the fields of the selected mode, the QR scan action where the platform has it, and connect) SHALL be one widget hosted by both the RomM tab and the wizard step. The host MUST supply the behaviour that differs: whether the bumpers switch tabs, the action for B when no field is focused, and callbacks for a successful connection and for a request starting and settling. The RomM tab's behaviour MUST NOT change: its bumpers switch tabs and its existing tests pass against the extracted form. In the wizard the bumpers MUST do nothing.

#### Scenario: Same modes in both places

- **WHEN** the wizard step is shown on Android
- **THEN** password, Client API Token and pairing code are offered, with the QR scan action in pairing mode, as on the tab

#### Scenario: Server disables password login

- **WHEN** the server's heartbeat reports password login disabled while the wizard form is on the password mode
- **THEN** the mode switch reorders and moves to pairing, as it does on the tab

### Requirement: Skipping

The step MUST offer Skip at all times while disconnected, and Skip MUST advance to the art-pack step without sending a request or writing anything. While a connect attempt is in flight Skip MUST be inert, as the wizard's buttons are during the ES-DE import; it MUST work again once the attempt settles.

#### Scenario: Skip

- **WHEN** the user presses Skip on the RomM step
- **THEN** the art-pack step is shown and no RomM request was made

### Requirement: Connecting

A successful connect from the step SHALL go through `RommProvider`'s existing connect path, so the link pass, the catalog refresh and the save-sync registration start as they do from the tab. The wizard MUST NOT await them. A failed connect MUST show the same localized error the tab shows and leave the user on the form with their input kept.

#### Scenario: Pairing code

- **WHEN** the user enters a server URL and a valid pairing code and connects
- **THEN** the step shows the connected state and the link pass has started

#### Scenario: Wrong password

- **WHEN** the connect fails with an authentication error
- **THEN** the form stays, the error is shown under it in the user's language, and Skip is available

### Requirement: Connected State

Once connected the step SHALL show the server's address and its version line, and one switch, "Show RomM library in my systems", bound to `romm_show_library` and off unless already on. The primary action MUST be Next and advance to the art-pack step. The step MUST NOT offer disconnect. A wizard that opens on this step with a connection already present MUST show this state directly.

#### Scenario: Turn the library on

- **WHEN** the user turns the switch on and presses Next
- **THEN** `romm_show_library` is on and the art-pack step is shown

#### Scenario: Already connected

- **WHEN** the wizard reaches the step and RomM is already connected
- **THEN** the connected state is shown with Next, and no form

### Requirement: Gamepad Navigation

Every control on the step MUST be reachable by D-pad. The wizard's buttons are not cursor targets: as on every other step, B is Skip and A is the primary action. While the credential form is shown it owns the controller through its own gamepad layer, and the wizard's navigator MUST be off for exactly that long, so one press never both acts on the form and advances the wizard. On the form, A acts on the control under the cursor (connect included), B with a text field focused MUST leave the field, and B with no field focused MUST be Skip. A connect request in flight MUST hold both B and the on-screen Skip until it settles. Once connected the wizard's navigator is back: A is Next, and X toggles the library switch, which shows that button beside it. The QR scan route MUST return to the form with the cursor where it was.

#### Scenario: Skip without touch

- **WHEN** the form is shown, no field is focused, and the user presses B
- **THEN** the art-pack step is shown

#### Scenario: B in a field

- **WHEN** a text field is focused and the user presses B
- **THEN** the field loses focus and the step stays

#### Scenario: One press, one action

- **WHEN** the cursor is on Connect and the user presses A
- **THEN** the connect request is sent and the wizard does not advance

### Requirement: Localized User-Facing Text

Every new user-visible string (the step's title and description, the indicator label, the connected-state text) MUST be an `AppLocale` key with a value in all twelve language files. Strings the form already has MUST be reused, not duplicated.

#### Scenario: Keys present

- **WHEN** the analyzer runs
- **THEN** every new key has a value in every language file

### Requirement: Error Handling Standards

A failure inside the step MUST NOT strand the user in the wizard: any exception from the connect path MUST be caught, logged with the server host and the authentication mode (never the secret), and shown as the form's error. The step MUST remain skippable after any failure.

#### Scenario: Server unreachable

- **WHEN** the server does not answer
- **THEN** the form shows the unreachable message and Skip still advances

### Requirement: Database Operation Standards

The step MUST NOT add a column, a table or a preference. The only setting it writes is `romm_show_library`, through the existing config mutator.

#### Scenario: Schema unchanged

- **WHEN** the feature is merged
- **THEN** `_databaseVersion` is unchanged
