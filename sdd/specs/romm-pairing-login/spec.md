---
status: draft
date: 2026-09-05
implements: [ADR-0007]
---

# SPEC-0007: RomM Pairing Code And QR Login

## Graph Edges

- **Implements:** [ADR-0007](../../adrs/ADR-0007-romm-pairing-code-and-qr-login.md) — RomM login by pairing code and QR code

## Overview

Users can connect NeoStation to a RomM server with the pairing code that RomM's Client API Tokens screen generates, either by typing the 8-character code or, on devices with a camera, by scanning the QR code shown next to it. The app exchanges the code for a client token and connects through the existing API-key path, so everything downstream of the connection is unchanged. See ADR-0007.

Facts fixed by RomM: the code is 8 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, displayed as `XXXX-XXXX`, valid for the `expires_in` seconds returned to the web UI (60 today), single use, exchanged with `POST /api/client-tokens/exchange` `{"code": "…"}` returning `raw_token`, `name`, `scopes`, `expires_at`; the QR encodes `<origin>/pair?code=XXXX-XXXX`.

## Requirements

### Requirement: Pairing Code Exchange

`RommService` SHALL provide `exchangePairCode(serverUrl, code)` that normalises the code (remove dashes and whitespace, upper-case), MUST reject codes that are not exactly 8 characters of the pairing alphabet before any request, MUST POST to `/api/client-tokens/exchange` using the same scheme-fallback and timeout handling as the other calls, and MUST return the token as `RommPairedToken {rawToken, name, scopes, expiresAt}`. Failures MUST be `RommException`s carrying a sentinel the UI can distinguish: invalid-or-expired code (404, 410, or any 4xx other than 429), too many attempts (429), and the existing network, TLS, and timeout cases.

#### Scenario: Dashed code

- **WHEN** the user enters `ABCD-2345`
- **THEN** the request body carries `ABCD2345` and the returned token starts with `rmm_`

#### Scenario: Malformed code

- **WHEN** the user enters `ABC-1O`
- **THEN** no request is made and the error names the expected format

#### Scenario: Expired code

- **WHEN** the server answers 404 or 410
- **THEN** the error says the code is invalid or expired and suggests generating a new one

#### Scenario: Rate limited

- **WHEN** the server answers 429
- **THEN** the error says too many attempts and to wait a minute

### Requirement: Connect Through The API-Key Path

`RommProvider` SHALL provide `connectWithPairCode(serverUrl, code)` that calls the exchange and then the existing `connect(serverUrl, apiKey: rawToken)`. The token MUST be persisted through the existing API-key secret storage. The token's name and expiry MUST be stored alongside the connection so the connect screen can show them, and the connection state after a successful pairing MUST be indistinguishable from a connection made by pasting the same token.

#### Scenario: Paired session survives restart

- **WHEN** the user pairs, quits, and relaunches
- **THEN** the app reconnects with the stored token exactly as it does for a pasted API key

#### Scenario: Expiry shown

- **WHEN** the paired token has `expires_at` set
- **THEN** the connected view shows the expiry date

#### Scenario: Token expired later

- **WHEN** a paired token has expired and the app reconnects
- **THEN** the existing invalid-key error path is taken and the user can pair again

### Requirement: Pairing Mode On The Connect Screen

The connect screen SHALL offer a third authentication mode, "Pairing code", beside password and API key. In that mode the form MUST show the server URL field and a code field accepting `XXXX-XXXX` or `XXXXXXXX` (case-insensitive), MUST show a hint that the code expires about a minute after RomM generates it, and Connect MUST exchange immediately. The mode switch MUST remain operable by D-pad (Left/Right cycles the modes) and every field and action MUST be reachable by controller with B leaving a focused field.

#### Scenario: Typed pairing on a camera-less device

- **WHEN** the user selects Pairing code, enters the server URL and `ABCD-2345`, and presses Connect
- **THEN** the app exchanges the code, connects, and shows the existing connection-success notification

#### Scenario: Mode cycling

- **WHEN** the switch is focused and the user presses Right twice from password mode
- **THEN** the mode is Pairing code and the form shows the code field

### Requirement: QR Scan Where A Camera Exists

On Android and macOS the pairing mode SHALL offer a "Scan QR code" action that opens a full-screen scanner registered as its own gamepad navigation layer, closable with B. A scanned value MUST be parsed with `RommPairLink.parse`; on success the scanner MUST close, the server URL and code fields MUST be filled, and the exchange MUST start at once. Any other content MUST be refused with a localized message and the scanner MUST stay open. Camera permission MUST be requested on first open; a denial MUST return to the form with a localized notice and the typed path intact. On Windows and Linux the action MUST NOT appear.

#### Scenario: Scan on a phone

- **WHEN** the user scans RomM's pairing QR
- **THEN** the server URL becomes the QR's origin, the code is filled, and the app connects without further input

#### Scenario: Wrong QR

- **WHEN** the user scans a QR that is not a RomM pairing link
- **THEN** a message says it is not a RomM pairing code and scanning continues

#### Scenario: No camera

- **WHEN** the app runs on Windows, Linux, or the camera permission is denied
- **THEN** the typed code path works and the scan action is absent or the denial is reported

### Requirement: Pairing Link Parsing

The system SHALL provide a pure `RommPairLink.parse(String)` that accepts `<scheme>://<host>[:port]/pair?code=<code>` with an optional trailing slash on the path, MUST return the origin (scheme, host, port) as the server URL and the normalised code, and MUST return null for any other input, including a bare code, a different path, or a missing code parameter.

#### Scenario: Dashed link

- **WHEN** parsing `https://romm.example.com/pair?code=ABCD-2345`
- **THEN** the result is server `https://romm.example.com` and code `ABCD2345`

#### Scenario: Port and trailing slash

- **WHEN** parsing `http://192.168.1.10:8080/pair/?code=abcd2345`
- **THEN** the result is server `http://192.168.1.10:8080` and code `ABCD2345`

#### Scenario: Not a pairing link

- **WHEN** parsing `https://romm.example.com/library` or `ABCD2345`
- **THEN** the result is null

### Requirement: Localized User-Facing Text

Every new user-visible string (mode label, code field label and hint, scan action, scanner title and prompt, refusal, permission denial, expiry line, error messages) MUST be an `AppLocale` key with a value in all twelve language files.

#### Scenario: Keys present

- **WHEN** the new keys are added
- **THEN** every `lib/l10n/app_locale_*.dart` file defines them and the analyzer passes

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (for example, "pairing failed: exchange for code ABCD2345 rejected: 410 expired")
- Sentinel errors MUST be defined for domain-specific failure modes that callers need to distinguish programmatically
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Exchange succeeds, verification fails

- **WHEN** the exchange returns a token but `/api/users/me` then fails
- **THEN** the error reported is the verification error, the exchange is logged as succeeded, and no token is persisted

### Requirement: Database Operation Standards

All database operations MUST follow structured data access patterns:

- Transactions MUST be used for multi-step mutations that require atomicity
- Connection lifecycle MUST be explicitly managed — connections MUST be returned to the pool after use, with timeouts configured
- Query parameters MUST use parameterized queries — string interpolation in queries MUST NOT occur

#### Scenario: Token persisted

- **WHEN** a pairing succeeds
- **THEN** the token and its metadata are written through the repository with parameterized statements and the secret store
