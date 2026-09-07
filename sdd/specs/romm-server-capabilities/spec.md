---
status: draft
date: 2026-09-06
implements: [ADR-0010]
extends: [SPEC-0007]
---

# SPEC-0010: RomM Server Capabilities

## Graph Edges

- **Implements:** [ADR-0010](../../adrs/ADR-0010-romm-heartbeat-capability-probe.md) — probe RomM capabilities with the heartbeat endpoint at connect time
- **Extends:** [SPEC-0007](../romm-pairing-login/spec.md) — RomM pairing code and QR login (the exchange gains a version gate and the connect screen a mode order)

## Overview

At connect time NeoStation fetches RomM's public `GET /api/heartbeat`, parses the server version and feature sections into a capability value object, and uses a single feature-threshold table to decide, before sending anything, whether a version-dependent endpoint exists on this server. A failed probe leaves capabilities unknown, which behaves exactly as today. See ADR-0010.

## Requirements

### Requirement: Capability Value Object

The system SHALL provide `RommServerVersion` (major, minor, patch, optional prerelease; ordered; parsed from strings with or without a `v` prefix and with or without a prerelease suffix; unparseable input yields null) and `RommServerCapabilities` (version, `metadataSources` as a map of flag name to bool, `passwordLoginDisabled`, `fsPlatforms`, `tasks`, `emulation`, and `fetchedAt`). Parsing MUST tolerate missing sections, unknown keys, and non-boolean flag values, and MUST NOT throw.

#### Scenario: Full heartbeat body

- **WHEN** a body with `SYSTEM.VERSION = "5.2.0"`, `METADATA_SOURCES.SS_API_ENABLED = true`, and `FRONTEND.DISABLE_USERPASS_LOGIN = false` is parsed
- **THEN** the version compares equal to 5.2.0, `metadataSources['SS_API_ENABLED']` is true, and `passwordLoginDisabled` is false

#### Scenario: Sparse or odd body

- **WHEN** a body has only `SYSTEM.VERSION = "v4.4.1-beta.2"` and an unknown top-level section
- **THEN** the version parses as 4.4.1 with prerelease `beta.2`, every other field is empty or null, and no exception is raised

### Requirement: Feature Threshold Table

The system SHALL define `RommFeature` with one entry per gated endpoint and the RomM version that introduced it: `playSessions` 4.8.0, `clientTokenExchange` 4.8.0, `romLookupByHash` 4.5.0. `RommServerCapabilities.supports(feature)` MUST return `supported` when the version is at or above the threshold, `unsupported` when below, and `unknown` when there is no version. A prerelease of the threshold version MUST count as below it. Each entry MUST carry a comment naming the RomM commit or release it was verified against. The table MUST live in one file.

#### Scenario: Old server

- **WHEN** the version is 4.7.0 and the feature is `playSessions`
- **THEN** `supports` returns `unsupported`

#### Scenario: Prerelease of the threshold

- **WHEN** the version is 4.8.0-beta.1 and the feature is `playSessions`
- **THEN** `supports` returns `unsupported`

#### Scenario: No probe result

- **WHEN** capabilities are null
- **THEN** every feature is `unknown`

### Requirement: Heartbeat Probe

`RommService.fetchHeartbeat()` SHALL GET `/api/heartbeat` on the configured base URL without an Authorization header, with a timeout of at most 5 seconds, using the service's existing HTTP client (including its TLS handling). It MUST store the parsed capabilities on the connection, MUST log exactly one line naming the version and whether the probe succeeded, and MUST NOT throw: any failure (timeout, socket error, non-2xx status, unparseable body) leaves capabilities null. `configure()` with a different base URL MUST clear stored capabilities. The service MUST expose `capabilities` and `supports(feature)`.

#### Scenario: Probe succeeds

- **WHEN** the server answers 200 with a valid body
- **THEN** `capabilities.version` is set and one info line is logged

#### Scenario: Probe fails

- **WHEN** the server answers 404, or the request times out
- **THEN** `capabilities` is null, `supports(anything)` is `unknown`, one warning line is logged, and the caller receives no exception

### Requirement: Probe Before The Token Grant

