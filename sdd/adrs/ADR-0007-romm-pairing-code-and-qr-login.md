---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-09-05
decision-makers: [Jon Stump]
related: [ADR-0001, ADR-0006]
---

# ADR-0007: RomM login by pairing code and QR code

## Context and Problem Statement

NeoStation connects to a RomM server with either a username and password (OAuth2 password grant against `/api/token`) or a RomM Client API Token pasted into the connect screen and sent as `Authorization: Bearer rmm_…`. Pasting a 68-character token on a gamepad-driven handheld is the worst part of the setup, and typing a password on one is not much better.

RomM's client-token screen (Settings → Client API Tokens → create or regenerate → "Pair device") offers a pairing flow made for exactly this: the server generates an 8-character code from the alphabet `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, shows it as `XXXX-XXXX` together with a QR code, and keeps it valid for 60 seconds (the pair response carries `expires_in`), single use, rate-limited to 5 exchange attempts per minute. The QR encodes a plain URL, `https://<romm host>/pair?code=XXXX-XXXX`, so a scan yields both the server address and the code. A device exchanges the code with one unauthenticated call, `POST /api/client-tokens/exchange` with `{"code": "…"}`, and receives the same token schema the create endpoint returns: `raw_token` (`rmm_` plus 64 hex), `name`, `scopes`, `expires_at`. That token is exactly the API key NeoStation already supports.

The user asked for login by these codes and by scanning the QR, noting that the Retroid Pocket Nova has no camera while a phone running NeoStation would. How should the pairing flow enter the app so the typed code works on every platform, the QR scan works where a camera exists, and the result lands in the connection and credential handling that already exist?

## Decision Drivers

* A code typed with a D-pad must be enough on camera-less handhelds and desktops; the QR path is an accelerator, not a requirement.
* The exchanged token must flow into the existing API-key mode (`RommService.configure(apiKey:)`, `_verifyApiKey`, `RommRepository` secret storage) so reconnect, disconnect, sync-provider adoption, and the link pass need no new branches.
* The code is short-lived (60 s) and single use; the UI must exchange it immediately and explain expiry and rate limiting in the user's words.
* A camera plugin is a real dependency: `mobile_scanner` 7.x supports Android, iOS, macOS, and web, not Windows or Linux, and bundles ML Kit on Android for roughly 3 to 10 MB. The app targets Windows, Linux, macOS, and Android.
* Strict layering, twelve-language strings, and controller reachability, including B to leave the scanner.
* RomM's `Pair.vue` also accepts a `callback` query parameter with a custom URL scheme, exchanging the code in the browser and redirecting `…?token=` to the app. That is a second way in, for phones whose system camera app scans the QR.

## Considered Options

* Pairing-code mode on the connect screen with an in-app QR scanner where a camera exists, exchanging the code into the existing API-key connection
* Deep-link callback only: register a `neostation://pair` scheme and let the phone's camera app plus RomM's `/pair` page do the exchange, no in-app scanner
* Typed pairing code only, no QR support

## Decision Outcome

Chosen option: "Pairing-code mode with an in-app QR scanner where a camera exists", because the typed code alone satisfies every platform the user owns today, the scanner turns a phone into a two-second login without depending on how the QR was reached, and both paths end in the API-key code that already works. Concretely:

1. **Exchange in the service.** `RommService.exchangePairCode(serverUrl, code)` normalises the code (strip dashes and spaces, upper-case, validate 8 characters of the pairing alphabet), POSTs to `/api/client-tokens/exchange` with the scheme fallback the other calls use, and returns a `RommPairedToken {rawToken, name, scopes, expiresAt}`. Errors map to sentinel-bearing `RommException`s: 404 or 410 → code invalid or expired, 429 → too many attempts, network and TLS as today.
2. **Connect through the API-key path.** `RommProvider.connectWithPairCode(serverUrl, code)` calls the exchange, then the existing `connect(serverUrl, apiKey: rawToken)`. Persistence is the existing API-key secret storage; the token's `expiresAt` and `name` are kept alongside so the connect screen can show "Token expires on …" and a 401 after expiry produces the existing invalid-key error rather than a mystery.
3. **A third auth mode on the connect screen.** The mode switch gains "Pairing code" beside password and API key: server URL plus a code field that accepts `XXXX-XXXX` or `XXXXXXXX`, with a hint that the code lasts about a minute, and Connect exchanging immediately. The switch stays D-pad operable (Left/Right cycles the three modes).
4. **QR scan where a camera exists.** A "Scan QR code" action appears only on Android and macOS, opening a full-screen scanner (`mobile_scanner`, bundled ML Kit) registered as its own gamepad layer with B to close. A scanned `…/pair?code=…` URL fills the server URL (origin) and the code, closes the scanner, and exchanges at once; any other QR content is refused with a message. Camera permission is requested on first open; denial returns to the form with the typed path still available. Windows and Linux never show the action.
5. **QR payload parsing is pure and tested.** `RommPairLink.parse(String)` extracts origin and code from the URL form, tolerates a trailing slash and the dashed or plain code, and rejects everything else.
6. **Deep-link callback deferred.** Registering a custom scheme and handling `neostation://pair?token=` is a separate decision; RomM's generated QR carries no `callback` today, so it would only serve hand-built links.

