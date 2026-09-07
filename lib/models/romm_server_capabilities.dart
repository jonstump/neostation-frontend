/// RomM server capabilities, as reported by the public `GET /api/heartbeat`
/// endpoint, plus the single table of "which RomM version introduced which
/// endpoint" that every version gate in the client consults.
///
/// Pure data: no Flutter, no HTTP, no logging. [RommService] fetches and stores
/// it, the provider exposes it, the UI reads it.
// Governing: ADR-0010 (RomM heartbeat capability probe),
// SPEC-0010 REQ "Capability Value Object"
library;

/// A RomM release number: `major.minor.patch` with an optional prerelease tag
/// (`4.8.0-beta.1`). Ordered, with a prerelease sorting *below* the release it
/// leads up to, so a beta of the version that introduced a feature does not
/// count as having it.
// Governing: ADR-0010, SPEC-0010 REQ "Capability Value Object"
class RommServerVersion implements Comparable<RommServerVersion> {
  final int major;
  final int minor;
  final int patch;

  /// The prerelease tag without its leading `-` (`beta.1`), or null for a
  /// final release. Build metadata (`+sha`) is discarded, as semver says it
  /// carries no ordering.
  final String? prerelease;

  const RommServerVersion(
    this.major,
    this.minor,
    this.patch, {
    this.prerelease,
  });

  /// `major[.minor[.patch]]` with an optional `v` prefix, an optional
  /// `-prerelease` tag and optional `+build` metadata. Returns null for
  /// anything else — including an empty string, `latest`, or a commit sha —
  /// so an unrecognised version reads as "unknown" rather than as 0.0.0.
  static RommServerVersion? parse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    // Build metadata never affects ordering; drop it before anything else.
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);

    String? prerelease;
    final dash = text.indexOf('-');
    if (dash >= 0) {
      prerelease = text.substring(dash + 1);
      if (prerelease.isEmpty) prerelease = null;
      text = text.substring(0, dash);
    }

    final parts = text.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final numbers = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0) return null;
      numbers.add(value);
    }
    return RommServerVersion(
      numbers[0],
      numbers.length > 1 ? numbers[1] : 0,
      numbers.length > 2 ? numbers[2] : 0,
      prerelease: prerelease,
    );
  }

  bool get isPrerelease => prerelease != null;

  @override
  int compareTo(RommServerVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    final a = prerelease;
    final b = other.prerelease;
    if (a == null && b == null) return 0;
    // A release outranks any prerelease of the same numbers (semver §11.3).
    if (a == null) return 1;
    if (b == null) return -1;
    return _comparePrerelease(a, b);
  }

  /// Dot-separated identifiers, numeric ones compared as numbers and sorting
  /// below alphanumeric ones (semver §11.4): `beta.2` > `beta.10` would be
  /// wrong, `alpha` < `beta` is right.
  static int _comparePrerelease(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < left.length && i < right.length; i++) {
      final ln = int.tryParse(left[i]);
      final rn = int.tryParse(right[i]);
      if (ln != null && rn != null) {
        if (ln != rn) return ln.compareTo(rn);
      } else if (ln != null) {
        return -1;
      } else if (rn != null) {
        return 1;
      } else {
        final c = left[i].compareTo(right[i]);
        if (c != 0) return c;
      }
    }
    return left.length.compareTo(right.length);
  }

  bool operator >=(RommServerVersion other) => compareTo(other) >= 0;
  bool operator <(RommServerVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is RommServerVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.prerelease == prerelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease == null ? '' : '-$prerelease'}';
}

/// Whether the connected server has a given endpoint.
///
/// [unknown] is the answer when the heartbeat never landed (blocked by a
/// reverse proxy, timed out, unparseable). It MUST never gate: the caller
/// behaves exactly as it did before ADR-0010 — try, and degrade on 404 or a
/// confirmed 403.
// Governing: ADR-0010, SPEC-0010 REQ "Feature Threshold Table"
enum RommFeatureSupport { supported, unsupported, unknown }

/// Every RomM endpoint NeoStation gates on the server version, with the
/// release that introduced it.
///
/// This is the single threshold table (ADR-0010): a new gated endpoint adds
/// one entry here and one guard at its call site. Every entry carries the RomM
/// commit or release it was verified against, because a wrong threshold hides
/// a feature the server actually has.
// Governing: ADR-0010, SPEC-0010 REQ "Feature Threshold Table"
enum RommFeature {
  /// `POST /api/play-sessions` — playtime ingest.
  ///
  /// Verified: play-session ingest landed on `rommapp/romm` master 2026-03-22,
  /// after the 4.7.0 tag and before 4.8.0, so 4.8.0 is the first release that
  /// carries it (confirmed against the 4.8.0 release notes).
  playSessions(RommServerVersion(4, 8, 0)),

