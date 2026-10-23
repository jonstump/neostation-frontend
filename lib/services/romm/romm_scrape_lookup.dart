import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/romm_rom.dart';
import '../../models/system_model.dart';
import '../../utils/romm_scrape_matcher.dart';
import '../romm_service.dart';

/// Every RomM ROM of the platforms that map onto [system], loaded once per run.
typedef RommCatalogLoader = Future<List<RommRom>> Function(SystemModel system);

/// RomM's own search of [system]'s platforms for [term] (one request).
typedef RommCandidateSearch =
    Future<List<RommRom>> Function(SystemModel system, String term);

/// Whether [error] says something about the RomM *server* (it did not answer,
/// or answered with a server-side failure or a rate limit) rather than about
/// the game or the request. The same classes as a failed detail request:
/// timeout, socket or TLS error, a response-less failure, `5xx` and `429`.
/// A `401`/`403`/`404` is not transport: the server answered.
bool rommErrorIsTransport(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return true;
  }
  if (error is RommException) {
    final status = error.statusCode;
    return status == null || status >= 500 || status == 429;
  }
  return false;
}

/// What a lookup found, or why it could not look.
class RommScrapeLookupResult {
  /// How the game lined up; null when the lookup itself [failed].
  final RommScrapeMatch? match;

  /// The failure behind a lookup that could not run.
  final Object? error;

  /// True when [error] is transport-class ([rommErrorIsTransport]).
  final bool transport;

  const RommScrapeLookupResult.found(RommScrapeMatch this.match)
    : error = null,
      transport = false;

  const RommScrapeLookupResult.failed(
    Object this.error, {
    this.transport = true,
  }) : match = null;

  bool get failed => error != null;
}

/// Looks a game up in RomM when it has no link, for scraping from RomM as a
/// source.
///
/// Two routes, one rule ([RommScrapeIndex]):
///
/// * [findInCatalog], for a bulk run: the first game of a system loads that
///   system's whole catalog, builds the index once, and every worker shares it
///   through the same in-flight future. A failed load is remembered for the
///   life of this object (one run) and answered to every later game of that
///   system without another request, so a dead server is asked once per
///   system, not once per game.
/// * [findBySearch], for a single game: one RomM search for its title, matched
///   in memory against what came back.
///
/// Network access is injected, so the matching, the sharing and the failure
/// handling are testable without a server, and the caller decides how a
/// request is gated and counted.
class RommScrapeLookup {
  final RommCatalogLoader _loadCatalog;
  final RommCandidateSearch _search;
  final Map<String, Future<_Catalog>> _catalogs = {};

  /// Catalog loads started, one per system at most. Test seam.
  int catalogLoads = 0;

  RommScrapeLookup({
    required RommCatalogLoader loadCatalog,
    required RommCandidateSearch search,
  }) : _loadCatalog = loadCatalog,
       _search = search;

  /// Looks [filename] up in [system]'s catalog, loading it on first use.
  Future<RommScrapeLookupResult> findInCatalog(
    SystemModel system,
    String filename,
  ) async {
    final catalog = await (_catalogs[_key(system)] ??= _load(system));
    if (catalog.error != null) {
      return RommScrapeLookupResult.failed(
        catalog.error!,
        transport: catalog.transport,
      );
    }
    return RommScrapeLookupResult.found(catalog.index!.lookup(filename));
  }

  /// Looks [filename] up with one RomM search for its title.
  Future<RommScrapeLookupResult> findBySearch(
    SystemModel system,
    String filename,
  ) async {
    final term = RommScrapeIndex.searchTerm(filename);
    if (term.isEmpty) {
      return const RommScrapeLookupResult.found(RommScrapeMatch.none());
    }
    try {
      final candidates = await _search(system, term);
      return RommScrapeLookupResult.found(
        RommScrapeIndex.build(candidates).lookup(filename),
      );
    } catch (e) {
      return RommScrapeLookupResult.failed(
        e,
        transport: rommErrorIsTransport(e),
      );
    }
  }

  /// The system's identity for sharing: its id, or its folder when it has none.
  static String _key(SystemModel system) => system.id ?? system.folderName;

  Future<_Catalog> _load(SystemModel system) async {
    catalogLoads++;
    try {
      return _Catalog.loaded(RommScrapeIndex.build(await _loadCatalog(system)));
    } catch (e) {
      return _Catalog.failed(e, rommErrorIsTransport(e));
    }
  }
}

class _Catalog {
  final RommScrapeIndex? index;
  final Object? error;
  final bool transport;

  _Catalog.loaded(RommScrapeIndex this.index) : error = null, transport = false;
  _Catalog.failed(Object this.error, this.transport) : index = null;
}
