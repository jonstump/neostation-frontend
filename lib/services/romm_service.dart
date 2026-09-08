import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;

import '../models/romm_asset.dart';
import '../models/romm_collection.dart';
import '../models/romm_firmware.dart';
import '../models/romm_pairing.dart';
import '../models/romm_platform.dart';
import '../models/romm_rom_filters.dart';
import '../models/romm_rom_page.dart';
import '../models/romm_play_session.dart';
import '../models/romm_rom.dart';
import '../models/romm_search_result.dart';
import '../models/romm_server_capabilities.dart';
import '../models/romm_screenshot.dart';
import 'logger_service.dart';

/// Failure modes a caller needs to tell apart programmatically (the connect
/// screen picks a localized message per kind). [other] covers everything that
/// only needs [RommException.message] and [RommException.statusCode].
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Code Exchange"
enum RommErrorKind {
  other,

  /// The pairing code is not 8 characters of the pairing alphabet, or the
  /// server rejected it for a reason other than expiry or rate limiting.
  pairCodeInvalid,

  /// The server has no such code: unknown, already used, or past its TTL.
  pairCodeExpired,

  /// Too many exchange attempts in the last minute.
  pairRateLimited,

  /// The server answered 403 on a call whose scope the credential does not
  /// hold — an API key created without `firmware.read`, typically. Distinct
  /// from a bad credential: the login itself is fine, this one endpoint is not
  /// allowed.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
  scopeDenied,

  /// The endpoint this call needs does not exist on this RomM: the heartbeat
  /// reported a version older than the release that introduced it, so nothing
  /// was sent.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Gated Call Sites"
  unsupported,

  /// The server refused the upload as larger than its asset limit (HTTP 413,
  /// `MAX_ASSET_UPLOAD_SIZE_BYTES`). Distinct because it is not worth
  /// retrying: the file's size will not change, so the caller records it as
  /// skipped rather than leaving it queued forever.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger"
  payloadTooLarge,

  /// A maintenance task could not be queued because it is already running:
  /// `POST /api/tasks/run/{name}` answered with a body that says so. Distinct
  /// because it is not a failure the user needs to fix — the work they asked
  /// for is already happening — so the screen says so rather than showing an
  /// error.
  ///
  /// Read from the body alone. A status code never implies it: the 400 this
  /// once trusted is undocumented on that route (issue #170), so every refusal
  /// RomM could not phrase as a 422 was reported to the user as a scan that
  /// was already underway when none had been queued.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Maintenance Tasks"
  taskBusy,

  /// `GET /api/search/roms` (or `/api/search/cover`) answered 500 because the
  /// server has no metadata provider configured. RomM raises rather than
  /// returning an empty list, so the status is the only signal, and it is not
  /// a fault the user can retry away — the fix is on the server.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Metadata Search And Apply"
  noMetadataSource,
}

/// One *optional* bundle of RomM OAuth scopes, negotiated at login.
///
/// RomM rejects the whole password grant with a 403 when any requested scope
/// is outside the account's allowance, and its answer never says *which* one.
/// Grouping the optional scopes by the feature that needs them lets the login
/// probe each group on its own and keep the ones the account actually holds,
/// so a single denial disables one feature instead of the connection.
///
/// The read scopes ([RommService.readScopes]) are never part of a group: a
/// login without them is not a usable connection.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
enum RommScopeGroup {
  /// Play sessions and per-user ROM props (`hidden`, `last_played`).
  playtime('roms.user.read roms.user.write', RommFeature.playSessions),

  /// Editing collections, including the favourites collection.
  collectionsWrite('collections.write', RommFeature.collectionRomsAddRemove),

  /// Library-wide ROM writes: the metadata fix in the match picker
  /// (SPEC-0018) and ROM upload (SPEC-0014).
  romsWrite('roms.write', null),

  /// Triggering server-side tasks such as a rescan — the maintenance menu
  /// (SPEC-0018 REQ "Maintenance Tasks").
  tasksRun('tasks.run', null),

  /// RomM's device registry (`POST /api/devices`) behind ADR-0018's
  /// device-negotiated save sync.
  ///
  /// The one group with no consumer yet: ADR-0018 is `proposed` and has no
  /// spec. It is still requested, and issue #134 asked whether it should be —
  /// the answer, on the evidence, is yes. `devices.read` and `devices.write`
  /// sit in RomM's READ and WRITE scope tiers, so any account above "viewer"
  /// already holds them and asking costs nothing: they are not what makes a
  /// combined grant 403. `tasks.run` is (RomM puts it in `FULL_SCOPES_MAP`,
  /// admin only) and `roms.write` is (`EDIT_SCOPES_MAP`, editor and up) — and
  /// both of those have consumers now, so the probe run they trigger is not
  /// avoidable by dropping this group. Dropping it would save one probe POST
  /// in a path that runs anyway, and cost every paired install a forced
  /// re-login the day Phase 1 lands.
  devices('devices.read devices.write', null);

  const RommScopeGroup(this.scopes, this.gate);

  /// The space-separated scope string requested for this group.
  final String scopes;

  /// The capability whose absence means the group's endpoints do not exist on
  /// this server, so the group is not worth requesting at all. Null for a
  /// group with no version gate in [RommFeature] yet — those are always
  /// requested and settle on the server's answer.
  final RommFeature? gate;
}

/// What the current connection knows about one [RommScopeGroup].
///
/// [unknown] is the API-key case and the pre-login case: nothing has proven
/// the group either way, so callers behave as they did before ADR-0013 — try,
/// and let a 403 settle it. Only [denied] gates.
// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
enum RommScopeState { granted, denied, unknown }

/// Raised when a RomM API call fails; [message] is safe to surface to the user.
class RommException implements Exception {
  final String message;
  final int? statusCode;

  /// Sentinel for callers that branch on the failure; [RommErrorKind.other]
  /// unless the call site says otherwise.
  final RommErrorKind kind;
  RommException(
    this.message, {
    this.statusCode,
    this.kind = RommErrorKind.other,
  });

  @override
  String toString() => kind == RommErrorKind.other
      ? 'RommException($statusCode): $message'
      : 'RommException($statusCode, ${kind.name}): $message';
}

/// Raised when a download is aborted because the caller's `shouldCancel`
/// callback returned true. A distinct type (rather than matching on the
/// message string) lets callers reliably tell a user-cancelled download apart
/// from a genuine failure, even if the message is later reworded/localized.
class RommCancelledException extends RommException {
  RommCancelledException([super.message = 'Download cancelled']);
}

/// Raised when the server rejected the *credential itself* — a wrong password,
/// a changed password, a revoked or mistyped API key — rather than refusing one
/// endpoint to an otherwise valid login.
///
/// A distinct type, not a message match, because the two are told apart by
/// status alone otherwise: RomM answers 403 both for "this login is not valid"
/// and for "this login may not touch that endpoint". The shared auth retry
/// re-authenticates mid-request on a 403, so a bad credential surfaces from
/// *inside* an ordinary endpoint call; without this marker the firmware calls
/// rewrite it as a missing `firmware.read` scope and the user is told the wrong
/// thing entirely. Extends [RommException] so every existing catch, status
/// check and error message keeps working unchanged.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Error Handling Standards"
class RommAuthException extends RommException {
  RommAuthException(super.message, {super.statusCode});
}

/// Raised when a request never got an answer out of the server — a timeout, a
/// dropped socket, a TLS handshake that failed.
///
/// A distinct type because the alternative is guessing. [RommException.statusCode]
/// tells "the server answered badly" apart from everything else, but it is
/// null for failures that are *not* transport faults either: an empty base
/// URL, which sends nothing at all, and [RommService._verifyApiKey]'s catch-all,
/// which would also swallow a `FormatException` from a malformed URL. Both used
/// to be logged as "could not reach the server", which is the misdiagnosis
/// issue #181 set out to end and issue #183 finding 3 caught it still doing.
///
/// The membership rule is *how the failure was raised*, not "no status came
/// back", and it covers every shape a dropped connection takes — including the
/// one `package:http` does not express as a socket error. `IOClient` maps a
/// `dart:io` `HttpException` raised while opening the request or reading its
/// headers to a bare `http.ClientException` ("Connection closed before full
/// header was received", `io_client.dart:229` in the pinned 1.6.0), which is a
/// genuinely unanswered request and exactly what a handheld produces when
/// Wi-Fi comes back mid-request. Leaving it out bounded issue #168's own
/// scenario at nine retries per connection (issue #190).
///
/// Extends [RommException] so every existing catch, message and status check
/// keeps working unchanged; only [RommService._ensureToken] reads the type.
// Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant",
// ADR-0020, SPEC-0019 REQ "Reachability"
class RommTransportException extends RommException {
  RommTransportException(super.message);
}

/// The one `http.ClientException` shape that is *not* a dropped connection: the
/// server answered — status and headers are in hand — and the body could not be
/// read to the end.
///
/// `package:http` raises the same bare `ClientException` for both, so the two
/// are told apart by where it was raised rather than by anything on the object:
/// [RommService._sendApiKeyVerification] separates the send from the body
/// drain, and only the drain produces this. Deliberately not a
/// [RommTransportException] and deliberately carries no
/// [RommException.statusCode]: retrying cannot fix a response the server keeps
/// truncating, so it belongs in the bounded fourth case
/// ([RommService._ensureToken]) rather than in the unbounded transport one,
/// where a proxy that truncates that endpoint on every call would cost one
/// extra request per authenticated call for the life of the process — issue
/// #173's regression, reintroduced by the back door.
// Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant",
// ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
class _RommUnreadableResponse implements Exception {
  _RommUnreadableResponse(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() =>
      'the server answered $statusCode but the response could not be read: '
      '$message';
}

/// HTTP client for a remote RomM server (library browse + ROM download).
///
/// Holds the server base URL and credentials for one connection. Two
/// authentication modes are supported, chosen by what [configure] is given:
///
/// * **OAuth2 password grant** (`POST /api/token`) — username + password. JWTs
///   are cached and transparently refreshed on expiry / 401.
/// * **Client API Token** — a `rmm_…` key the user creates in RomM. It is sent
///   as the bearer token directly, never expires, and has no refresh flow, so
///   the whole token lifecycle collapses to "use the key".
///
/// Modeled on the IOClient + bad-certificate setup used by [ScreenScraperService]
/// so self-signed homelab certificates work.
class RommService {
  static final _log = LoggerService.instance;

  /// Scopes requested in the password grant. RomM grants the intersection of
  /// these and the user's allowed scopes; covers library browse + download plus
  /// save/state sync (`assets.write`).
  ///
  /// These are *not* optional: a token without them is not a usable
  /// connection, so a 403 on a grant that asks only for these is a credential
  /// problem, never a scope problem. Everything beyond them is a
  /// [RommScopeGroup] negotiated per login.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  static const String readScopes =
      'me.read roms.read platforms.read assets.read assets.write collections.read firmware.read';

  /// Maximum sessions RomM accepts in one `/api/play-sessions` POST.
  static const int maxPlaySessionBatch = 100;

  /// Cap on the capability probe. It is one small body on the connect path, so
  /// a slow or unreachable server must not hold up the login behind it.
  ///
  /// This is the budget for the *whole* probe, retries included — not per
  /// attempt. See [fetchHeartbeat] for why that distinction matters.
  // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe"
  static const Duration _heartbeatTimeout = Duration(seconds: 5);

  /// Cap on an ordinary request, the HTTPS→HTTP scheme fallback included.
  ///
  /// Like [_heartbeatTimeout] this is the budget for the whole call rather
  /// than for one attempt: the login and pairing paths retry once over plain
  /// HTTP, and a per-attempt cap let a TLS-misconfigured server keep a user
  /// waiting for close to two minutes with no feedback.
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// Shared client that tolerates self-signed certificates (homelab servers).
  static final http.Client _sharedHttpClient = () {
    final inner = HttpClient()
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);
    return IOClient(inner);
  }();

  /// Test seam: when set, every request goes through this client instead of
  /// [_sharedHttpClient]. Process-wide, like the client it replaces.
  static http.Client? _httpClientOverride;

  /// Routes all RomM HTTP through [client] (a `MockClient`, typically); pass
  /// null to restore the shared client.
  @visibleForTesting
  static void debugUseHttpClient(http.Client? client) {
    _httpClientOverride = client;
  }

  static http.Client get _httpClient =>
      _httpClientOverride ?? _sharedHttpClient;

  String _baseUrl = '';

  /// Whether the user pinned the scheme (`http://`/`https://`) themselves. When
  /// false we may transparently downgrade an https attempt to http on a TLS
  /// handshake failure (common for plain-HTTP homelab servers).
  bool _schemeExplicit = false;
  String _username = '';
  String _password = '';
  String _apiKey = '';
  String? _accessToken;
  String? _refreshToken;
  int? _tokenExpiresMs;