  /// `POST /api/client-tokens/exchange` — the pairing-code exchange behind
  /// ADR-0007's pair-code and QR login.
  ///
  /// Verified: client API tokens with QR pairing shipped in commit e0b25fbc
  /// (2026-03-11), released in RomM 4.8.0.
  clientTokenExchange(RommServerVersion(4, 8, 0)),

  /// `GET /api/roms?…` lookup by file hash, used by ADR-0011's local-ROM
  /// linking.
  ///
  /// Verified: `/api/roms/by-hash` first shipped in commit 8a66ac81
  /// (2025-12-12), released in RomM 4.5.0.
  romLookupByHash(RommServerVersion(4, 5, 0)),

  /// `PUT /api/roms/{id}/props` taking a *bare* `RomUserData` body plus the
  /// `update_last_played` / `remove_last_played` query flags. Older servers
  /// expect a `{"data": ...}` wrapper, which is a different call shape rather
  /// than a missing field, so NeoStation gates on the release instead of
  /// carrying two encoders.
  ///
  /// Verified: the bare-body props endpoint is part of the RomM 4.9.0 release
  /// (published 2026-06-12), the threshold recorded in ADR-0013.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props Update Call"
  romPropsBareBody(RommServerVersion(4, 9, 0)),

  /// `POST|DELETE /api/collections/{id}/roms` — adding and removing ROMs from
  /// a collection by id, which is how the favourites collection is edited.
  ///
  /// Verified: the collection rom add/remove endpoints are part of the RomM
  /// 4.9.0 release (published 2026-06-12), the threshold recorded in ADR-0013.
  // Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Favourites Collection"
  collectionRomsAddRemove(RommServerVersion(4, 9, 0)),

  /// The ROM detail's `user_screenshots` gallery: the `is_gallery` /
  /// `is_public` flags and `GET /api/screenshots/{id}/content`, which the
  /// details card's RomM gallery strip reads.
  ///
  /// Verified: RomM 5.0.0 is the release that added the gallery flags and the
  /// screenshot content route to `backend/endpoints/screenshots.py`; earlier
  /// servers accept the upload (`POST /api/screenshots?rom_id=`, 3.10+) but
  /// carry no gallery to read back. Recorded in ADR-0016.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Gallery Strip"
  screenshotGallery(RommServerVersion(5, 0, 0)),

  /// `GET /api/roms/random` — one ROM picked server-side, behind the browse
  /// screen's "Surprise me".
  ///
  /// Verified against `rommapp/romm` itself, and the answer is **5.2.0**
  /// (released 2026-08-20) — not the 4.8.0 that ADR-0019 and SPEC-0018 name.
  /// The route (`@protected_route(router.get, "/random", [Scope.ROMS_READ])`
  /// in `backend/endpoints/roms/__init__.py`) was added by commit 1ee6cea0,
  /// "perf(roms): pick a random rom without paging to a random offset"
  /// (2026-08-02, PR #4071, merged as d874cc17 on 2026-08-04). It is absent
  /// from the 4.8.0, 4.9.0, 5.0.0 and 5.1.0 trees and present from
  /// 5.1.1-beta.2 (2026-08-16) onward; 5.1.1 never shipped a final, so 5.2.0
  /// is the first release that answers it. RomM's own web UI picked randomly
  /// by paging to a random offset before that, which is why the *feature*
  /// predates the *endpoint*. Recording 4.8.0 here would have offered
  /// "Surprise me" on every 4.8–5.1 server and earned a 404 on every press.
  // Governing: ADR-0019 (expose RomM library filters, search and maintenance),
  // SPEC-0018 REQ "Filter Parameters"
  randomRom(RommServerVersion(5, 2, 0));

  const RommFeature(this.minVersion);

  /// The oldest RomM release that answers this endpoint.
  final RommServerVersion minVersion;
}

