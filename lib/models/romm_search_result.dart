/// One candidate returned by RomM's own metadata providers.
///
/// `GET /api/search/roms` asks the *server* to query whichever of IGDB, MobyGames,
/// ScreenScraper, LaunchBox, Hasheous or SteamGridDB it has credentials for, and
/// answers with one object per candidate. The shape is provider-shaped rather
/// than fixed: every provider contributes its own `<provider>_id` and
/// `<provider>_url_cover` key, and a RomM release that gains a provider gains
/// two more keys. Parsing therefore collects the id keys generically instead of
/// naming them, so a newer server's new provider still round-trips through
/// [providerIds] into the multipart update without a code change.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Metadata Search And Apply"
class RommSearchResult {
  /// Every `<provider>_id` the candidate carries, keyed by the wire name
  /// (`igdb_id`, `moby_id`, `ss_id`, …) so it can be posted back verbatim.
  final Map<String, int> providerIds;

  final String name;
  final String summary;

  /// The best cover the candidate offers, or null when it has none.
  final String? coverUrl;

  /// RomM's platform id for the candidate, when the provider reported one.
  final int? platformId;

  const RommSearchResult({
    required this.providerIds,
    required this.name,
    this.summary = '',
    this.coverUrl,
    this.platformId,
  });

  /// Keys that look like a provider id but are not one: the ROM being fixed and
  /// the platform it sits on travel in the same object.
  static const Set<String> _notProviderIds = {'rom_id', 'platform_id', 'id'};

  /// Cover keys in the order they are preferred. `url_cover` is RomM's own
  /// normalized field on newer releases; the provider-specific keys are the
  /// fallback on servers that only send those.
  static const List<String> _coverKeys = [
    'url_cover',
    'igdb_url_cover',
    'moby_url_cover',
    'ss_url_cover',
    'launchbox_url_cover',
    'hasheous_url_cover',
    'sgdb_url_cover',
  ];

  /// Parses one candidate. Never throws: a key of an unexpected type is
  /// dropped rather than failing the whole search.
  factory RommSearchResult.fromJson(Map<String, dynamic> json) {
    final ids = <String, int>{};
    json.forEach((key, value) {
      if (!key.endsWith('_id') || _notProviderIds.contains(key)) return;
      final parsed = _asInt(value);
      if (parsed != null) ids[key] = parsed;
    });

    String? cover;
    for (final key in _coverKeys) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) {
        cover = value.trim();
        break;
      }
    }

    return RommSearchResult(
      providerIds: Map.unmodifiable(ids),
      name: (json['name'] ?? '').toString().trim(),
      summary: (json['summary'] ?? '').toString().trim(),
      coverUrl: cover,
      platformId: _asInt(json['platform_id']),
    );
  }

  /// True when the candidate names no provider at all, in which case applying
  /// it would send an update with nothing to match on.
  bool get isEmpty => providerIds.isEmpty;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  @override
  String toString() =>
      'RommSearchResult(name: $name, ids: $providerIds, '
      'platformId: $platformId)';
}

/// One cover offered by `GET /api/search/cover` (SteamGridDB, through RomM).
///
/// RomM groups its answer by game name with a `resources` list of sizes; older
/// releases answer with a flat list instead. [listFromJson] flattens both into
/// one candidate per image so the picker can show a plain grid of covers.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance), SPEC-0018 REQ "Metadata Search And Apply"
class RommCoverResult {
  /// The game name the cover was found under — several covers share it.
  final String name;

  /// The full-size image, which is what `url_cover` is set to.
  final String url;

  /// A smaller image to paint in the list, or null when the server sent none.
  final String? thumbUrl;

  const RommCoverResult({required this.name, required this.url, this.thumbUrl});

  /// The URL to paint: the thumbnail when there is one, the full cover
  /// otherwise.
  String get previewUrl => thumbUrl ?? url;

  /// Flattens a `/api/search/cover` body into one entry per image, dropping
  /// anything without a usable URL. Never throws.
  static List<RommCoverResult> listFromJson(Object? decoded) {
    final items = decoded is List
        ? decoded
        : (decoded is Map && decoded['items'] is List
              ? decoded['items'] as List
              : const []);
    final out = <RommCoverResult>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString().trim();
      final resources = raw['resources'];
      if (resources is List) {
        for (final resource in resources) {
          if (resource is! Map) continue;
          final entry = _entry(name, resource);
          if (entry != null) out.add(entry);
        }
        continue;
      }
      final entry = _entry(name, raw);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  static RommCoverResult? _entry(String name, Map<Object?, Object?> raw) {
    final url = (raw['url'] ?? raw['url_cover'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    final thumb = (raw['thumb'] ?? '').toString().trim();
    return RommCoverResult(
      name: name,
      url: url,
      thumbUrl: thumb.isEmpty ? null : thumb,
    );
  }

  @override
  String toString() => 'RommCoverResult(name: $name, url: $url)';
}