  /// What this connection knows about each optional scope group.
  ///
  /// Starts optimistic (`unknown` everywhere, which never gates): a token
  /// restored from disk may predate a group, and the shared 403-retry
  /// re-authenticates — picking the group up — before giving up.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  final Map<RommScopeGroup, RommScopeState> _scopeStates = {
    for (final group in RommScopeGroup.values) group: RommScopeState.unknown,
  };

  /// Scope groups already reported as gating a call on this connection, so the
  /// "denied, not sending" line is logged once per group rather than per call.
  // Governing: ADR-0013, SPEC-0013 REQ "Error Handling Standards"
  final Set<RommScopeGroup> _scopeGatesLogged = <RommScopeGroup>{};

  /// The id of this account's `is_favorite` collection once
  /// [ensureFavouritesCollection] has found or created it. RomM allows exactly
  /// one per user, so it is looked up once per connection.
  // Governing: ADR-0013, SPEC-0013 REQ "Favourites Collection"
  int? _favouritesCollectionId;

  /// Cleared for the rest of this connection once the server proves it has no
  /// play-session API (404) or won't grant access to it (403 after a re-auth),
  /// so a RomM older than the feature isn't probed on every sync.
  bool _playSessionsSupported = true;

  /// What the last heartbeat said this server can do, or null when the probe
  /// has not run or did not land. Null means every feature reads as
  /// [RommFeatureSupport.unknown], which never gates.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Heartbeat Probe"
  RommServerCapabilities? _capabilities;

  /// Whether [fetchHeartbeat] has run since the last base-URL change. Set even
  /// when the probe fails, so a server that blocks `/api/heartbeat` is asked
  /// once per connection rather than before every authenticated call.
  bool _probed = false;

  /// Whether this connection has already verified its API key — and, with it,
  /// learned the scopes that key holds — since the last [configure].
  ///
  /// Set even when the attempt fails, so a key the server keeps rejecting is
  /// asked about once per connection rather than before every call.
  // Governing: ADR-0013 (push play state to RomM),
  // SPEC-0013 REQ "Optional Scope Groups", ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  bool _apiKeyVerified = false;

  /// How many API-key verifications this connection has spent *in a row* on a
  /// failure that was not a rejection and not a transport fault: a server that
  /// answered badly (a 5xx, a 429, any non-2xx that is not 401/403), or a
  /// failure with no status to classify at all.
  ///
  /// Consecutive, not cumulative. A rejection latches on the first answer and a
  /// transport failure is not the server's fault at all, so neither ever
  /// increments this. [_noteApiKeyAccepted] clears it when the server answers
  /// an authenticated call normally, and a verification that succeeds clears it
  /// too; [_apiKeyVerifyFailuresTotal] is the half that nothing clears.
  // Governing: ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  int _apiKeyVerifyFailures = 0;

  /// Every failure [_apiKeyVerifyFailures] has counted since the last
  /// [configure], healed episodes included. Reset only where [_apiKeyVerified]
  /// is reset for a *new* connection, never by a healthy response.
  // Governing: ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  int _apiKeyVerifyFailuresTotal = 0;

  /// The consecutive bound on [_apiKeyVerifyFailures]: three attempts against a
  /// server that keeps answering badly, then the one-shot is put away until the
  /// server proves it is answering again.
  ///
  /// Three, not one and not unbounded. Re-arming at all is what lets a RomM
  /// container that is mid-restart heal the connection by itself — dropping
  /// that would strand the session with unknown scopes until the user
  /// reconnects, which is issue #168's symptom with a 502 as the trigger.
  /// Re-arming *forever* is what issue #173 measured: one extra
  /// `GET /api/users/me` on every authenticated call, for the life of a
  /// process pointed at a permanently broken server.
  ///
  /// Three *calls*, note — not three seconds. The budget this bounds is spent
  /// per attempt, and attempts are made by calls: opening the RomM tab fires
  /// `getPlatforms`, `getCollections` and a `getRoms` page, so a restart of a
  /// few seconds can burn the whole consecutive budget inside one screen open.
  /// That is why the budget is consecutive rather than per-connection, and why
  /// [_noteApiKeyAccepted] exists: without a way back, three unlucky calls
  /// stranded the connection until the app restarted (issue #183 finding 2).
  static const int _maxApiKeyVerifyFailures = 3;

  /// The absolute bound on [_apiKeyVerifyFailuresTotal], which nothing clears
  /// short of a [configure]. This is the ceiling issue #173's measurement asks
  /// for, and the consecutive bound above cannot supply it on its own.
  ///
  /// The healthy signal that clears the consecutive count is a 2xx to *some*
  /// authenticated call, which is the best evidence available but not proof
  /// that `/api/users/me` in particular has recovered: a server answering
  /// `/api/roms` with 200 and `/api/users/me` with 500 alternates the reset and
  /// the failure forever, and the consecutive count then never reaches three.
  /// Nine caps that at nine extra requests for the life of the connection —
  /// three full consecutive budgets, so three separate restart episodes can
  /// each be healed — instead of one per call.
  ///
  /// Nine is the worst case in *requests*, not just in failures: a
  /// verification that succeeds can only ever be the last one, because it
  /// zeroes the consecutive count and [_noteApiKeyAccepted] then early-returns
  /// on that zero, so nothing re-arms the one-shot again. The realizable
  /// maximum is therefore eight failures plus a success, or nine failures and
  /// no success — never ten. Measured on the suite in
  /// `test/romm_api_key_scope_learning_test.dart`.
  static const int _maxApiKeyVerifyFailuresTotal = 9;

  /// Features already reported as gated on this connection, so the "not on
  /// this server" line is logged once per feature rather than once per call.
  final Set<RommFeature> _gatesLogged = <RommFeature>{};

  /// Called when a request could not reach the server at all — a socket error
  /// or a timeout, never a status the server answered with.
  ///
  /// The provider installs these to keep its reachability state honest without
  /// this service knowing what reachability is: every authenticated call and
  /// the heartbeat report through them, so "offline" is a fact about the last
  /// request rather than a poll of its own.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Reachability"
  void Function(Object error)? onTransportFailure;

  /// Called when a request reached the server, whatever it answered.
  // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Reachability"
  void Function()? onTransportSuccess;

  /// Whether playtime sync can be attempted against this server.
  ///
  /// Expressed through [hasScope]: only a *denied* playtime group stops it,
  /// so `unknown` (API-key mode, a restored token) still tries, exactly as it
  /// did before the groups existed.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  bool get playtimeSyncAvailable =>
      hasScope(RommScopeGroup.playtime) != RommScopeState.denied &&
      _playSessionsSupported;

  /// What this connection knows about [group]. [RommScopeState.unknown] until
  /// a login negotiates it or an endpoint answers 403.
  // Governing: ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  RommScopeState hasScope(RommScopeGroup group) =>
      _scopeStates[group] ?? RommScopeState.unknown;

  /// The parsed heartbeat for this connection, or null when unknown.
  RommServerCapabilities? get capabilities => _capabilities;

  /// Whether this server answers [feature]'s endpoint. [RommFeatureSupport
  /// .unknown] when the probe never landed — callers then behave exactly as
  /// they did before ADR-0010.
  // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe"
  RommFeatureSupport supports(RommFeature feature) =>
      _capabilities?.supports(feature) ?? RommFeatureSupport.unknown;

  /// Whether the server has at least one metadata provider configured, which
  /// is what `GET /api/search/roms` needs to answer at all (it raises a 500
  /// otherwise). Read from the heartbeat's `METADATA_SOURCES` flags.
  ///
  /// Follows ADR-0010's rule that *unknown never gates*: a heartbeat that
  /// never landed, or one whose `METADATA_SOURCES` section carries no
  /// `*_API_ENABLED` flag at all, reads as true so the user is offered the
  /// action and the server's own answer decides. Only a heartbeat that
  /// positively says every provider is off hides it.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Fix Match In The Picker"
  bool get hasMetadataSource {
    final flags = _capabilities?.metadataSources ?? const <String, bool>{};
    final anySource = flags['ANY_SOURCE_ENABLED'];
    if (anySource != null) return anySource;
    final apiFlags = [
      for (final entry in flags.entries)
        if (entry.key.endsWith('_API_ENABLED')) entry.value,
    ];
    if (apiFlags.isEmpty) return true;
    return apiFlags.any((enabled) => enabled);
  }

  String get baseUrl => _baseUrl;

  /// The account this connection belongs to. With the password grant it is
  /// whatever the user typed; with an API key it is filled in from
  /// `/api/users/me` at [authenticate] time, since the key alone doesn't name
  /// its owner.
  String get username => _username;

  /// Whether this connection authenticates with a Client API Token. Callers
  /// that persist the connection use it to decide which secret to store.
  bool get usesApiKey => _apiKey.isNotEmpty;

  /// The API key in use, or an empty string on a password-grant connection.
  String get apiKey => _apiKey;

  /// The cached OAuth2 access token — always null in API-key mode, where there
  /// is nothing to cache and the key itself is the bearer credential.
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  int? get tokenExpiresMs => _tokenExpiresMs;

  /// Configures the connection. [serverUrl] may include or omit a scheme and
  /// trailing slash; it is normalized to `scheme://host[:port]` with no
  /// trailing slash.
  ///
  /// Pass either [username]/[password] or a non-empty [apiKey]; a key wins if
  /// both are somehow given, and puts the service in API-key mode where the
  /// [accessToken]/[refreshToken]/[tokenExpiresMs] restore arguments are
  /// meaningless and ignored.
  void configure({
    required String serverUrl,
    String username = '',
    String password = '',
    String apiKey = '',
    String? accessToken,
    String? refreshToken,
    int? tokenExpiresMs,
  }) {
    // Capabilities describe the server, not the credentials: a different URL
    // is a different server, so [_setServerUrl] drops everything the last one
    // taught this connection. Editing the credentials for the same URL keeps
    // what the last probe learned.
    // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe"
    _setServerUrl(serverUrl);
    // Gate logging is per *connection*, not per server: configuring is how a
    // connection starts, so a reconnect to the same URL says again which
    // features its version rules out. Clearing this only on a URL change left
    // a support log from a reconnect with no gate lines at all.
    // Governing: ADR-0010, SPEC-0010 REQ "Error Handling Standards"
    _gatesLogged.clear();
    _apiKey = apiKey.trim();
    _username = username;
    _password = _apiKey.isEmpty ? password : '';
    _accessToken = _apiKey.isEmpty ? accessToken : null;
    _refreshToken = _apiKey.isEmpty ? refreshToken : null;
    _tokenExpiresMs = _apiKey.isEmpty ? tokenExpiresMs : null;
    // Playtime support is a property of the server we're pointed at, so a
    // reconfigure (different server, or the same one after an edit) re-probes
    // instead of inheriting the previous server's verdict. Scope grants belong
    // to the *credential*, which a reconfigure may also have changed, so they
    // go back to "unknown" for the same reason.
    // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
    for (final group in RommScopeGroup.values) {
      _scopeStates[group] = RommScopeState.unknown;
    }
    _scopeGatesLogged.clear();
    _apiKeyVerified = false;
    _apiKeyVerifyFailures = 0;
    _apiKeyVerifyFailuresTotal = 0;
    _favouritesCollectionId = null;
    _playSessionsSupported = true;
    _applyCapabilityGates();
  }

  /// Points the service at [serverUrl] without touching credentials or cached
  /// tokens — the URL half of [configure], shared with [fetchHeartbeat] and
  /// [exchangePairCode], neither of which has credentials yet.
  ///
  /// A different URL is a different server, so everything the previous one
  /// taught this connection is dropped here rather than at each call site.
  /// Returns whether the URL actually moved.
  bool _setServerUrl(String serverUrl) {
    final previousUrl = _baseUrl;
    final raw = serverUrl.trim();
    _schemeExplicit = raw.startsWith('http://') || raw.startsWith('https://');
    _baseUrl = _normalizeBaseUrl(raw);
    if (_baseUrl == previousUrl) return false;
    _forgetServerState();
    return true;
  }

  /// Drops every per-server fact this connection had learned, so nothing from
  /// the old server survives a move to a new one.
  ///
  /// Capabilities and the probe flag are the version half; `_playSessionsSupported`
  /// and the scope states are the "what did the server actually answer" half.
  /// [configure] used to clear only the first group here, which was harmless
  /// because pairing always reconfigured straight afterwards — but a caller
  /// that probes a new server without a following [configure] would have
  /// inherited the previous server's play-session verdict.
  // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe",
  // ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  void _forgetServerState() {
    _capabilities = null;
    _probed = false;
    _gatesLogged.clear();
    _playSessionsSupported = true;
    _favouritesCollectionId = null;
    for (final group in RommScopeGroup.values) {
      _scopeStates[group] = RommScopeState.unknown;
    }
    _scopeGatesLogged.clear();
    _apiKeyVerified = false;
    _apiKeyVerifyFailures = 0;
    _apiKeyVerifyFailuresTotal = 0;
  }

  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _uri(String pathAndQuery) => Uri.parse('$_baseUrl$pathAndQuery');

  bool get _tokenLikelyValid {
    // An API key never expires and has no refresh flow, so it is always the
    // credential to send: there is nothing for _ensureToken to do.
    if (usesApiKey) return true;
    if (_accessToken == null || _accessToken!.isEmpty) return false;
    final exp = _tokenExpiresMs;
    if (exp == null) return true; // assume valid until a 401 proves otherwise
    // Refresh 30s early to avoid edge-of-expiry races.
    return DateTime.now().millisecondsSinceEpoch < exp - 30000;
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  /// Runs [send] and, if an HTTPS TLS handshake fails while the user did not
  /// pin the scheme, downgrades the base URL to HTTP and retries once
  /// (plain-HTTP homelab servers are common). [send] must build its request
  /// fresh so the retry picks up the rewritten [_baseUrl].
  ///
  /// [timeout] is the budget for the *whole* call, retries included — never
  /// one budget per attempt. A per-attempt cap let a server that fails TLS
  /// slowly and then hangs on plain HTTP hold a caller for close to twice the
  /// stated ceiling, which is what #141 fixed for the heartbeat and #146 for
  /// the login and pairing paths. Pass null only for a caller that bounds
  /// itself some other way.
  Future<http.Response> _withSchemeFallback(
    Future<http.Response> Function() send, {
    Duration? timeout,
  }) {
    if (timeout == null) return _sendWithSchemeFallback(send, () => false);
    // The fallback has to know the budget is gone, not merely that someone
    // stopped waiting: once the timeout fires, the caller has already been
    // handed a TimeoutException, so a TLS failure landing afterwards must not
    // rewrite [_baseUrl] to http:// and fire a request nobody is waiting for.
    // That second request outlived the call it belonged to and quietly moved
    // the connection's scheme behind the caller's back.
    var expired = false;
    return _sendWithSchemeFallback(send, () => expired).timeout(
      timeout,
      onTimeout: () {
        expired = true;
        throw TimeoutException('RomM request timed out', timeout);
      },
    );
  }

  /// The retry half of [_withSchemeFallback]. [budgetExpired] reports whether
  /// the caller's timeout has already fired.
  Future<http.Response> _sendWithSchemeFallback(
    Future<http.Response> Function() send,
    bool Function() budgetExpired,
  ) async {
    final attemptUrl = _baseUrl;
    try {
      return await send();
    } on HandshakeException {
      // Nothing is waiting for this any more, or the service has since been
      // pointed at a different server: either way the downgrade would apply to
      // a connection this attempt no longer describes.
      if (budgetExpired() || _baseUrl != attemptUrl) rethrow;
      if (!_schemeExplicit && _baseUrl.startsWith('https://')) {
        _baseUrl = _baseUrl.replaceFirst('https://', 'http://');
        _log.w('RomM HTTPS handshake failed; retrying over HTTP at $_baseUrl');
        return await send();
      }
      rethrow;
    }
  }

  /// POSTs to `/api/token`, with the [_withSchemeFallback] HTTPS→HTTP retry.
  Future<http.Response> _postTokenRequest(Map<String, String> body) {
    const headers = {'Content-Type': 'application/x-www-form-urlencoded'};
    return _withSchemeFallback(
      () => _httpClient.post(_uri('/api/token'), headers: headers, body: body),
      timeout: _requestTimeout,
    );
  }

  // ── Capabilities (heartbeat probe) ────────────────────────────────────────

  /// Fetches RomM's public `GET /api/heartbeat` and stores what it reports.
  ///
  /// Unauthenticated (the endpoint is public and the probe runs *before* the
  /// token grant, so it can shape the scopes we ask for), capped at
  /// [_heartbeatTimeout], and routed through the same client and TLS policy as
  /// every other call — including the HTTPS→HTTP fallback for homelab servers.
  ///
  /// The cap covers the fallback too: both attempts share one budget, so a
  /// server that fails TLS and then hangs on plain HTTP cannot stall the
  /// connect path for longer than [_heartbeatTimeout] in total.
  ///
  /// Never throws. Any failure — timeout, socket error, TLS, a non-2xx status,
  /// a body that is not a JSON object — leaves [capabilities] null, which reads
  /// as [RommFeatureSupport.unknown] and gates nothing. Exactly one line is
  /// logged either way.
  ///
  /// Pass [serverUrl] to point the service at a server first, the way
  /// [exchangePairCode] does, for the pairing flow that probes before it has
  /// any credentials to [configure] with.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Heartbeat Probe", REQ "Error Handling Standards"
  Future<void> fetchHeartbeat({String? serverUrl}) async {
    // A different URL is a different server: [_setServerUrl] forgets the old
    // one's capabilities *and* the play-session/scope verdicts its answers
    // settled, so a caller that probes without a following [configure] does
    // not inherit them.
    // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe",
    // ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
    if (serverUrl != null) _setServerUrl(serverUrl);
    _probed = true;
    if (_baseUrl.isEmpty) {
      _log.w('RomM heartbeat skipped: url= endpoint=heartbeat reason=no_url');
      _capabilities = null;
      return;
    }

    final url = _baseUrl;
    http.Response resp;
    try {
      // One budget for the whole probe, not one per attempt. The HTTPS->HTTP
      // scheme fallback re-sends the request, so a per-attempt cap let a
      // server that fails TLS slowly and then hangs on plain HTTP hold the
      // connect path for close to twice [_heartbeatTimeout]. The cap therefore
      // belongs to [_withSchemeFallback], covering both attempts together —
      // and, since it owns the cap, it also knows not to downgrade the scheme
      // on a TLS failure that lands after the budget is already gone.
      // Governing: ADR-0010, SPEC-0010 REQ "Heartbeat Probe" (at most 5 s)
      resp = await _withSchemeFallback(
        () => _httpClient.get(_uri('/api/heartbeat')),
        timeout: _heartbeatTimeout,
      );
    } on TimeoutException catch (e) {
      _capabilities = null;
      onTransportFailure?.call(e);
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=timeout',
      );
      return;
    } on HandshakeException catch (e) {
      _capabilities = null;
      onTransportFailure?.call(e);
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=tls_handshake',
      );
      return;
    } on SocketException catch (e) {
      _capabilities = null;
      onTransportFailure?.call(e);
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=socket cause=${e.message}',
      );
      return;
    } catch (e) {
      _capabilities = null;
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=error cause=$e',
      );
      return;
    }

    // Whatever it answered, it answered: the server is reachable.
    // Governing: ADR-0020 (show RomM library inside the local library), SPEC-0019 REQ "Reachability"
    onTransportSuccess?.call();

    if (resp.statusCode != 200) {
      _capabilities = null;
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=status status=${resp.statusCode}',
      );
      return;
    }

    final RommServerCapabilities parsed;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('heartbeat body is not a JSON object');
      }
      parsed = RommServerCapabilities.fromJson(decoded);
    } catch (e) {
      _capabilities = null;
      _log.w(
        'RomM heartbeat failed: url=$url endpoint=heartbeat '
        'reason=unparseable_body cause=$e',
      );
      return;
    }

    _capabilities = parsed;
    _log.i(
      'RomM heartbeat ok: url=$url version=${parsed.version} '
      'password_login_disabled=${parsed.passwordLoginDisabled}',
    );
    _applyCapabilityGates();
  }

  /// Folds a known-unsupported feature into the per-connection state its call
  /// sites already consult, so "this server predates play sessions" and "this
  /// account was denied the scope" settle into one flag with one meaning.
  // Governing: ADR-0010, SPEC-0010 REQ "Gated Call Sites"
  void _applyCapabilityGates() {
    if (supports(RommFeature.playSessions) == RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.playSessions);
      _playSessionsSupported = false;
    }
  }

  /// One info line per gated feature per connection: which feature, and the
  /// version that gated it.
  // Governing: ADR-0010, SPEC-0010 REQ "Error Handling Standards"
  void _logGateOnce(RommFeature feature) {
    if (!_gatesLogged.add(feature)) return;
    _log.i(
      'RomM feature gated: feature=${feature.name} '
      'version=${_capabilities?.version} '
      'min_version=${feature.minVersion}',
    );
  }

  /// Establishes (or confirms) a usable credential, dispatching on the mode the
  /// service was configured in. Throws [RommException] with a user-facing
  /// message on failure.
  ///
  /// The heartbeat probe runs first when this connection has not been probed
  /// since the last [configure]: it is unauthenticated, so it is the one place
  /// that can shape the scopes the password grant asks for, and putting it here
  /// means every login mode (password, API key, paired token) gets it without
  /// remembering to ask.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Probe Before The Token Grant"
  Future<void> authenticate() async {
    if (_baseUrl.isEmpty) {
      throw RommException('Server URL is empty');
    }
    // API-key mode probes too: the key's scopes are fixed, but the server
    // version still gates which endpoints exist.
    if (!_probed) await fetchHeartbeat();
    if (usesApiKey) {
      _apiKeyVerified = true;
      return _verifyApiKey();
    }
    return _authenticateWithPassword();
  }

  /// Confirms an API key by fetching its owner, which doubles as the source of
  /// the username shown in the UI (the key itself doesn't name its account).
  ///
  /// Nothing is cached: the key *is* the credential, so this is a validity
  /// check rather than a token exchange, and only ever runs on connect.
  Future<void> _verifyApiKey() async {
    http.Response resp;
    try {
      // One budget across the scheme fallback, not one per attempt.
      resp = await _withSchemeFallback(
        _sendApiKeyVerification,
        timeout: _requestTimeout,
      );
    } on TimeoutException {
      // These four are the whole of "the server did not answer", and they are
      // marked as such so [_ensureToken] can tell them from a failure that has
      // no status for a different reason. The messages are unchanged and the
      // type is a [RommException] subclass, so nothing else sees a difference.
      // Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant"
      throw RommTransportException('Connection timed out');
    } on HandshakeException {
      throw RommTransportException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
      );
    } on SocketException catch (e) {
      // Ahead of the `ClientException` arm on purpose: `IOClient` wraps a
      // socket error in a `_ClientSocketException`, which *is* a
      // `ClientException` and only implements `SocketException` for the sake
      // of callers like this one. Reordering these would silently move every
      // ordinary socket failure onto the message below.
      throw RommTransportException('Cannot reach server: ${e.message}');
    } on http.ClientException catch (e) {
      // The connection died before any answer arrived: `IOClient` has already
      // reduced the `dart:io` `HttpException` behind it to this
      // ("Connection closed before full header was received"), and
      // [_sendApiKeyVerification] has already peeled off the one shape that
      // means the server *did* answer. See [RommTransportException] for why
      // this must retry rather than spend budget (issue #190).
      throw RommTransportException('Cannot reach server: ${e.message}');
    } catch (e) {
      // Deliberately *not* a transport exception: this arm catches a
      // `FormatException` from a malformed URL and a [_RommUnreadableResponse]
      // from a body the server truncated, neither of which is the network
      // being down, and neither of which a retry can fix.
      throw RommException('Connection failed: $e');
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw RommAuthException('Invalid API key', statusCode: resp.statusCode);
    }
    if (resp.statusCode != 200) {
      throw RommException(
        'Authentication failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final name = decoded['username']?.toString();
        if (name != null && name.isNotEmpty) _username = name;
        _learnScopesFromUser(decoded);
      }
    } catch (_) {
      // The key works; a surprising body shape only costs us the display name
      // and leaves the scope groups where they were: unknown, not denied.
    }
  }

  /// Sends the verification request, keeping "the server never answered" apart
  /// from "the server answered and the body could not be read".
  ///
  /// `http.Client.get` is `Response.fromStream(await send(request))` with the
  /// two halves collapsed into one future, and `package:http` raises the same
  /// bare `ClientException` from either — a closed connection from `send`
  /// (`io_client.dart:229`) and a truncated body from the response stream
  /// (`io_client.dart:188`). The exception object carries nothing that tells
  /// them apart, so this splits the call instead: whatever `send` throws never
  /// got an answer, and whatever the drain throws did. Only this endpoint
  /// needs the distinction, because only this endpoint classifies its failures
  /// into a retry policy; every other call in this file keeps using `get`.
  ///
  /// The request is built here rather than by the caller so the HTTPS→HTTP
  /// retry in [_withSchemeFallback] picks up the rewritten [_baseUrl], and so a
  /// `FormatException` from a malformed URL still lands in the caller's
  /// catch-all.
  // Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant",
  // ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  Future<http.Response> _sendApiKeyVerification() async {
    final request = http.Request('GET', _uri('/api/users/me'))
      ..headers.addAll(_authHeaders);
    final streamed = await _httpClient.send(request);
    try {
      return await http.Response.fromStream(streamed);
    } on http.ClientException catch (e) {
      throw _RommUnreadableResponse(streamed.statusCode, e.message);
    }
  }

  /// Settles the optional scope groups from the `oauth_scopes` RomM reports for
  /// the current credential, for the login modes that have no token grant to
  /// negotiate with.
  ///
  /// A password login learns its scopes by asking for them and reading the
  /// server's 403s ([_negotiateScopeGroups]). An API key — and therefore a
  /// paired client token, which [RommProvider] hands to [configure] as one —
  /// has fixed scopes and never sends a grant, so every group used to stay
  /// [RommScopeState.unknown] for the whole connection. That is the state
  /// [RommProvider.canRunServerTasks] refuses to act on, which made the server
  /// maintenance menu unreachable on the pairing/QR path — the primary way a
  /// handheld connects (issue #168).
  ///
  /// `GET /api/users/me` already answers with the scope list, so this costs no
  /// extra request: [_verifyApiKey] simply stops discarding the rest of the
  /// body it has.
  ///
  /// Deliberately conservative about what counts as an answer. A missing,
  /// malformed, or **empty** `oauth_scopes` is "learned nothing" and leaves
  /// every group unknown, because a server that does not report scopes must not
  /// be read as a server that grants none — that would newly disable features
  /// like playtime, which run on `!= denied` and work today precisely because
  /// unknown is permissive. Only a non-empty list settles anything.
  /// Note on the governing artifacts: ADR-0013 decision 1, SPEC-0013 REQ
  /// "Optional Scope Groups" and SPEC-0018 REQ "Maintenance Tasks" each
  /// specified the *inverse* of this method — groups stay `unknown` in API-key
  /// mode until a 403, and the resulting blind spot for pair-code and restored
  /// sessions is deliberate. Issue #168 is the report that the blind spot made
  /// the maintenance menu unreachable on the primary handheld login. All three
  /// are amended to match this code in the docs PR #171, which must land
  /// alongside this change.
  // Governing: ADR-0013 (push play state to RomM) decision 1 (amended, #171),
  // SPEC-0013 REQ "Optional Scope Groups" (amended, #171),
  // ADR-0019, SPEC-0018 REQ "Maintenance Tasks" (amended, #171)
  void _learnScopesFromUser(Map<String, dynamic> user) {
    final raw = user['oauth_scopes'];
    if (raw is! List || raw.isEmpty) return;
    final held = <String>{
      for (final scope in raw)
        if (scope != null) scope.toString().trim(),
    }..removeWhere((s) => s.isEmpty);
    if (held.isEmpty) return;

    for (final group in RommScopeGroup.values) {
      // A group the server version rules out is denied without consulting the
      // list, exactly as the password path decides it before requesting.
      final gate = group.gate;
      if (gate != null && supports(gate) == RommFeatureSupport.unsupported) {
        _logGateOnce(gate);
        _scopeStates[group] = RommScopeState.denied;
        continue;
      }
      // Every scope in the group, or the group is not usable: the group is the
      // unit a feature needs, so a half-held pair is not a grant.
      final needed = group.scopes.split(' ').where((s) => s.isNotEmpty);
      _scopeStates[group] = needed.every(held.contains)
          ? RommScopeState.granted
          : RommScopeState.denied;
    }
    _logScopeNegotiation();
  }

  /// Exchanges a RomM pairing code for a client token.
  ///
  /// Points the service at [serverUrl] (credentials untouched), normalises
  /// [code] the way the server does, and refuses anything that isn't eight
  /// characters of [RommPairCode.alphabet] without a request. The exchange is
  /// unauthenticated, so no bearer header is sent. Failures are
  /// [RommException]s whose [RommException.kind] the UI can branch on; network,
  /// TLS, and timeout errors read exactly as they do for [_verifyApiKey].
  ///
  /// The returned token is used like a pasted Client API Token: pass
  /// [RommPairedToken.rawToken] to [configure] as `apiKey`.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Code Exchange"
  Future<RommPairedToken> exchangePairCode(
    String serverUrl,
    String code,
  ) async {
    final normalized = RommPairCode.normalize(code);
    final shown = RommPairCode.display(normalized);
    if (!RommPairCode.isValid(normalized)) {
      _log.w(
        'RomM pair exchange rejected before request: code=$shown '
        'kind=${RommErrorKind.pairCodeInvalid.name}',
      );
      throw RommException(
        'Invalid pairing code format — expected 8 characters as XXXX-XXXX',
        kind: RommErrorKind.pairCodeInvalid,
      );
    }

    _setServerUrl(serverUrl);
    if (_baseUrl.isEmpty) {
      throw RommException('Server URL is empty');
    }

    // The user-facing half of this gate lives in
    // [RommProvider.connectWithPairCode], which SPEC-0010 REQ "Gated Call
    // Sites" names and which owns the localized message. This is the same gate
    // at the layer that actually sends the request, so a second caller cannot
    // bypass it and read a pre-4.8.0 server's raw 404 as "bad code".
    //
    // It can only fire on capabilities probed for *this* server: pointing at a
    // different URL just above forgot them, so an unprobed server still reads
    // as unknown and the exchange is still attempted.
    // Governing: ADR-0010, SPEC-0010 REQ "Gated Call Sites",
    // ADR-0007, SPEC-0007 REQ "Pairing Code Exchange"
    if (supports(RommFeature.clientTokenExchange) ==
        RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.clientTokenExchange);
      _log.w(
        'RomM pair exchange rejected before request: code=$shown '
        'kind=${RommErrorKind.unsupported.name}',
      );
      throw RommException(
        'This RomM server is too old for pairing (needs '
        '${RommFeature.clientTokenExchange.minVersion} or newer)',
        kind: RommErrorKind.unsupported,
      );
    }

    http.Response resp;
    try {
      // One budget across the scheme fallback, not one per attempt.
      resp = await _withSchemeFallback(
        () => _httpClient.post(
          _uri('/api/client-tokens/exchange'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code': normalized}),
        ),
        timeout: _requestTimeout,
      );
    } on TimeoutException {
      _log.w('RomM pair exchange failed: code=$shown error=timeout');
      throw RommException('Connection timed out');
    } on HandshakeException {
      _log.w('RomM pair exchange failed: code=$shown error=tls_handshake');
      throw RommException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
      );
    } on SocketException catch (e) {
      _log.w(
        'RomM pair exchange failed: code=$shown error=socket ${e.message}',
      );
      throw RommException('Cannot reach server: ${e.message}');
    } catch (e) {
      _log.w('RomM pair exchange failed: code=$shown error=$e');
      throw RommException('Connection failed: $e');
    }

    if (resp.statusCode == 200) {
      RommPairedToken token;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('response is not a JSON object');
        }
        token = RommPairedToken.fromJson(decoded);
      } catch (e) {
        _log.w(
          'RomM pair exchange failed: code=$shown status=200 '
          'error=unparseable_body $e',
        );
        throw RommException(
          'Unexpected pairing response from server',
          statusCode: 200,
        );
      }
      if (token.rawToken.isEmpty) {
        _log.w(
          'RomM pair exchange failed: code=$shown status=200 '
          'error=missing_raw_token',
        );
        throw RommException(
          'Pairing response carried no token',
          statusCode: 200,
        );
      }
      _log.i(
        'RomM pair exchange succeeded: code=$shown name=${token.name} '
        'expires_at=${token.expiresAt?.toIso8601String()}',
      );
      return token;
    }

    final RommErrorKind kind;
    final String message;
    switch (resp.statusCode) {
      case 429:
        kind = RommErrorKind.pairRateLimited;
        message = 'Too many pairing attempts; wait a minute and try again';
      case 404:
      case 410:
        kind = RommErrorKind.pairCodeExpired;
        message =
            'Pairing code is invalid or expired — generate a new one in RomM';
      case >= 400 && < 500:
        kind = RommErrorKind.pairCodeInvalid;
        message = 'Pairing code rejected (${resp.statusCode})';
      default:
        kind = RommErrorKind.other;
        message = 'Pairing failed (${resp.statusCode})';
    }
    _log.w(
      'RomM pair exchange failed: code=$shown status=${resp.statusCode} '
      'kind=${kind.name}',
    );
    throw RommException(message, statusCode: resp.statusCode, kind: kind);
  }

  /// Performs the OAuth2 password grant and stores the resulting tokens.
  ///
  /// The heartbeat (run by [authenticate] before this) decides which optional
  /// [RommScopeGroup]s are worth asking for: a group whose endpoints this
  /// server predates does not exist, so asking for it only earns a 403 and a
  /// second POST. That is the *version* question. Whether *this account* holds
  /// a group is a different question the heartbeat cannot answer, which is
  /// what [_negotiateScopeGroups] settles on a 403 — per group, so one denial
  /// costs one feature rather than every optional one.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Probe Before The Token Grant",
  // ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  Future<void> _authenticateWithPassword() async {
    Map<String, String> bodyFor(Iterable<RommScopeGroup> groups) => {
      'grant_type': 'password',
      'username': _username,
      'password': _password,
      // RomM issues an empty-scope token (403 on every read endpoint) unless
      // the requested scopes are passed explicitly.
      'scope': [readScopes, for (final g in groups) g.scopes].join(' '),
    };

    // A group whose endpoints this server does not have is not worth a scope:
    // asking would only earn a 403 and a probe round trip. Those settle as
    // denied without a request, exactly as the old playtime special case did.
    // Governing: ADR-0010, SPEC-0013 REQ "Optional Scope Groups"
    final requested = <RommScopeGroup>[];
    for (final group in RommScopeGroup.values) {
      final gate = group.gate;
      if (gate != null && supports(gate) == RommFeatureSupport.unsupported) {
        _logGateOnce(gate);
        _scopeStates[group] = RommScopeState.denied;
        continue;
      }
      _scopeStates[group] = RommScopeState.unknown;
      requested.add(group);
    }

    http.Response resp;
    try {
      resp = await _postTokenRequest(bodyFor(requested));
      if (resp.statusCode == 200) {
        for (final group in requested) {
          _scopeStates[group] = RommScopeState.granted;
        }
      } else if (resp.statusCode == 403 && requested.isNotEmpty) {
        resp = await _negotiateScopeGroups(requested, bodyFor, resp);
      }
    } on TimeoutException {
      throw RommException('Connection timed out');
    } on HandshakeException {
      throw RommException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
      );
    } on SocketException catch (e) {
      throw RommException('Cannot reach server: ${e.message}');
    } catch (e) {
      throw RommException('Connection failed: $e');
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw RommAuthException(
        'Invalid username or password',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw RommException(
        'Authentication failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    _applyTokenResponse(resp.body);
    _logScopeNegotiation();
  }

  /// Works out which of [requested] this account actually holds after the
  /// combined grant came back 403, and returns the response the caller should
  /// treat as the login's answer.
  ///
  /// One probe per group (the read scopes plus that group alone), then one
  /// final grant for the read scopes plus the granted union — `groups + 2`
  /// token POSTs at the very worst, once per login. A probe answering anything
  /// other than 200 or 403 is not a scope verdict (a rate limit, a 500, a
  /// credential that expired mid-negotiation), so probing stops there and that
  /// response is handed back for the shared error mapping.
  ///
  /// With a single requested group there is nothing to learn: the combined
  /// grant *was* the probe, so its 403 settles the group and only the final
  /// grant is sent.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  Future<http.Response> _negotiateScopeGroups(
    List<RommScopeGroup> requested,
    Map<String, String> Function(Iterable<RommScopeGroup>) bodyFor,
    http.Response combined,
  ) async {
    if (requested.length == 1) {
      _scopeStates[requested.single] = RommScopeState.denied;
    } else {
      for (final group in requested) {
        final probe = await _postTokenRequest(bodyFor([group]));
        if (probe.statusCode == 200) {
          _scopeStates[group] = RommScopeState.granted;
        } else if (probe.statusCode == 403) {
          _scopeStates[group] = RommScopeState.denied;
        } else {
          // Not a scope answer — stop spending requests and let the caller
          // map this status the way it maps any other failed grant.
          return probe;
        }
      }
    }

    final granted = [
      for (final group in requested)
        if (_scopeStates[group] == RommScopeState.granted) group,
    ];
    final base = await _postTokenRequest(bodyFor(granted));
    // A final grant that fails too means the read scopes themselves were
    // refused: report the original 403 rather than pretending we learned
    // something about the groups.
    if (base.statusCode != 200) {
      for (final group in requested) {
        _scopeStates[group] = RommScopeState.unknown;
      }
      return combined;
    }
    return base;
  }

  /// One info line per login naming what the negotiation settled, so a support
  /// log says which features this account can use without re-deriving it.
  // Governing: ADR-0013, SPEC-0013 REQ "Error Handling Standards"
  void _logScopeNegotiation() {
    String names(RommScopeState state) {
      final matches = [
        for (final group in RommScopeGroup.values)
          if (hasScope(group) == state) group.name,
      ];
      return matches.isEmpty ? 'none' : matches.join(',');
    }

    _log.i(
      'RomM scope groups: granted=${names(RommScopeState.granted)} '
      'denied=${names(RommScopeState.denied)} '
      'unknown=${names(RommScopeState.unknown)}',
    );
  }

  Future<void> _refreshAccessToken() async {
    // An API key can't be refreshed or re-minted; if the server rejected it,
    // asking again with the same key would only repeat the rejection.
    if (usesApiKey) return;
    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) {
      // No refresh token: fall back to a full re-authentication.
      await authenticate();
      return;
    }
    try {
      final resp = await _postTokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (resp.statusCode == 200) {
        _applyTokenResponse(resp.body);
        return;
      }
    } catch (e) {
      _log.w('RomM token refresh failed, re-authenticating: $e');
    }
    // Refresh failed for any reason: re-authenticate from credentials.
    await authenticate();
  }

  void _applyTokenResponse(String responseBody) {
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    final access = json['access_token']?.toString();
    if (access == null || access.isEmpty) {
      throw RommException('Server did not return an access token');
    }
    _accessToken = access;
    final refresh = json['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) {
      _refreshToken = refresh;
    }
    // `expires` is the access-token lifetime in seconds.
    final expiresSeconds = (json['expires'] as num?)?.toInt();
    _tokenExpiresMs = expiresSeconds != null
        ? DateTime.now().millisecondsSinceEpoch + expiresSeconds * 1000
        : null;
  }

  /// Ensures a usable access token, authenticating or refreshing as needed.
  ///
  /// API-key mode has nothing to refresh, but it does have something to
  /// *learn*: the scopes the key carries, which only `GET /api/users/me`
  /// reports. [RommProvider.initialize] restores a saved connection without
  /// touching the network — by design — so a session resumed at launch never
  /// calls [authenticate], and before this the scope groups stayed unknown for
  /// the entire run. Every `granted`-gated feature was then invisible until the
  /// user re-connected by hand, which is how the server maintenance menu came
  /// to be missing on a paired handheld across restarts (issue #168).
  ///
  /// Verifying here rather than in `initialize` keeps the restore offline: the
  /// cost is paid by the first call that actually needs the network, once per
  /// connection, and a failure is logged and swallowed because this is a
  /// best-effort enrichment of a request that is about to be sent anyway.
  ///
  /// "Once" holds for the case that matters — a key the server accepts or
  /// rejects is asked about exactly once. A failure splits on whether and how
  /// the server answered: rejected (spent for good), answered badly (retried,
  /// bounded by [_maxApiKeyVerifyFailures] in a row and
  /// [_maxApiKeyVerifyFailuresTotal] in all), never answered (retried,
  /// unbounded, and identified by *how* the failure was raised rather than by
  /// a missing status), and — the fourth case — failed in a way no retry can
  /// fix: an unset URL, a malformed one, a body the server truncated. The
  /// fourth is bounded like the second.
  // Governing: ADR-0010 (RomM heartbeat capability probe),
  // SPEC-0010 REQ "Probe Before The Token Grant" (amended, #171 and #184),
  // ADR-0013, SPEC-0013 REQ "Optional Scope Groups" (amended, #171 and #184)
  Future<void> _ensureToken() async {
    if (usesApiKey && !_apiKeyVerified) {
      _apiKeyVerified = true;
      try {
        await authenticate();
        // The verification landed. Clear the consecutive count so a failure
        // much later gets its own three attempts rather than inheriting a
        // number from a restart this connection has already healed from — and
        // so [_noteApiKeyAccepted] stays inert on a healthy connection, where
        // a zero count is what makes it a no-op.
        _apiKeyVerifyFailures = 0;
      } on RommAuthException catch (e) {
        // Case 1 — the server answered, and its answer was "no" (401/403).
        // Asking again with the same key would only repeat it, so the attempt
        // stays spent for the life of the connection.
        _log.w('RomM API-key rejected during verification: ${e.message}');
      } on RommTransportException catch (e) {
        // Case 3 — the server did not answer at all: a timeout, a dropped
        // socket, a TLS failure. Re-arm, unbounded. A handheld commonly
        // resumes and issues its first request before Wi-Fi is up, and
        // latching on a transport error would leave the groups unknown and the
        // capabilities null for the rest of the process. That is issue #168's
        // exact symptom with a narrower trigger, and `_reprobe()` does not
        // cover it because it restores capabilities without re-running
        // verification. Unbounded is what SPEC-0010 REQ "Probe Before The
        // Token Grant" requires of this case, and the damping that keeps it
        // affordable is partial, not total: [onTransportFailure] is reported
        // by the *calls*, never by [_verifyApiKey], so RommProvider's
        // reachability backoff only quiets this when the surrounding request
        // fails too. That is the case this branch exists for — a handheld off
        // Wi-Fi fails everything — but it is not the only shape. A transport
        // failure confined to `/api/users/me` on a server answering everything
        // else costs one extra request per authenticated call with nothing
        // damping it (measured at 100 calls, 100 extra requests, issue #190
        // finding 3). Reporting it here instead would mark the whole
        // connection offline on the strength of one endpoint, which is the
        // stranding issue #183 finding 2 fixed, so the residual is accepted
        // rather than traded for that.
        //
        // Matched by type rather than by "no status came back": that test used
        // to catch two failures that are not transport faults at all — an
        // empty base URL, which sends nothing, and [_verifyApiKey]'s catch-all
        // — and logged both as an unreachable server (issue #183 finding 3).
        // Governing: ADR-0020, SPEC-0019 REQ "Reachability"
        _apiKeyVerified = false;
        _log.w('RomM API-key verification could not reach the server: $e');
      } catch (e) {
        // The remaining cases are told apart by whether a *status* came back,
        // not by exception type. `RommAuthException` covers only 401/403, so
        // matching on type alone filed every 5xx and 429 under "unreachable" —
        // which is both the wrong policy (issue #173) and the wrong log line
        // (issue #172): #168 was diagnosed almost entirely from these lines,
        // and one that blames the network for a 502 sends the next
        // investigation after Wi-Fi instead of after the server.
        final status = e is RommException ? e.statusCode : null;
        if (status != null) {
          // Case 2 — the server answered, badly. A 5xx is usually a container
          // mid-restart, so re-arm and let a later call heal the connection,
          // but bound it: see [_maxApiKeyVerifyFailures] for why three in a row
          // and [_maxApiKeyVerifyFailuresTotal] for why nine in all.
          _log.w(
            'RomM API-key verification failed: the server answered $status '
            '${_spendApiKeyVerifyBudget()}',
          );
        } else {
          // Case 4 — no status and no dropped connection: an empty base URL
          // and a malformed URI, which send nothing at all, plus a response
          // the server began and we could not finish reading
          // ([_RommUnreadableResponse]), which does cost a request. Bounded
          // like case 2 rather than latched, because a truncating proxy may
          // still be transient while a retry cannot fix any of them; the point
          // of the branch is that the line no longer blames the network for
          // something the network did not do (issue #183 finding 3), and no
          // longer sweeps up the closed-connection `ClientException` that
          // belongs in case 3 (issue #190 finding 1).
          _log.w(
            'RomM API-key verification failed without a status to classify: '
            '$e ${_spendApiKeyVerifyBudget()}',
          );
        }
      }
      return;
    }
    if (_tokenLikelyValid) return;
    if (_accessToken != null && _refreshToken != null) {
      await _refreshAccessToken();
    } else {
      await authenticate();
    }
  }

  /// Spends one attempt from the API-key verification budget and reports where
  /// that leaves it, as the tail of the caller's log line.
  ///
  /// Two counters, because one cannot express both halves of the bound. The
  /// consecutive count is what a healthy server clears, so a container that
  /// restarts twice in a session is forgiven twice; the total is what nothing
  /// clears, so a server that alternates a healthy answer with a failing
  /// verification still stops costing requests. Re-arms the one-shot only while
  /// both bounds have room.
  // Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant",
  // ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  String _spendApiKeyVerifyBudget() {
    _apiKeyVerifyFailures++;
    _apiKeyVerifyFailuresTotal++;
    final outOfAttempts =
        _apiKeyVerifyFailuresTotal >= _maxApiKeyVerifyFailuresTotal;
    final paused = _apiKeyVerifyFailures >= _maxApiKeyVerifyFailures;
    if (!outOfAttempts && !paused) _apiKeyVerified = false;
    final verdict = outOfAttempts
        ? 'giving up for this connection'
        : paused
        ? 'waiting for the server to answer an authenticated call before '
              'retrying'
        : 'a later call will retry';
    return '(attempt $_apiKeyVerifyFailures of $_maxApiKeyVerifyFailures in a '
        'row, $_apiKeyVerifyFailuresTotal of $_maxApiKeyVerifyFailuresTotal for '
        'this connection) — $verdict';
  }

  /// Re-arms the API-key verification one-shot when the server proves it is
  /// answering again, so a connection whose consecutive budget was spent on a
  /// restart heals itself instead of waiting for the app to restart.
  ///
  /// Called from [_sendWithAuthRetry] with the status of a request that carried
  /// this connection's API key in its `Authorization` header, and only in
  /// API-key mode. That is the narrowest healthy signal available, and it is
  /// worth being exact about how narrow: a 2xx there proves the server
  /// answered a request that *carried* this credential, not that it validated
  /// it — RomM answers plenty of endpoints without checking the key closely,
  /// and the 2xx came from a different endpoint than the one whose
  /// verification failed, possibly in the very same call. The unauthenticated
  /// heartbeat is weaker still and deliberately not a trigger: it proves only
  /// that something is listening on the URL, and `RommProvider._reprobe()`
  /// fires it on a timer, so resetting there would let a poll re-arm the probe
  /// on no evidence about the key at all.
  ///
  /// Because the signal is that weak, what makes re-arming safe is not the
  /// signal but [_maxApiKeyVerifyFailuresTotal]: the ceiling nothing clears is
  /// the only thing standing between a server that alternates a healthy answer
  /// with a failing verification and one extra request per call forever. Do
  /// not remove the ceiling on the strength of this method looking careful —
  /// it is deliberately not, and does not try to be.
  // Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant",
  // ADR-0013, SPEC-0013 REQ "Optional Scope Groups"
  void _noteApiKeyAccepted(int status) {
    if (status < 200 || status >= 300) return;
    // A connection that has never failed a verification — the normal case —
    // touches no state here, so the healthy path costs a comparison.
    if (_apiKeyVerifyFailures == 0) return;
    final wasSpent = _apiKeyVerified;
    _apiKeyVerifyFailures = 0;
    if (_apiKeyVerifyFailuresTotal >= _maxApiKeyVerifyFailuresTotal) return;
    _apiKeyVerified = false;
    if (wasSpent) {
      _log.i(
        'RomM API-key verification re-armed: the server answered $status to an '
        'authenticated call after $_apiKeyVerifyFailuresTotal failed '
        'verification(s)',
      );
    }
  }

  /// The credential to send. RomM accepts a Client API Token in exactly the
  /// same `Bearer` header as an OAuth2 access token, so every call site below
  /// is mode-agnostic.
  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer ${usesApiKey ? _apiKey : _accessToken}',
  };

  /// Whether a credential exists at all (used to decide if a request is worth
  /// attaching auth to).
  bool get _hasCredential =>
      usesApiKey || (_accessToken != null && _accessToken!.isNotEmpty);

  /// Authenticates and performs a lightweight call to confirm the connection
  /// and credentials are valid (used by the settings "Test" button).
  Future<void> verifyConnection() async {
    await authenticate();
    // In API-key mode authenticate() *is* the authorized `/api/users/me` call,
    // so repeating it here would only double the round trips.
    if (usesApiKey) return;
    // A successful, authorized call confirms the token works end-to-end. Hit
    // the lightweight `/api/users/me` rather than downloading the full platform
    // list — same auth guarantee, a fraction of the payload. Error mapping is
    // unchanged: authenticate() surfaces bad credentials as 401/403, and any
    // other failure surfaces as the shared "Request failed"/network message.
    await _authedGet('/api/users/me');
  }

  // ── Read endpoints ───────────────────────────────────────────────────────

  /// Sends an authenticated request via [send] and retries it once on an auth
  /// failure: `401` → refresh the access token, `403` → full re-authenticate
  /// (covers a cached token minted before the current scope set). [send] must
  /// build a *fresh* request each call so the retry picks up the new token.
  ///
  /// In API-key mode there is no retry: the key is fixed, its scopes were set
  /// when the user created it, and nothing about a second identical request
  /// would come out differently — so a 401/403 is passed straight to the caller.
  ///
  /// Works for both [http.Response] and [http.StreamedResponse] via [statusOf];
  /// this is the single retry policy shared by every authenticated call site
  /// (plain GETs, asset GETs, uploads and ROM downloads).
  Future<T> _sendWithAuthRetry<T>(
    Future<T> Function() send, {
    required int Function(T resp) statusOf,
  }) async {
    await _ensureToken();
    T resp;
    try {
      resp = await send();
      onTransportSuccess?.call();
    } on TimeoutException catch (e) {
      onTransportFailure?.call(e);
      throw RommException('Request timed out');
    } on SocketException catch (e) {
      onTransportFailure?.call(e);
      throw RommException('Cannot reach server: ${e.message}');
    }
    if (usesApiKey) {
      // The one healthy signal that re-arms a spent verification budget: this
      // request carried the API key and the server answered it.
      // Governing: ADR-0010, SPEC-0010 REQ "Probe Before The Token Grant"
      _noteApiKeyAccepted(statusOf(resp));
      return resp;
    }
    if (statusOf(resp) == 401) {
      await _refreshAccessToken();
      resp = await send();
    } else if (statusOf(resp) == 403) {
      await authenticate();
      resp = await send();
    }
    return resp;
  }

  /// Issues an authenticated GET for a server-relative path+query, applying the
  /// shared [_sendWithAuthRetry] policy and throwing on any non-200.
  Future<http.Response> _authedGet(String pathAndQuery) =>
      _authedGetUri(_uri(pathAndQuery));

  /// Like [_authedGet] but for a fully-built [uri] (used where query parameters
  /// are assembled via [Uri] or the asset path needs bespoke encoding).
  Future<http.Response> _authedGetUri(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient.get(uri, headers: _authHeaders).timeout(timeout),
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode != 200) {
      throw RommException(
        'Request failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    return resp;
  }

  /// Extracts the item list from a RomM list response, tolerating both a bare
  /// JSON array and a paginated `{items: [...]}` envelope. Any other shape
  /// (including `{}`) yields an empty list.
  static List<dynamic> _itemsOf(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map && decoded['items'] is List) {
      return decoded['items'] as List;
    }
    return const [];
  }

  /// Returns all platforms (consoles/systems) on the server.
  Future<List<RommPlatform>> getPlatforms() async {
    final resp = await _authedGet('/api/platforms');
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(RommPlatform.fromJson)
        // RomM's /api/platforms returns every platform its DB knows about,
        // including ones with no scanned ROMs. Hide the empties.
        .where((p) => p.romCount > 0)
        .toList();
  }

  /// Returns the current user's RetroAchievements progression as a map of
  /// RA game id → earned achievement count (`num_awarded`).
  ///
  /// RomM exposes per-user RA progress on the user (`GET /api/users/me` →
  /// `ra_progression.results`, each keyed by `rom_ra_id`), not on individual
  /// ROMs. Returns an empty map when the user hasn't linked/synced RA.
  Future<Map<int, int>> getRaProgression() async {
    final resp = await _authedGet('/api/users/me');
    return parseRaProgression(resp.body);
  }

  /// Parses `/api/users/me` JSON into a map of RA game id → earned count.
  /// Extracted for testability; tolerates missing/partial progression data.
  static Map<int, int> parseRaProgression(String body) {
    final result = <int, int>{};
    final decoded = jsonDecode(body);
    if (decoded is! Map) return result;
    final progression = decoded['ra_progression'];
    if (progression is! Map) return result;
    final results = progression['results'];
    if (results is! List) return result;
    for (final entry in results) {
      if (entry is! Map) continue;
      final gameId = (entry['rom_ra_id'] as num?)?.toInt();
      final awarded = (entry['num_awarded'] as num?)?.toInt();
      if (gameId != null && awarded != null) {
        result[gameId] = awarded;
      }
    }
    return result;
  }

  /// Returns the user's collections (`GET /api/collections`). Tolerates both a
  /// bare list and a `{items: [...]}` envelope; an empty/`{}` body yields [].
  Future<List<RommCollection>> getCollections() async {
    final resp = await _authedGet('/api/collections');
    return _parseCollections(resp.body, isVirtual: false);
  }

  /// Returns RomM virtual collections of [type] (default `collection`, i.e. the
  /// auto-generated game-series groupings shown as "Collections" in RomM's UI).
  /// The endpoint requires the `type` query parameter.
  Future<List<RommCollection>> getVirtualCollections({
    String type = 'collection',
  }) async {
    final resp = await _authedGet(
      '/api/collections/virtual?type=${Uri.encodeQueryComponent(type)}',
    );
    return _parseCollections(resp.body, isVirtual: true);
  }

  static List<RommCollection> _parseCollections(
    String body, {
    required bool isVirtual,
  }) {
    return _itemsOf(jsonDecode(body))
        .whereType<Map<String, dynamic>>()
        .map((j) => RommCollection.fromJson(j, isVirtual: isVirtual))
        .toList();
  }

  /// Returns one page of ROMs filtered by exactly one of [platformId],
  /// [collectionId] (user collection) or [virtualCollectionId] (RomM virtual
  /// collection). RomM paginates via `limit`/`offset`; [search] filters by name
  /// server-side.
  ///
  /// Thin wrapper over [getRomsPage] for callers that only want the rows.
  Future<List<RommRom>> getRoms({
    int? platformId,
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    RommRomFilters filters = RommRomFilters.none,
    int limit = 50,
    int offset = 0,
  }) async {
    final page = await getRomsPage(
      platformIds: platformId == null ? const [] : [platformId],
      collectionId: collectionId,
      virtualCollectionId: virtualCollectionId,
      search: search,
      filters: filters,
      limit: limit,
      offset: offset,
    );
    return page.items;
  }

  /// Returns the ROMs this user has played, most recent first.
  ///
  /// Ordering by `last_played` is also a *filter*: RomM leaves ROMs that have
  /// never been played out of the result entirely, so this returns a short
  /// candidate list rather than a page of the library. Measured against RomM
  /// 5.1.0 on a 9,899-ROM library, where it answered with 5.
  ///
  /// That is what makes the connect-time playtime pull affordable — one request
  /// names every ROM worth asking about, instead of a session lookup per linked
  /// game. `order_dir` must be passed explicitly: RomM defaults to ascending,
  /// which would return the *least* recently played.
  Future<List<RommRom>> getRecentlyPlayedRoms({int limit = 25}) async {
    final resp = await _authedGetUri(
      Uri.parse('$_baseUrl/api/roms').replace(
        queryParameters: <String, String>{
          'limit': '$limit',
          'offset': '0',
          'order_by': 'last_played',
          'order_dir': 'desc',
        },
      ),
    );
    return _itemsOf(
      jsonDecode(resp.body),
    ).whereType<Map<String, dynamic>>().map(RommRom.fromJson).toList();
  }

  /// Returns one page of ROMs along with RomM's result [RommRomPage.total] and
  /// the filter values still available for the query.
  ///
  /// [genres] and [companies] are matched server-side across the whole library,
  /// so they narrow far more than post-filtering a fetched page can. Multiple
  /// values are OR-ed via RomM's `*_logic=any` default.
  ///
  /// Matching is exact and case-sensitive against RomM's own vocabulary:
  /// `Adventure` matches, `adventure` and `Advent` match nothing, and
  /// `Capcom` does not match a ROM credited to "Capcom Production Studio 1".
  /// Callers must therefore pass values RomM actually publishes — see the
  /// `filter_values` on [RommRomPage] — rather than values derived from a
  /// local library, which will silently return nothing when the two
  /// vocabularies disagree.
  ///
  /// Note RomM has no release-year filter — year has to stay a client-side
  /// concern.
  ///
  /// [filters] are RomM's own boolean list filters; only the ones that are set
  /// are sent, under the query-parameter names RomM publishes (`has_saves`,
  /// `playable`, …). An unset filter contributes nothing, so a caller that
  /// passes [RommRomFilters.none] builds byte-for-byte the query it always did.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Filter Parameters"
  Future<RommRomPage> getRomsPage({
    List<int> platformIds = const [],
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    List<String> genres = const [],
    List<String> companies = const [],
    RommRomFilters filters = RommRomFilters.none,
    int limit = 50,
    int offset = 0,
  }) async {
    // Repeated keys (platform_ids, genres, companies) need a list-valued map,
    // which Uri's queryParameters accepts as List<String>.
    final params = <String, dynamic>{
      'limit': '$limit',
      'offset': '$offset',
      'order_by': 'name',
    };
    if (platformIds.isNotEmpty) {
      // RomM filters by the plural `platform_ids`; `platform_id` is ignored.
      params['platform_ids'] = platformIds.map((id) => '$id').toList();
    }
    if (collectionId != null) {
      params['collection_id'] = '$collectionId';
    }
    if (virtualCollectionId != null) {
      params['virtual_collection_id'] = virtualCollectionId;
    }
    if (search != null && search.trim().isNotEmpty) {
      params['search_term'] = search.trim();
    }
    if (genres.isNotEmpty) params['genres'] = genres;
    if (companies.isNotEmpty) params['companies'] = companies;
    // Governing: ADR-0019, SPEC-0018 REQ "Filter Parameters"
    params.addAll(filters.toQueryParameters());

    final resp = await _authedGetUri(
      Uri.parse('$_baseUrl/api/roms').replace(queryParameters: params),
    );
    final decoded = jsonDecode(resp.body);
    // RomM may return either a bare list or a paginated `{items: [...]}` object.
    final items = _itemsOf(
      decoded,
    ).whereType<Map<String, dynamic>>().map(RommRom.fromJson).toList();

    if (decoded is! Map<String, dynamic>) {
      return RommRomPage(items: items, total: items.length);
    }
    return RommRomPage(
      items: items,
      total: (decoded['total'] as num?)?.toInt() ?? items.length,
      filterValues: _filterValuesOf(decoded['filter_values']),
    );
  }

  /// Normalizes RomM's `filter_values` object into string lists.
  ///
  /// `platforms` is dropped: it holds platform *ids*, not names, so it has no
  /// place alongside the string-valued dimensions.
  static Map<String, List<String>> _filterValuesOf(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (key == 'platforms') continue;
      final value = entry.value;
      if (value is! List) continue;
      final values = [
        for (final v in value)
          if ((v?.toString() ?? '').trim().isNotEmpty) v.toString().trim(),
      ];
      if (values.isNotEmpty) out[key] = values;
    }
    return out;
  }

  /// One ROM picked at random by the server, scoped to a platform, a
  /// collection or a virtual collection — the browse screen's "Surprise me".
  ///
  /// Returns null when the scope holds nothing (RomM answers `null`), and null
  /// **without sending a request** when the heartbeat says this server predates
  /// [RommFeature.randomRom]. An [RommFeatureSupport.unknown] version still
  /// tries, per ADR-0010: a heartbeat that never landed must not gate.
  ///
  /// Note the endpoint is far newer than ADR-0019 assumed — see
  /// [RommFeature.randomRom] for the provenance — so on most servers in the
  /// field this gate is what is actually load-bearing, not a formality.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Filter Parameters", REQ "Surprise Me"
  Future<RommRom?> getRandomRom({
    List<int> platformIds = const [],
    int? collectionId,
    String? virtualCollectionId,
  }) async {
    if (supports(RommFeature.randomRom) == RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.randomRom);
      return null;
    }

    final params = <String, dynamic>{};
    if (platformIds.isNotEmpty) {
      params['platform_ids'] = platformIds.map((id) => '$id').toList();
    }
    if (collectionId != null) params['collection_id'] = '$collectionId';
    if (virtualCollectionId != null) {
      params['virtual_collection_id'] = virtualCollectionId;
    }

    final uri = Uri.parse(
      '$_baseUrl/api/roms/random',
    ).replace(queryParameters: params.isEmpty ? null : params);

    final http.Response resp;
    try {
      resp = await _authedGetUri(uri);
    } on RommException catch (e) {
      // A server that reports no version (or a proxy that ate the heartbeat)
      // reaches here rather than the gate above; a 404 is that server saying
      // it has no such endpoint, which is an absent feature and not an error
      // worth surfacing.
      if (e.statusCode == 404) {
        _log.i(
          'RomM random rom unavailable: endpoint=/api/roms/random status=404 '
          'reason=endpoint_absent',
        );
        return null;
      }
      _log.w(
        'RomM random rom failed: endpoint=/api/roms/random '
        'status=${e.statusCode} error=${e.message}',
      );
      rethrow;
    }

    // RomM answers a bare `null` for an empty scope, and 204 would carry no
    // body at all; both mean "nothing to pick".
    if (resp.body.trim().isEmpty) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) return null;
    return RommRom.fromJson(decoded);
  }

  /// Queues one server-side maintenance task and returns the id RomM gave it.
  ///
  /// `POST /api/tasks/run/{name}` needs the `tasks.run` scope, so a connection
  /// known not to hold [RommScopeGroup.tasksRun] returns null without sending
  /// anything (logged once per connection by [_scopeGated]).
  ///
  /// A failure's kind is read from the *body* before the status: only an answer
  /// that says the task is already going maps to [RommErrorKind.taskBusy],
  /// whatever status carried it, and the caller reports that as "already
  /// running" rather than as a failure. The status alone never means busy.
  /// RomM 5.1.0's OpenAPI documents only 200 and 422 on this route, so the 400
  /// observed in the wild (issue #170) is undocumented and could be any refusal
  /// at all — a task name a RomM upgrade renamed, a server-side precondition, a
  /// reverse proxy answering before RomM does. Reading those as "already
  /// running" told the user a scan was underway when nothing had been queued,
  /// so a bare 400 is now an ordinary failure and the body is logged for the
  /// next occurrence to be diagnosed from rather than guessed at.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Maintenance Tasks"
  Future<String?> runTask(String name) async {
    if (_scopeGated(RommScopeGroup.tasksRun)) return null;

    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient
          .post(_uri('/api/tasks/run/$name'), headers: _authHeaders)
          .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final id = _taskIdOf(resp.body);
      _log.i(
        'RomM task queued: endpoint=/api/tasks/run/$name '
        'status=${resp.statusCode} task_id=$id',
      );
      // The id is what the caller reports; an answer without one still means
      // the task was accepted, so the task name stands in rather than a null
      // that would read as "gated".
      return id ?? name;
    }

    if (resp.statusCode == 403) {
      _noteScopeDenial(RommScopeGroup.tasksRun, resp.statusCode);
    }
    // 403 is settled before the body is consulted: the server named that
    // reason itself and `_noteScopeDenial` has just recorded it, so a proxy
    // error page that happens to contain the words cannot turn a scope denial
    // into "already running". Every other status defers to the body.
    final RommErrorKind kind;
    if (resp.statusCode == 403) {
      kind = RommErrorKind.scopeDenied;
    } else if (_saysAlreadyRunning(resp.body)) {
      kind = RommErrorKind.taskBusy;
    } else {
      kind = RommErrorKind.other;
    }
    _log.w(
      'RomM task run failed: endpoint=/api/tasks/run/$name '
      'status=${resp.statusCode} kind=${kind.name} '
      'body=${_briefBody(resp.body)}',
    );
    throw RommException(
      'RomM task run failed: task=$name status=${resp.statusCode}',
      statusCode: resp.statusCode,
      kind: kind,
    );
  }

  /// The `task_id` of a task-run response body, or null for any other shape.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  static String? _taskIdOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final id = decoded['task_id'] ?? decoded['job_id'] ?? decoded['id'];
      final text = id?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Whether a task-run failure body says the task is already going. RomM
  /// words this in the `detail` string rather than in a code, and the wording
  /// has changed between releases, so this matches loosely on purpose.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  static bool _saysAlreadyRunning(String body) {
    final text = body.toLowerCase();
    return text.contains('already running') ||
        text.contains('already queued') ||
        text.contains('already in progress');
  }

  /// How much of an unexpected response body reaches the log.
  static const int _maxLoggedBody = 200;

  /// [body] trimmed to one short line fit for the log.
  ///
  /// Credentials are scrubbed centrally by [LoggerService]'s redacting
  /// printer, so this only has to keep the line readable: whitespace collapsed
  /// — an HTML error page from a reverse proxy is otherwise dozens of lines —
  /// and the tail cut, since what identifies the refusal is always at the
  /// front.
  static String _briefBody(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '<empty>';
    return text.length <= _maxLoggedBody
        ? text
        : '${text.substring(0, _maxLoggedBody)}...';
  }

  /// Returns full detail for a single ROM.
  Future<RommRom> getRom(int id) async {
    final resp = await _authedGet('/api/roms/$id');
    return RommRom.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Returns the raw ROM-detail JSON (metadata + media paths), or null on error.
  /// Used by the metadata import, which needs fields beyond [RommRom].
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    try {
      final resp = await _authedGet('/api/roms/$id');
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _log.e('RomM getRomDetail failed: $e');
      return null;
    }
  }

  /// Fetches raw image bytes (RomM-relative path or absolute URL), or null.
  /// The caller picks the on-disk extension from the actual content — RomM
  /// serves JPEG even from `*.png` cover paths, and the app's image lookup is
  /// extension-sensitive.
  ///
  /// With [requireImage] (the default) a body that isn't a recognisable image
  /// counts as a miss: a resource path RomM no longer has a file for falls
  /// through to its SPA shell, which answers **200 with HTML**. Writing that
  /// out would leave an undecodable `.png` behind — art that looks downloaded
  /// but renders as nothing — and would hide the miss from any caller trying a
  /// second source. Video fetches pass `requireImage: false`.
  Future<Uint8List?> fetchImageBytes(
    String pathOrUrl, {
    bool requireImage = true,
  }) async {
    try {
      final url = pathOrUrl.startsWith('http')
          ? pathOrUrl
          : '$_baseUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        _log.w('RomM image fetch: HTTP ${resp.statusCode} for $url');
        return null;
      }
      final bytes = resp.bodyBytes;
      if (requireImage && !looksLikeImage(bytes)) {
        _log.w('RomM image fetch: non-image body for $url');
        return null;
      }
      return bytes;
    } catch (e) {
      _log.e('RomM image fetch failed: $e');
      return null;
    }
  }

  /// Whether [bytes] start with the magic numbers of an image format the app
  /// can decode. Deliberately content-based: RomM names every stored cover
  /// `big.png` whatever the source served, so the extension proves nothing.
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true; // JPEG
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true; // WEBP
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true; // GIF
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true; // BMP
    }
    return false;
  }

  /// Returns the image file extension ('jpg'/'png'/'webp') implied by [bytes]'
  /// magic numbers, defaulting to 'png'.
  static String imageExtensionFor(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }

  /// Builds an absolute, authenticated-fetchable cover URL for [rom], or null.
  String? coverUrl(RommRom rom) => coverUrlCandidates(rom).firstOrNull;

  /// Every cover URL [rom] could be drawn from, best first: the metadata
  /// provider's own copy, then RomM's cached large and small files.
  ///
  /// RomM populates these independently — a ROM matched without a provider
  /// cover still has the cached file, and a library RomM never cached covers
  /// for only has the provider URL. Anything that draws a cover should walk the
  /// list rather than give up on the first entry, or a ROM whose art the server
  /// plainly has renders as a blank card.
  List<String> coverUrlCandidates(RommRom rom) => _absoluteCoverUrls([
    rom.urlCover,
    rom.pathCoverLarge,
    rom.pathCoverSmall,
  ]);

  /// [coverUrlCandidates] reordered for grid and list tiles: RomM's cached
  /// small file first, then its large file, then the provider's copy.
  ///
  /// A tile is drawn at a fraction of a cover's native size, so the server's
  /// thumbnail is both the cheapest fetch (LAN, small) and the cheapest decode.
  /// Surfaces that show a single large cover keep [coverUrlCandidates].
  // Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Tile Cover Source Order"
  List<String> tileCoverUrlCandidates(RommRom rom) => _absoluteCoverUrls([
    rom.pathCoverSmall,
    rom.pathCoverLarge,
    rom.urlCover,
  ]);

  /// Absolute, authenticated-fetchable URLs for [covers] in the given order,
  /// skipping null/empty entries and joining server-relative paths onto the
  /// base URL.
  List<String> _absoluteCoverUrls(Iterable<String?> covers) {
    final urls = <String>[];
    for (final cover in covers) {
      if (cover == null || cover.isEmpty) continue;
      urls.add(
        (cover.startsWith('http://') || cover.startsWith('https://'))
            ? cover
            : '$_baseUrl${cover.startsWith('/') ? '' : '/'}$cover',
      );
    }
    return urls;
  }

  /// Absolute, authenticated-fetchable cover URLs making up [collection]'s
  /// mosaic thumbnail (up to [limit], RomM's web UI uses 4). Empty when the
  /// server reported no covers.
  List<String> collectionCovers(RommCollection collection, {int limit = 4}) {
    return collection.coverUrls
        .map((c) {
          if (c.startsWith('http://') || c.startsWith('https://')) return c;
          return '$_baseUrl${c.startsWith('/') ? '' : '/'}$c';
        })
        .take(limit)
        .toList();
  }

  /// Absolute logo URL for [platform] (usually a public IGDB CDN URL), or null.
  String? platformLogoUrl(RommPlatform platform) {
    final logo = platform.urlLogo;
    if (logo == null || logo.isEmpty) return null;
    if (logo.startsWith('http://') || logo.startsWith('https://')) {
      return logo;
    }
    return '$_baseUrl${logo.startsWith('/') ? '' : '/'}$logo';
  }

  /// Auth headers for fetching an image, but only when [url] points at the RomM
  /// server itself — never leak the bearer token to third-party CDNs (IGDB,
  /// RetroAchievements, etc. host many covers/logos).
  Map<String, String> imageHeadersFor(String url) =>
      (_hasCredential && url.startsWith(_baseUrl)) ? _authHeaders : const {};

  /// URL of RomM's bundled SVG icon for [platform]. RomM only ships icons for
  /// some slugs, so this may 404.
  String platformIconUrl(RommPlatform platform) =>
      '$_baseUrl/assets/platforms/${platform.slug}.svg';

  /// Fetches an SVG document, returning its source if it looks like SVG, else
  /// null (e.g. a 404 for a slug RomM has no icon for).
  ///
  /// RomM's icons are Illustrator exports that style shapes via `<style>` CSS
  /// classes, which flutter_svg ignores (everything would render solid black),
  /// so we inline those class styles as presentation attributes first.
  Future<String?> fetchSvg(String url) async {
    try {
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.body.contains('<svg')) {
        return _inlineSvgClassStyles(resp.body);
      }
    } catch (_) {
      // Network/parse failure: fall through to null so the UI uses a fallback.
    }
    return null;
  }

  /// Converts `<style>`-block class rules into inline presentation attributes so
  /// renderers without CSS support draw the intended fills/strokes. Handles
  /// multi-selector rules and elements carrying several classes.
  static String _inlineSvgClassStyles(String svg) {
    final styleMatch = RegExp(
      r'<style[^>]*>(.*?)</style>',
      dotAll: true,
    ).firstMatch(svg);
    if (styleMatch == null) return svg;

    final classProps = <String, Map<String, String>>{};
    final ruleRe = RegExp(r'([^{}]+)\{([^{}]+)\}');
    for (final rule in ruleRe.allMatches(styleMatch.group(1)!)) {
      final props = <String, String>{};
      for (final decl in rule.group(2)!.split(';')) {
        final i = decl.indexOf(':');
        if (i < 0) continue;
        final key = decl.substring(0, i).trim();
        final value = decl.substring(i + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) props[key] = value;
      }
      if (props.isEmpty) continue;
      for (final sel in rule.group(1)!.split(',')) {
        final s = sel.trim();
        if (!s.startsWith('.')) continue;
        classProps.putIfAbsent(s.substring(1), () => {}).addAll(props);
      }
    }
    if (classProps.isEmpty) return svg;

    return svg.replaceAllMapped(RegExp(r'class="([^"]+)"'), (m) {
      final merged = <String, String>{};
      for (final c in m.group(1)!.trim().split(RegExp(r'\s+'))) {
        final p = classProps[c];
        if (p != null) merged.addAll(p);
      }
      if (merged.isEmpty) return m.group(0)!;
      final attrs = merged.entries
          .map((e) => '${e.key}="${e.value}"')
          .join(' ');
      return '${m.group(0)} $attrs';
    });
  }

  // ── Metadata fix-up (search, match, cover) ────────────────────────────────

  /// Asks the server's own metadata providers for candidates matching
  /// [searchTerm] for [romId] (`GET /api/search/roms?rom_id=&search_term=`).
  ///
  /// This is a *server-side* search: RomM queries whichever of IGDB, MobyGames,
  /// ScreenScraper, LaunchBox or Hasheous it holds credentials for and answers
  /// with provider-shaped candidates. A server with none configured answers
  /// 500 rather than an empty list, which surfaces as
  /// [RommErrorKind.noMetadataSource] so the caller can say so instead of
  /// showing a generic failure.
  ///
  /// Candidates that name no provider at all are dropped: applying one would
  /// send an update with nothing for RomM to re-match on.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Metadata Search And Apply"
  Future<List<RommSearchResult>> searchRomMetadata(
    int romId,
    String searchTerm,
  ) async {
    final uri = Uri.parse('$_baseUrl/api/search/roms').replace(
      queryParameters: <String, String>{
        'rom_id': '$romId',
        'search_term': searchTerm.trim(),
      },
    );
    final body = await _metadataSearchGet(uri, endpoint: '/api/search/roms');
    final parsed = _itemsOf(
      jsonDecode(body),
    ).whereType<Map<String, dynamic>>().map(RommSearchResult.fromJson).toList();
    final usable = parsed.where((r) => !r.isEmpty).toList();
    if (usable.length != parsed.length) {
      _log.w(
        'RomM metadata search: endpoint=/api/search/roms rom=$romId '
        'dropped=${parsed.length - usable.length} reason=no_provider_id',
      );
    }
    return usable;
  }

  /// Lists cover art for [searchTerm] (`GET /api/search/cover`), flattened to
  /// one entry per image. Maps a 500 the same way [searchRomMetadata] does:
  /// SteamGridDB not being configured is the usual cause.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Metadata Search And Apply"
  Future<List<RommCoverResult>> searchCovers(String searchTerm) async {
    final uri = Uri.parse('$_baseUrl/api/search/cover').replace(
      queryParameters: <String, String>{'search_term': searchTerm.trim()},
    );
    final body = await _metadataSearchGet(uri, endpoint: '/api/search/cover');
    return RommCoverResult.listFromJson(jsonDecode(body));
  }

  /// Applies [result] to the RomM entry for [romId] — a library-wide write
  /// that rewrites what the *server* thinks the ROM is, for every client.
  ///
  /// Returns null without sending anything when this connection is known not
  /// to hold [RommScopeGroup.romsWrite]; otherwise the ROM as RomM returned it
  /// after the update. Throws [RommException] with the endpoint and status on
  /// any other failure.
  ///
  /// A candidate with no name sends no `name` at all rather than a blank one,
  /// for the same reason [applyRomCover] refuses an empty URL: RomM reads a
  /// present-but-empty form field as a value, so a blank `name` would erase
  /// the entry's title for every client of the server. The candidate is still
  /// worth applying — its provider ids are what RomM re-matches on, and the
  /// name it already holds is left alone.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Metadata Search And Apply"
  Future<RommRom?> applyRomMatch(int romId, RommSearchResult result) async {
    if (_scopeGated(RommScopeGroup.romsWrite)) return null;
    final cover = result.coverUrl;
    final name = result.name.trim();
    if (name.isEmpty) {
      _log.w(
        'RomM match update: rom=$romId omitting blank name '
        'endpoint=/api/roms/$romId',
      );
    }
    final fields = <String, String>{
      for (final entry in result.providerIds.entries)
        entry.key: '${entry.value}',
      if (name.isNotEmpty) 'name': name,
      if (cover != null && cover.isNotEmpty) 'url_cover': cover,
    };
    return _putRomForm(romId, fields, action: 'match');
  }

  /// Points the RomM entry for [romId] at [url] as its cover.
  ///
  /// Same gate and same return contract as [applyRomMatch]; an empty URL is
  /// refused locally rather than sent, since RomM reads a blank `url_cover` as
  /// "clear the cover".
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Metadata Search And Apply"
  Future<RommRom?> applyRomCover(int romId, String url) async {
    if (_scopeGated(RommScopeGroup.romsWrite)) return null;
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      _log.w(
        'RomM cover update skipped: rom=$romId reason=empty_url '
        'endpoint=/api/roms/$romId',
      );
      return null;
    }
    return _putRomForm(romId, {'url_cover': trimmed}, action: 'cover');
  }

  /// Shared body of the two searches: one authenticated GET whose 500 becomes
  /// [RommErrorKind.noMetadataSource]. Every failure is logged once with the
  /// endpoint and status before it is rethrown, never swallowed.
  // Governing: ADR-0019, SPEC-0018 REQ "Error Handling Standards"
  Future<String> _metadataSearchGet(Uri uri, {required String endpoint}) async {
    final resp = await _sendWithAuthRetry<http.Response>(
      () =>
          _httpClient.get(uri, headers: _authHeaders).timeout(_requestTimeout),
      statusOf: (r) => r.statusCode,
    );
    if (resp.statusCode == 200) return resp.body;

    // RomM raises rather than returning nothing when it has no provider to
    // ask, so 500 is the only signal that the *server* is unconfigured. It is
    // not worth a retry: the fix is on the server.
    final noSource = resp.statusCode == 500;
    _log.w(
      'RomM metadata search failed: endpoint=$endpoint '
      'status=${resp.statusCode} '
      'reason=${noSource ? 'no_metadata_source' : 'request_failed'}',
    );
    throw RommException(
      'RomM metadata search failed ($endpoint, ${resp.statusCode})',
      statusCode: resp.statusCode,
      kind: noSource
          ? RommErrorKind.noMetadataSource
          : (resp.statusCode == 403
                ? RommErrorKind.scopeDenied
                : RommErrorKind.other),
    );
  }

  /// The one multipart `PUT /api/roms/{id}` both writes go through.
  ///
  /// RomM's update endpoint reads form data, not JSON, and treats an absent
  /// field as "leave it alone" — so only the keys the caller set travel.
  // Governing: ADR-0019, SPEC-0018 REQ "Metadata Search And Apply"
  Future<RommRom> _putRomForm(
    int romId,
    Map<String, String> fields, {
    required String action,
  }) async {
    final uri = _uri('/api/roms/$romId');

    // Capped like `_metadataSearchGet`: the body is a small form, and the
    // dialog above this shows a modal the user cannot dismiss while a write is
    // in flight, so a server that accepts the connection and never answers
    // would otherwise strand a gamepad-only user with no way out.
    // Governing: ADR-0019, SPEC-0018 REQ "Error Handling Standards"
    Future<http.StreamedResponse> send() async {
      final req = http.MultipartRequest('PUT', uri)
        ..headers.addAll(_authHeaders)
        ..fields.addAll(fields);
      return _httpClient.send(req).timeout(_requestTimeout);
    }

    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      send,
      statusOf: (r) => r.statusCode,
    );
    final body = await resp.stream.bytesToString().timeout(_requestTimeout);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (resp.statusCode == 403) {
        _noteScopeDenial(RommScopeGroup.romsWrite, 403);
      }
      _log.w(
        'RomM rom update failed: endpoint=/api/roms/$romId action=$action '
        'status=${resp.statusCode} fields=${fields.keys.join(",")}',
      );
      throw RommException(
        'RomM update failed (/api/roms/$romId, ${resp.statusCode})',
        statusCode: resp.statusCode,
        kind: resp.statusCode == 403
            ? RommErrorKind.scopeDenied
            : RommErrorKind.other,
      );
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw RommException(
        'RomM update returned an unexpected body (/api/roms/$romId)',
        statusCode: resp.statusCode,
      );
    }
    _log.i(
      'RomM rom updated: rom=$romId action=$action '
      'fields=${fields.keys.join(",")}',
    );
    return RommRom.fromJson(decoded);
  }

  // ── Download ─────────────────────────────────────────────────────────────

  /// Streams a ROM download to [destFilePath].
  ///
  /// Writes to a sibling `.part` temp file and renames it into place only on
  /// success, so partial/cancelled downloads never leave a usable-looking file.
  /// Streaming (not buffering) keeps memory flat for multi-GB ROMs.
  ///
  /// [onProgress] receives `(receivedBytes, totalBytes?)`. [shouldCancel] is
  /// polled between chunks; returning true aborts and cleans up the temp file.
  Future<void> downloadRom(
    RommRom rom, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) {
    final fileName = rom.fsName.isNotEmpty ? rom.fsName : '${rom.id}';
    return _streamToFile(
      '/api/roms/${rom.id}/content/${Uri.encodeComponent(fileName)}',
      destFilePath: destFilePath,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }

  /// Streams the body of an authenticated GET on [endpoint] into
  /// [destFilePath].
  ///
  /// The single download path for every large binary this client fetches (ROMs
  /// and firmware): writes to a sibling `.part` temp file and renames it into
  /// place only on success, so a partial, failed or cancelled transfer never
  /// leaves a usable-looking file behind. Streaming (not buffering) keeps
  /// memory flat for multi-GB payloads.
  ///
  /// [onProgress] receives `(receivedBytes, totalBytes?)`. [shouldCancel] is
  /// polled between chunks; returning true aborts with a
  /// [RommCancelledException] and removes the temp file. A non-200 response
  /// throws a [RommException] carrying the status, which the caller may remap
  /// to a more specific [RommErrorKind].
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
  Future<void> _streamToFile(
    String endpoint, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final tmpPath = '$destFilePath.part';
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
    await Directory(path.dirname(destFilePath)).create(recursive: true);

    // Build a fresh request each attempt so the shared retry policy (401 →
    // refresh, 403 → re-auth) picks up the new token on its second try.
    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      () => _httpClient.send(
        http.Request('GET', _uri(endpoint))..headers.addAll(_authHeaders),
      ),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode != 200) {
      throw RommException(
        'Download failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    final total = resp.contentLength;
    var received = 0;
    final sink = tmpFile.openWrite();
    try {
      await for (final chunk in resp.stream) {
        if (shouldCancel?.call() ?? false) {
          await sink.close();
          await tmpFile.delete();
          throw RommCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
      if (e is RommException) rethrow;
      throw RommException('Download error: $e');
    }

    // Replace any existing destination, then move temp into place.
    final destFile = File(destFilePath);
    if (await destFile.exists()) {
      await destFile.delete();
    }
    await tmpFile.rename(destFilePath);
    _log.i('RomM download complete: $destFilePath ($received bytes)');
  }

  // ── Firmware (BIOS) ──────────────────────────────────────────────────────

  /// Lists the firmware RomM holds for [platformId]
  /// (`GET /api/firmware?platform_id=`), through the shared auth-retry policy.
  ///
  /// Rows the server marks `missing_from_fs` are returned too — the panel shows
  /// them as "missing on the server" rather than hiding a record the user can
  /// see in RomM's own UI. A 403 means the credential lacks the `firmware.read`
  /// scope (an API key created without it, typically) and surfaces as
  /// [RommErrorKind.scopeDenied] so the caller can say so instead of showing a
  /// bare status code.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
  Future<List<RommFirmware>> listFirmware(int platformId) async {
    final http.Response resp;
    try {
      resp = await _authedGet('/api/firmware?platform_id=$platformId');
    } on RommException catch (e) {
      throw _asScopeDenied(e) ?? e;
    }
    return _itemsOf(
      jsonDecode(resp.body),
    ).whereType<Map<String, dynamic>>().map(RommFirmware.fromJson).toList();
  }

  /// Streams [firmware]'s bytes into [destFilePath]
  /// (`GET /api/firmware/{id}/content/{file_name}`).
  ///
  /// Shares the `.part`-and-rename path with [downloadRom], so a failed or
  /// cancelled BIOS download leaves nothing behind for an emulator to load. A
  /// 403 surfaces as [RommErrorKind.scopeDenied]; every other failure is logged
  /// exactly once here, naming the file and the cause, and rethrown for the
  /// caller to report.
  ///
  /// A row the server flagged `missing_from_fs` is refused before any request
  /// leaves: ADR-0012 has those "listed, but not downloadable", and this is the
  /// layer that enforces it for every caller — the panel and
  /// [RommFirmwareService.download] gate it too, but neither can speak for a
  /// future caller holding only this service.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
  Future<void> downloadFirmware(
    RommFirmware firmware, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final fileName = firmware.fileName.isNotEmpty
        ? firmware.fileName
        : '${firmware.id}';
    if (firmware.missingFromFs) {
      // Governing: ADR-0012 Decision Outcome §1 ("listed but not downloadable")
      _log.w(
        'RomM firmware download refused: file=$fileName id=${firmware.id} '
        'reason=missing_from_fs',
      );
      throw RommException(
        'RomM no longer holds the bytes for this firmware file',
      );
    }
    try {
      await _streamToFile(
        '/api/firmware/${firmware.id}/content/'
        '${Uri.encodeComponent(fileName)}',
        destFilePath: destFilePath,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
    } on RommCancelledException {
      // A user-requested stop is not a failure: the temp file is already gone.
      _log.i('RomM firmware download cancelled: file=$fileName');
      rethrow;
    } on RommException catch (e) {
      final mapped = _asScopeDenied(e) ?? e;
      _log.w(
        'RomM firmware download failed: file=$fileName id=${firmware.id} '
        'status=${mapped.statusCode ?? '-'} kind=${mapped.kind.name} '
        'cause=${mapped.message}',
      );
      throw mapped;
    }
  }

  /// Rewrites a 403 the *firmware endpoint itself* answered as a
  /// [RommErrorKind.scopeDenied] exception, or returns null when [e] is not a
  /// scope problem.
  ///
  /// Such a 403 has already survived the shared retry (a password-grant
  /// connection re-authenticates once before giving up), so the credential
  /// genuinely lacks `firmware.read` rather than holding a stale token.
  ///
  /// A [RommAuthException] is deliberately left alone: the shared retry
  /// re-authenticates on a 403 and a rejected credential throws 403 out of
  /// *that* step, so remapping every 403 told a user who had changed their RomM
  /// password that their account has no firmware access.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
  static RommException? _asScopeDenied(RommException e) {
    if (e is RommAuthException) return null;
    if (e.statusCode != 403) return null;
    return RommException(
      'This RomM account or API key has no firmware access',
      statusCode: 403,
      kind: RommErrorKind.scopeDenied,
    );
  }

  // ── Saves & states (asset sync) ──────────────────────────────────────────

  /// Lists the save files RomM holds for [romId] (`GET /api/saves?rom_id=`).
  Future<List<RommAsset>> listSaves({required int romId}) =>
      _listAssets('/api/saves', romId: romId, isState: false);

  /// Lists the save states RomM holds for [romId] (`GET /api/states?rom_id=`).
  Future<List<RommAsset>> listStates({required int romId}) =>
      _listAssets('/api/states', romId: romId, isState: true);

  Future<List<RommAsset>> _listAssets(
    String basePath, {
    required int romId,
    required bool isState,
  }) async {
    final resp = await _authedGet('$basePath?rom_id=$romId');
    return _itemsOf(jsonDecode(resp.body))
        .whereType<Map<String, dynamic>>()
        .map((j) => RommAsset.fromJson(j, isState: isState))
        .toList();
  }

  /// Downloads a save's bytes via the saves-only convenience route
  /// (`GET /api/saves/{id}/content`). Used by the generic [ISyncProvider] API
  /// which only has the asset id. For per-game sync prefer [downloadAssetByPath]
  /// (works for states too).
  Future<Uint8List> downloadSaveContent(int assetId) async {
    final resp = await _authedGet('/api/saves/$assetId/content');
    return resp.bodyBytes;
  }

  /// Downloads an asset's bytes from its server-relative [downloadPath]
  /// (`/api/raw/assets/{file_path}/{file_name}?timestamp=...`). This is the
  /// canonical route for BOTH saves and states — states have no `/content`
  /// endpoint.
  Future<Uint8List> downloadAssetByPath(String downloadPath) async {
    // Asset content can be large, so allow a longer per-attempt timeout than a
    // plain metadata GET.
    final resp = await _authedGetUri(
      _assetUri(downloadPath),
      timeout: const Duration(seconds: 60),
    );
    return resp.bodyBytes;
  }

  /// Builds the request URI for a server-supplied asset [downloadPath].
  ///
  /// RomM emits this path **un-encoded** — raw file names and a raw timestamp
  /// — so it must be percent-encoded before use. [Uri.encodeFull] is wrong
  /// here: it leaves `#`/`?`/`&` intact (a save named `Zelda #1.srm` would lose
  /// its `#…` tail to a URL fragment → 404) and would double-escape any literal
  /// `%`. Instead the scheme/host is preserved verbatim while each path segment
  /// and query key/value is encoded individually, so plain-ASCII names come out
  /// byte-identical to the un-encoded input.
  Uri _assetUri(String downloadPath) {
    final String origin;
    final String rest; // path[?query], server-relative, still un-encoded
    if (downloadPath.startsWith('http')) {
      // Absolute URL: peel off scheme://authority (no raw specials live there),
      // keeping the raw path+query for manual encoding below.
      final slash = downloadPath.indexOf('/', downloadPath.indexOf('://') + 3);
      origin = slash == -1 ? downloadPath : downloadPath.substring(0, slash);
      rest = slash == -1 ? '' : downloadPath.substring(slash);
    } else {
      origin = _baseUrl;
      rest = downloadPath.startsWith('/') ? downloadPath : '/$downloadPath';
    }

    final q = rest.indexOf('?');
    final rawPath = q == -1 ? rest : rest.substring(0, q);
    final rawQuery = q == -1 ? null : rest.substring(q + 1);

    final encodedPath = rawPath.split('/').map(Uri.encodeComponent).join('/');
    final encodedQuery = rawQuery == null
        ? ''
        : '?${rawQuery.split('&').map((pair) {
            final eq = pair.indexOf('=');
            if (eq == -1) return Uri.encodeQueryComponent(pair);
            final k = Uri.encodeQueryComponent(pair.substring(0, eq));
            final v = Uri.encodeQueryComponent(pair.substring(eq + 1));
            return '$k=$v';
          }).join('&')}';

    return Uri.parse('$origin$encodedPath$encodedQuery');
  }

  /// Uploads [file] as a save for [romId] (`POST /api/saves`, field `saveFile`).
  ///
  /// [slot] is a stable *name* (RomM's own example is `autosave`), not a number.
  /// Passing one opts the save into RomM's `(rom_id, slot)` pairing — and into
  /// server-side renaming, since RomM datetime-tags every slotted upload.
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _uploadAsset(
    '/api/saves',
    fileField: 'saveFile',
    romId: romId,
    file: file,
    emulator: emulator,
    slot: slot,
    deviceId: deviceId,
    overwrite: overwrite,
    isState: false,
  );

  /// Uploads [file] as a save state for [romId] (`POST /api/states`, field
  /// `stateFile`).
  ///
  /// [slot] is accepted for symmetry with [uploadSave] only — `/api/states` has
  /// no slot parameter, so RomM ignores it and never tags a state's filename.
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) => _uploadAsset(
    '/api/states',
    fileField: 'stateFile',
    romId: romId,
    file: file,
    emulator: emulator,
    slot: slot,
    deviceId: deviceId,
    overwrite: overwrite,
    isState: true,
  );

  /// Uploads [file] as a user screenshot for [romId]
  /// (`POST /api/screenshots?rom_id=`, multipart field `screenshotFile`).
  ///
  /// Deliberately not routed through [_uploadAsset]: the screenshots endpoint
  /// takes neither `overwrite`, `emulator`, `slot` nor `device_id` — it
  /// overwrites on `(user, rom, file name)` unconditionally — and it answers
  /// with a screenshot, not a save/state asset. It does share the auth-retry
  /// policy, so a cached token that predates the `assets.write` scope is
  /// refreshed rather than surfacing as a failed upload.
  ///
  /// Throws [RommException]; a 413 carries [RommErrorKind.payloadTooLarge] so
  /// the caller can record the file as skipped instead of retrying it after
  /// every future session. Returns null when the upload succeeded but the
  /// response body was not a shape [RommScreenshot] recognises — the file is
  /// on the server either way, and only the gallery needs the id.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Upload And Ledger"
  Future<RommScreenshot?> uploadScreenshot(int romId, File file) async {
    final fileName = path.basename(file.path);
    final uri = Uri.parse(
      '$_baseUrl/api/screenshots',
    ).replace(queryParameters: {'rom_id': '$romId'});

    Future<http.StreamedResponse> send() async {
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll(_authHeaders)
        ..files.add(
          await http.MultipartFile.fromPath(
            'screenshotFile',
            file.path,
            filename: fileName,
          ),
        );
      return _httpClient.send(req);
    }

    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      send,
      statusOf: (r) => r.statusCode,
    );

    final body = await resp.stream.bytesToString();
    if (resp.statusCode == 413) {
      throw RommException(
        'Screenshot rejected as too large (413) file="$fileName" rom=$romId',
        statusCode: 413,
        kind: RommErrorKind.payloadTooLarge,
      );
    }
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw RommException(
        'Screenshot upload failed (${resp.statusCode}) '
        'file="$fileName" rom=$romId',
        statusCode: resp.statusCode,
      );
    }
    try {
      return RommScreenshot.fromUploadResponse(jsonDecode(body));
    } catch (e) {
      _log.w(
        'RomM screenshot upload succeeded but the body was unreadable '
        'file="$fileName" rom=$romId error=$e',
      );
      return null;
    }
  }

  /// Replaces the contents of the existing save asset [assetId]
  /// (`PUT /api/saves/{id}`, field `saveFile`).
  Future<RommAsset> updateSave(int assetId, File file) => _updateAsset(
    '/api/saves',
    fileField: 'saveFile',
    assetId: assetId,
    file: file,
    isState: false,
  );

  /// Replaces the contents of the existing state asset [assetId]
  /// (`PUT /api/states/{id}`, field `stateFile`).
  Future<RommAsset> updateState(int assetId, File file) => _updateAsset(
    '/api/states',
    fileField: 'stateFile',
    assetId: assetId,
    file: file,
    isState: true,
  );

  /// Updates an existing asset in place.
  ///
  /// This is deliberately not a `POST` with `overwrite=true`. RomM identifies an
  /// asset by `(rom_id, file_name)` and *ignores* `emulator` when matching, but
  /// it stores the file under the emulator label as a directory component. A
  /// `POST` from a device whose label differs from the one the asset was
  /// created with therefore updates the row's size and timestamp, writes its
  /// bytes to a different directory, and leaves `file_path` pointing at the
  /// original — so the download endpoint keeps serving the *old* file forever
  /// while the metadata describes the new one. Verified against RomM 5.1.0.
  ///
  /// `PUT` carries no emulator at all and rewrites the file at the path the
  /// asset already has, which keeps content and metadata in agreement.
  Future<RommAsset> _updateAsset(
    String basePath, {
    required String fileField,
    required int assetId,
    required File file,
    required bool isState,
  }) async {
    final uri = Uri.parse('$_baseUrl$basePath/$assetId');

    Future<http.StreamedResponse> send() async {
      final req = http.MultipartRequest('PUT', uri)
        ..headers.addAll(_authHeaders)
        ..files.add(
          await http.MultipartFile.fromPath(
            fileField,
            file.path,
            filename: path.basename(file.path),
          ),
        );
      return _httpClient.send(req);
    }

    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      send,
      statusOf: (r) => r.statusCode,
    );

    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw RommException(
        'Update failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    return RommAsset.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
      isState: isState,
    );
  }

  Future<RommAsset> _uploadAsset(
    String basePath, {
    required String fileField,
    required int romId,
    required File file,
    String? emulator,
    String? slot,
    String? deviceId,
    required bool overwrite,
    required bool isState,
  }) async {
    final params = <String, String>{
      'rom_id': '$romId',
      'overwrite': '$overwrite',
    };
    if (emulator != null && emulator.isNotEmpty) params['emulator'] = emulator;
    if (slot != null && slot.isNotEmpty) params['slot'] = slot;
    if (deviceId != null && deviceId.isNotEmpty) params['device_id'] = deviceId;
    final uri = Uri.parse(
      '$_baseUrl$basePath',
    ).replace(queryParameters: params);

    Future<http.StreamedResponse> send() async {
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll(_authHeaders)
        ..files.add(
          await http.MultipartFile.fromPath(
            fileField,
            file.path,
            filename: path.basename(file.path),
          ),
        );
      return _httpClient.send(req);
    }

    // Shared retry policy: 401 → refresh, 403 → re-auth (cached token may
    // predate the assets.write scope).
    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      send,
      statusOf: (r) => r.statusCode,
    );

    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw RommException(
        'Upload failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    final decoded = jsonDecode(body);
    return RommAsset.fromJson(
      decoded as Map<String, dynamic>,
      isState: isState,
    );
  }

  // ── Play sessions (playtime sync) ─────────────────────────────────────────

  /// Uploads finished play sessions (`POST /api/play-sessions`).
  ///
  /// RomM caps a batch at 100 and dedupes on `(rom_id, start_time)`, so a
  /// re-push of a session it already holds is reported back as `duplicate`
  /// rather than added twice. Ingesting also moves the ROM's `last_played`
  /// forward server-side, which is why there's no separate props call.
  ///
  /// Throws [RommException]; a 404 (server predates the feature) or a 403 that
  /// survives the shared re-auth retry also disables further attempts for this
  /// connection — see [playtimeSyncAvailable].
  Future<RommPlaySessionIngestResult> ingestPlaySessions(
    List<RommPlaySession> sessions,
  ) async {
    // Known-old server: the endpoint does not exist, so nothing is sent and
    // the connection settles into the same "no playtime sync here" state a 404
    // would have produced — [playtimeSyncAvailable] reads false and the outbox
    // stops being drained.
    // Governing: ADR-0010 (RomM heartbeat capability probe),
    // SPEC-0010 REQ "Gated Call Sites"
    if (supports(RommFeature.playSessions) == RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.playSessions);
      _playSessionsSupported = false;
      throw RommException(
        'This RomM server predates play-session sync '
        '(needs ${RommFeature.playSessions.minVersion} or newer)',
        kind: RommErrorKind.unsupported,
      );
    }
    if (sessions.isEmpty) {
      return const RommPlaySessionIngestResult(
        acceptedIndexes: {},
        rejectedIndexes: {},
        createdCount: 0,
        skippedCount: 0,
      );
    }
    if (sessions.length > maxPlaySessionBatch) {
      throw RommException(
        'Play-session batch exceeds RomM\'s limit of $maxPlaySessionBatch',
      );
    }

    final body = jsonEncode({
      'sessions': [for (final s in sessions) s.toIngestJson()],
    });

    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient
          .post(
            _uri('/api/play-sessions'),
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode != 200 && resp.statusCode != 201) {
      _notePlaySessionFailure(resp.statusCode);
      throw RommException(
        'Play-session upload failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw RommException('Unexpected play-session response');
    }
    return RommPlaySessionIngestResult.fromJson(decoded);
  }

  /// Every play session the current user has for [romId], across all devices
  /// (`GET /api/play-sessions?rom_id=`).
  ///
  /// RomM only applies its default 50-row page cap when no time filter is
  /// given, so an epoch `start_after` is passed to get the complete history —
  /// the aggregate is meaningless if it silently stops at the newest 50.
  Future<List<RommPlaySession>> getPlaySessions({required int romId}) async {
    // Same gate as the upload: no request to an endpoint this server predates.
    // Governing: ADR-0010, SPEC-0010 REQ "Gated Call Sites"
    if (supports(RommFeature.playSessions) == RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.playSessions);
      _playSessionsSupported = false;
      throw RommException(
        'This RomM server predates play-session sync '
        '(needs ${RommFeature.playSessions.minVersion} or newer)',
        kind: RommErrorKind.unsupported,
      );
    }
    final uri = Uri.parse('$_baseUrl/api/play-sessions').replace(
      queryParameters: {
        'rom_id': '$romId',
        'start_after': '1970-01-01T00:00:00Z',
      },
    );

    final http.Response resp;
    try {
      resp = await _authedGetUri(uri);
    } on RommException catch (e) {
      if (e.statusCode != null) _notePlaySessionFailure(e.statusCode!);
      rethrow;
    }

    return _itemsOf(
      jsonDecode(resp.body),
    ).whereType<Map<String, dynamic>>().map(RommPlaySession.fromJson).toList();
  }

  /// Marks the play-session API unusable when the server's answer says it will
  /// never work on this connection: `404` (endpoint absent) or a `403` that has
  /// already survived one re-authentication, i.e. a genuine scope denial. In
  /// API-key mode a 403 is conclusive on the first try — the key's scopes were
  /// fixed when the user created it, so there is no re-auth that could widen
  /// them, and this is how a key issued without `roms.user.*` quietly settles
  /// into "everything but playtime sync" instead of erroring on every game exit.
  void _notePlaySessionFailure(int statusCode) {
    if (statusCode == 404 || statusCode == 403) {
      if (_playSessionsSupported) {
        _log.w(
          'RomM play-session API unavailable ($statusCode) - '
          'playtime sync disabled for this connection',
        );
      }
      _playSessionsSupported = false;
      // A 403 here is the scope answer the login could not get (API-key mode)
      // or one that survived a re-auth: either way the playtime group is not
      // held on this connection, so every other call that needs it stops too.
      // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
      _noteScopeDenial(RommScopeGroup.playtime, statusCode);
    }
  }

  /// Records a conclusive per-endpoint 403 as "this connection does not hold
  /// [group]".
  ///
  /// Conclusive because every authenticated call already runs through
  /// [_sendWithAuthRetry], which re-authenticates once on a 403 — so a 403 that
  /// reaches a caller was answered by a freshly minted token. In API-key mode
  /// there is no re-auth to widen the key's fixed scopes, so the first 403 is
  /// conclusive by construction. This is how an API key issued without a group
  /// settles into "everything but that feature" instead of erroring forever.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Optional Scope Groups"
  void _noteScopeDenial(RommScopeGroup group, int statusCode) {
    if (statusCode != 403) return;
    if (_scopeStates[group] == RommScopeState.denied) return;
    _scopeStates[group] = RommScopeState.denied;
    _log.w(
      'RomM scope denied: group=${group.name} scopes="${group.scopes}" '
      'status=403',
    );
  }

  /// True when [group] is known not to be held, logging the reason once per
  /// group per connection so a silently skipped push is explainable.
  // Governing: ADR-0013, SPEC-0013 REQ "Error Handling Standards"
  bool _scopeGated(RommScopeGroup group) {
    if (hasScope(group) != RommScopeState.denied) return false;
    if (_scopeGatesLogged.add(group)) {
      _log.i(
        'RomM write skipped: group=${group.name} reason=scope_denied '
        'scopes="${group.scopes}"',
      );
    }
    return true;
  }

  // -- Play-state write-back (props and favourites) --------------------------

  /// Writes per-user ROM props (`PUT /api/roms/{id}/props`).
  ///
  /// The body carries only the fields given — RomM 4.9.0 takes a bare
  /// `RomUserData` object, so an absent key means "leave it alone" — and
  /// `?update_last_played=true` is added when [updateLastPlayed] is set, which
  /// is how a finished session moves the server's `last_played` forward.
  ///
  /// Returns false without sending anything when this server predates the bare
  /// body ([RommFeature.romPropsBareBody]) or this connection is known not to
  /// hold [RommScopeGroup.playtime]; true when the server confirmed the write.
  /// Throws [RommException] on a failure worth retrying, with the rom id and
  /// status in the message; a 404 carries its status so the caller can drop the
  /// queued row for a ROM the server no longer has.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Update Call"
  Future<bool> updateRomProps(
    int romId, {
    bool? hidden,
    bool updateLastPlayed = false,
  }) async {
    if (supports(RommFeature.romPropsBareBody) ==
        RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.romPropsBareBody);
      return false;
    }
    if (_scopeGated(RommScopeGroup.playtime)) return false;
    if (hidden == null && !updateLastPlayed) return false;

    final body = <String, dynamic>{'hidden': ?hidden};
    var uri = _uri('/api/roms/$romId/props');
    if (updateLastPlayed) {
      uri = uri.replace(queryParameters: {'update_last_played': 'true'});
    }

    final resp = await _sendWithAuthRetry<http.Response>(
      () => _httpClient
          .put(
            uri,
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode == 200 || resp.statusCode == 201) return true;
    if (resp.statusCode == 403) {
      _noteScopeDenial(RommScopeGroup.playtime, resp.statusCode);
    }
    throw RommException(
      'RomM props update failed: rom=$romId status=${resp.statusCode}',
      statusCode: resp.statusCode,
      kind: resp.statusCode == 403
          ? RommErrorKind.scopeDenied
          : RommErrorKind.other,
    );
  }

  /// The id of this account's favourites collection, creating it when the
  /// server has none.
  ///
  /// RomM models favourites as an ordinary collection flagged `is_favorite`,
  /// one per user, so the list is read once per connection and the id cached.
  /// [name] is the localized "Favourites" the collection is created with; it is
  /// only used on the create path, since an existing collection keeps whatever
  /// the user named it.
  ///
  /// Returns null without sending anything when the server predates
  /// [RommFeature.collectionRomsAddRemove] or the connection is known not to
  /// hold [RommScopeGroup.collectionsWrite].
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Favourites Collection"
  Future<int?> ensureFavouritesCollection({String name = 'Favorites'}) async {
    if (supports(RommFeature.collectionRomsAddRemove) ==
        RommFeatureSupport.unsupported) {
      _logGateOnce(RommFeature.collectionRomsAddRemove);
      return null;
    }
    if (_scopeGated(RommScopeGroup.collectionsWrite)) return null;
    final cached = _favouritesCollectionId;
    if (cached != null) return cached;

    final http.Response listing;
    try {
      listing = await _authedGet('/api/collections');
    } on RommException catch (e) {
      if (e.statusCode == 403) {
        _noteScopeDenial(RommScopeGroup.collectionsWrite, 403);
        return null;
      }
      rethrow;
    }

    final existing = _favouritesIdOf(listing.body);
    if (existing != null) {
      _favouritesCollectionId = existing;
      return existing;
    }

    final createName = name.trim().isEmpty ? 'Favorites' : name.trim();
    final uri = _uri(
      '/api/collections',
    ).replace(queryParameters: {'is_favorite': 'true'});

    final resp = await _sendWithAuthRetry<http.StreamedResponse>(
      () => _httpClient.send(
        http.MultipartRequest('POST', uri)
          ..headers.addAll(_authHeaders)
          ..fields['name'] = createName,
      ),
      statusOf: (r) => r.statusCode,
    );
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      if (resp.statusCode == 403) {
        _noteScopeDenial(RommScopeGroup.collectionsWrite, 403);
        return null;
      }
      throw RommException(
        'RomM favourites collection create failed: '
        'status=${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }

    final created = _idOfCollectionBody(body);
    if (created == null) {
      throw RommException('RomM returned no id for the favourites collection');
    }
    _log.i('RomM favourites collection created: id=$created name=$createName');
    _favouritesCollectionId = created;
    return created;
  }

  /// Adds [romId] to the favourites collection
  /// (`POST /api/collections/{id}/roms`).
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Favourites Collection"
  Future<bool> addFavourite(int romId, {String collectionName = 'Favorites'}) =>
      _editFavourites(romId, add: true, collectionName: collectionName);

  /// Removes [romId] from the favourites collection
  /// (`DELETE /api/collections/{id}/roms`).
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Favourites Collection"
  Future<bool> removeFavourite(
    int romId, {
    String collectionName = 'Favorites',
  }) => _editFavourites(romId, add: false, collectionName: collectionName);

  /// Shared body of [addFavourite] and [removeFavourite]: same URL, same
  /// `{"rom_ids": [...]}` payload, only the verb differs.
  ///
  /// Returns false without a request when the feature is gated; true when the
  /// server confirmed the change.
  // Governing: ADR-0013, SPEC-0013 REQ "Favourites Collection"
  Future<bool> _editFavourites(
    int romId, {
    required bool add,
    required String collectionName,
  }) async {
    final collectionId = await ensureFavouritesCollection(name: collectionName);
    if (collectionId == null) return false;

    final uri = _uri('/api/collections/$collectionId/roms');
    final headers = {..._authHeaders, 'Content-Type': 'application/json'};
    final body = jsonEncode({
      'rom_ids': [romId],
    });

    final resp = await _sendWithAuthRetry<http.Response>(
      () =>
          (add
                  ? _httpClient.post(uri, headers: headers, body: body)
                  : _httpClient.delete(uri, headers: headers, body: body))
              .timeout(const Duration(seconds: 30)),
      statusOf: (r) => r.statusCode,
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
    if (resp.statusCode == 403) {
      _noteScopeDenial(RommScopeGroup.collectionsWrite, 403);
    }
    throw RommException(
      'RomM favourite ${add ? 'add' : 'remove'} failed: rom=$romId '
      'collection=$collectionId status=${resp.statusCode}',
      statusCode: resp.statusCode,
      kind: resp.statusCode == 403
          ? RommErrorKind.scopeDenied
          : RommErrorKind.other,
    );
  }

  /// The id of the `is_favorite` collection in a `/api/collections` body, or
  /// null when the account has none. Tolerates both the bare list and the
  /// `{items: [...]}` envelope, like every other list read here.
  // Governing: ADR-0013, SPEC-0013 REQ "Favourites Collection"
  static int? _favouritesIdOf(String body) {
    final decoded = jsonDecode(body);
    for (final item in _itemsOf(decoded)) {
      if (item is! Map) continue;
      if (item['is_favorite'] != true) continue;
      final id = int.tryParse(item['id'].toString());
      if (id != null) return id;
    }
    return null;
  }

  /// The `id` of a single-collection response body, or null for any other
  /// shape.
  static int? _idOfCollectionBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return int.tryParse(decoded['id'].toString());
    } catch (_) {
      return null;
    }
  }
}
