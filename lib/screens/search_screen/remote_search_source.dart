import '../../providers/romm_provider.dart';

/// Where the search screen's RomM rows come from.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
enum RemoteSearchSource {
  /// The server's own search endpoint: exact counts, every filter, paging.
  server,

  /// The persisted catalog (`app_romm_catalog`): what the device holds of the
  /// library while the server is unreachable. Name and system and genre
  /// only — the catalog keeps no companies.
  catalog,
}

/// The source for [reachability]: the catalog while the server is known to
/// be unreachable, the server otherwise (including `unknown`, which is a cold
/// start with nothing asked yet — a request is the way to find out).
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display And Search"
RemoteSearchSource remoteSearchSourceFor(RommReachability reachability) =>
    reachability == RommReachability.offline
    ? RemoteSearchSource.catalog
    : RemoteSearchSource.server;