/// One heartbeat response, parsed.
///
/// Every field is optional on the wire: RomM adds and renames sections between
/// releases, and a reverse proxy may trim the body. Parsing therefore never
/// throws — a section that is missing or the wrong shape simply yields an
/// empty map, an empty list, or null.
// Governing: ADR-0010, SPEC-0010 REQ "Capability Value Object"
class RommServerCapabilities {
  /// `SYSTEM.VERSION`, or null when absent or unparseable. Null means every
  /// feature reads as [RommFeatureSupport.unknown].
  final RommServerVersion? version;

  /// `METADATA_SOURCES.*` — which scrapers the server has configured
  /// (`SS_API_ENABLED`, `IGDB_API_ENABLED`, `SS_DEV_CREDENTIALS_SET`, …).
  final Map<String, bool> metadataSources;

  /// `FRONTEND.DISABLE_USERPASS_LOGIN` — the server refuses the password
  /// grant and expects a token or OIDC. False when the flag is absent.
  final bool passwordLoginDisabled;

  /// `FILESYSTEM.FS_PLATFORMS` — the platform slugs the server has folders for.
  final List<String> fsPlatforms;

  /// `TASKS.*` boolean flags (`ENABLE_SCHEDULED_*`); the `*_CRON` strings
  /// beside them are not booleans and are dropped.
  final Map<String, bool> tasks;

  /// `EMULATION.*` boolean flags (`DISABLE_*`).
  final Map<String, bool> emulation;

  /// When the probe that produced this object answered.
  final DateTime fetchedAt;

  const RommServerCapabilities({
    required this.version,
    required this.metadataSources,
    required this.passwordLoginDisabled,
    required this.fsPlatforms,
    required this.tasks,
    required this.emulation,
    required this.fetchedAt,
  });

  /// An empty capability set, for a body that carried nothing usable.
  RommServerCapabilities.empty({DateTime? fetchedAt})
    : version = null,
      metadataSources = const {},
      passwordLoginDisabled = false,
      fsPlatforms = const [],
      tasks = const {},
      emulation = const {},
      fetchedAt = fetchedAt ?? DateTime.now();

  /// Parses a heartbeat body. Never throws: unknown sections are ignored,
  /// missing ones default, and non-boolean flag values are dropped.
  factory RommServerCapabilities.fromJson(
    Map<String, dynamic> json, {
    DateTime? fetchedAt,
  }) {
    final system = _section(json['SYSTEM']);
    final frontend = _section(json['FRONTEND']);
    final filesystem = _section(json['FILESYSTEM']);
    return RommServerCapabilities(
      version: RommServerVersion.parse(system['VERSION']?.toString()),
      metadataSources: _boolFlags(json['METADATA_SOURCES']),
      passwordLoginDisabled:
          _asBool(frontend['DISABLE_USERPASS_LOGIN']) ?? false,
      fsPlatforms: _stringList(filesystem['FS_PLATFORMS']),
      tasks: _boolFlags(json['TASKS']),
      emulation: _boolFlags(json['EMULATION']),
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }

  /// Whether this server answers [feature]'s endpoint: [supported] at or above
  /// the threshold, [unsupported] below it (a prerelease of the threshold
  /// counts as below), [unknown] when the version never parsed.
  // Governing: ADR-0010, SPEC-0010 REQ "Feature Threshold Table"
  RommFeatureSupport supports(RommFeature feature) {
    final v = version;
    if (v == null) return RommFeatureSupport.unknown;
    return v >= feature.minVersion
        ? RommFeatureSupport.supported
        : RommFeatureSupport.unsupported;
  }

  static Map<String, dynamic> _section(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : const {};

  static Map<String, bool> _boolFlags(Object? value) {
    if (value is! Map) return const {};
    final out = <String, bool>{};
    value.forEach((key, raw) {
      final parsed = _asBool(raw);
      if (parsed != null) out['$key'] = parsed;
    });
    return out;
  }

  /// Booleans as RomM sends them, plus the shapes a proxy or an older release
  /// might: `"true"`, `1`. Anything else (a cron string, a nested map) is not
  /// a flag and yields null so the key is dropped.
  static bool? _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) {
      if (value == 1) return true;
      if (value == 0) return false;
      return null;
    }
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true') return true;
      if (text == 'false') return false;
    }
    return null;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item != null) '$item',
    ];
  }

  @override
  String toString() =>
      'RommServerCapabilities(version: $version, '
      'passwordLoginDisabled: $passwordLoginDisabled, '
      'metadataSources: ${metadataSources.length}, '
      'fsPlatforms: ${fsPlatforms.length})';
}