`authenticate()` SHALL call `fetchHeartbeat()` first when the connection has not been probed since the last `configure()`. When `supports(playSessions)` is `unsupported`, the password grant MUST request only the read scopes and MUST NOT retry with the playtime scopes; the playtime-scope-granted flag MUST be false. When `supported` or `unknown`, the grant and its 403 fallback MUST behave as SPEC-0013 REQ "Optional Scope Groups" defines. (Until SPEC-0013, that was the binary playtime grant with a single 403 retry; ADR-0013 `extends` ADR-0010 and replaced it with per-group negotiation. This clause originally read "exactly as before this spec", which is stale now that SPEC-0013 has superseded the fallback it referred to.) API-key mode MUST still probe (the version still gates endpoints, and since the amended SPEC-0013 REQ "Optional Scope Groups" the same call also settles the scope groups). A connection restored by `RommProvider.initialize()` never calls `authenticate()` — the restore is deliberately offline — so it MUST verify and probe lazily, at most once, before its first authenticated request rather than during the restore. (Added after issue #168. ADR-0010 already claimed a restored session re-probes "off the critical path"; it did not, so a resumed session ran with null capabilities and every scope group `unknown` for the life of the process. That made version-gated controls render on servers that cannot serve them — Surprise Me was visible against a 5.1.0 server and answered 422 — and left `granted` unreachable.)

#### Scenario: Old server, password grant

- **WHEN** the heartbeat reports 4.7.0 and the user logs in with a password
- **THEN** exactly one token POST is sent, with the read scopes only, and playtime sync is unavailable

#### Scenario: Heartbeat failed, password grant

- **WHEN** the probe failed and the user logs in with a password
- **THEN** the grant requests read plus playtime scopes and falls back to read scopes on 403, as before

### Requirement: Gated Call Sites

A method whose endpoint is in the threshold table MUST return early, without sending a request, when `supports(feature)` is `unsupported`. When `unknown`, it MUST behave as before (send, and degrade on 404 or a confirmed 403). `uploadPlaySessions` MUST report the early return the same way it reports an unavailable API today. The pairing exchange in `RommProvider.connectWithPairCode` MUST fail with a localized "server too old for pairing" error, and error kind `unsupported`, without sending the exchange request.

#### Scenario: Play sessions on an old server

- **WHEN** a session ends while connected to a 4.7.0 server
- **THEN** no `/api/play-sessions` request is sent and the session is not queued for retry

#### Scenario: Pairing on an old server

- **WHEN** the user enters a pairing code against a 4.7.0 server
- **THEN** the connect screen shows the localized "too old" message and no exchange request is sent

#### Scenario: Unknown capabilities

- **WHEN** the probe failed and a session ends
- **THEN** the upload is attempted and 404/403 handling is unchanged

### Requirement: Provider Exposure And Re-Probe

`RommProvider` SHALL expose `serverVersion` (nullable) and `passwordLoginDisabled` (false when unknown). `connect` and `connectWithPairCode` probe through `authenticate()`. `initialize()` (restored session) MUST NOT probe: the restore reads the saved connection from the database and is deliberately offline, so it marks the connection connected with the capabilities still unknown. The probe for a restored session happens lazily instead, before its first authenticated request, per REQ "Probe Before The Token Grant" — which means a session that never issues one keeps `serverVersion` null, and that is correct rather than a missed probe. An offline connection additionally re-probes on the backoff timer SPEC-0019 REQ "Reachability" defines. Listeners MUST be notified when either lands. `disconnect` MUST clear the exposed values. (Amended after issue #168. This clause previously required `initialize()` to schedule a probe "off the critical path"; no such scheduling was ever implemented, and asserting it here left the spec claiming a restored session self-heals when it did not — the gap that let version-gated controls render against a server that cannot serve them.)

#### Scenario: Restored session

- **WHEN** the app starts with a saved RomM connection
- **THEN** the connection is reported connected with `serverVersion` still null, and no request is sent by the restore itself

#### Scenario: Restored session, first authenticated request

- **WHEN** that restored connection sends its first authenticated request
- **THEN** the capability probe and, in API-key mode, the scope verification run once before it, and `serverVersion` becomes non-null

### Requirement: Connect Screen Surfaces

The connect content SHALL show the server version on a connected server as a localized line ("Server version {version}"), and MUST show nothing when the version is unknown. When `passwordLoginDisabled` is true, the connect screen's auth-mode order SHALL lead with pairing and API key and place the password mode last with a localized hint that the server has disabled it; the password mode MUST remain selectable. Every string MUST go through `AppLocale` with all twelve translations; every control MUST stay reachable by controller.

#### Scenario: Version line

- **WHEN** the RomM tab shows a connected 5.2.0 server
- **THEN** a "Server version 5.2.0" line is visible

#### Scenario: Password login disabled

- **WHEN** the heartbeat reports `DISABLE_USERPASS_LOGIN = true`
- **THEN** the pairing mode is focused first and the password mode carries the hint

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (the probe names the URL and the failure class in its warning line)
- The probe MUST NOT swallow failures silently: every failure is logged once with its cause
- Gated early returns MUST be logged at info level with the feature and the version that gated it, once per connection per feature
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Timeout

- **WHEN** the heartbeat times out
- **THEN** one warning names the base URL, `heartbeat`, and `timeout`, and connection continues