### Consequences

* Good, because a handheld user types eight unambiguous characters instead of a token or a password, and a phone user scans once.
* Good, because the connection, reconnect, disconnect, and every RomM feature behind it are untouched: the paired token is an API key.
* Good, because the pure parser and the exchange are unit-testable, and the scanner is isolated behind a platform gate.
* Bad, because `mobile_scanner` adds a native dependency and several megabytes to the Android build. Accepted for the phone use case; the unbundled ML Kit variant is a later option.
* Bad, because a 60-second code plus a slow scan or typing race the clock; the form says so and the server's error is relayed, and RomM's dialog can regenerate the code.
* Neutral, because tokens can carry expiry and reduced scopes; the app shows the expiry and otherwise behaves as with any API key.

### Confirmation

* Unit tests: code normalisation and validation; `RommPairLink.parse` for dashed, plain, trailing-slash, wrong-path, and non-URL inputs; `exchangePairCode` against a fake client for 200, 404, 410, 429, and network failure; `connectWithPairCode` ends in a connected API-key session and persists the token.
* Connect-screen tests for the three-mode switch and the platform gate on the scan action.
* Manual: Nova (typed code), Android phone (scan), desktop (no scan action).
* Governing comments on the exchange, the parser, the provider entry, the mode switch, and the scanner gate.

## Pros and Cons of the Options

### Pairing-code mode with an in-app QR scanner where a camera exists

* Good, because it covers every platform with one typed path and accelerates phones.
* Good, because it reuses the API-key connection end to end.
* Bad, because of the scanner dependency and its size.

### Deep-link callback only

Register `neostation://` and rely on the phone's camera app opening RomM's `/pair` page with a callback.

* Good, because no camera code in the app.
* Bad, because RomM's QR carries no callback parameter; the user would have to construct the link by hand.
* Bad, because it does nothing for camera-less devices or desktops, and Android intent filters plus per-platform scheme registration are their own work.

### Typed pairing code only

* Good, because smallest change and no dependency.
* Bad, because it ignores the QR the user asked for and the phone case they named.

## Architecture Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant W as RomM web UI
    participant C as Connect screen (pairing mode)
    participant S as QR scanner (Android/macOS)
    participant P as RommProvider.connectWithPairCode
    participant R as RommService
    participant API as RomM server

    U->>W: Client API Tokens → Pair device
    W-->>U: XXXX-XXXX + QR (https://host/pair?code=XXXX-XXXX)
    alt camera available
        U->>S: Scan QR
        S->>C: RommPairLink.parse → server URL + code
    else
        U->>C: type server URL + code
    end
    C->>P: connectWithPairCode(url, code)
    P->>R: exchangePairCode(url, code)
    R->>API: POST /api/client-tokens/exchange {code}
    API-->>R: raw_token, name, scopes, expires_at
    P->>P: connect(url, apiKey: raw_token) (existing)
    P->>R: _verifyApiKey → GET /api/users/me
    P-->>C: connected; token stored as API key (+ expiry shown)
```

## More Information

* RomM sources: `backend/endpoints/client_tokens.py` (`POST /client-tokens/{id}/pair`, `GET /client-tokens/pair/{code}/status`, `POST /client-tokens/exchange`), `backend/utils/client_tokens.py` (`PAIR_CODE_LENGTH = 8`, `PAIR_CODE_TTL_SECONDS = 60`, `PAIR_ALPHABET`, rate limit 5 per 60 s), `frontend/src/v2/components/Settings/CreateClientTokenDialog.vue` (`pairUrl = origin + '/pair?code=' + 'XXXX-XXXX'`), `frontend/src/views/Pair.vue` (optional custom-scheme `callback`). Docs: https://docs.romm.app/4.9.0/developers/client-api-tokens/
* Key code: `lib/services/romm_service.dart` (`configure(apiKey:)`, `_verifyApiKey`, `_withSchemeFallback`, `RommException`), `lib/providers/romm_provider.dart` (`connect`), `lib/repositories/romm_repository.dart` (API-key secret storage), `lib/screens/romm_screen/romm_connect_content.dart` (mode switch, `_connect`).
* Scanner: `mobile_scanner` 7.4.0, `MobileScanner(onDetect:)`, `barcodes.first.rawValue`; Android bundled ML Kit by default.
* Related to ADR-0001 and ADR-0006 as part of the same RomM integration; independent of their decisions.
* This fork does not open upstream pull requests.
