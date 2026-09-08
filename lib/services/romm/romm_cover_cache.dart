import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/romm_catalog_row.dart';
import '../../repositories/config_repository.dart';
import '../../utils/bounded_concurrency.dart';
import '../config_service.dart';
import '../logger_service.dart';
import '../romm_service.dart';

/// Fetches the bytes behind one cover URL, or null when the server had
/// nothing usable there (a miss, a non-image body, a dropped connection).
/// Auth headers are the fetcher's business, which is why the production
/// fetcher is [RommService.fetchImageBytes].
typedef RommCoverFetcher = Future<Uint8List?> Function(String url);

/// The URLs a row's cover could be fetched from, best first.
typedef RommCoverUrlResolver = List<String> Function(RommCatalogRow row);

/// The directory the cache lives in, resolved once on [RommCoverCache.initialize].
typedef RommCoverCacheRoot = Future<String> Function();

/// The cap in megabytes, read fresh at every eviction so a settings change
/// takes effect without a restart.
typedef RommCoverCacheCap = Future<int> Function();

/// One cached file, as the LRU index sees it.
@immutable
class RommCoverCacheEntry {
  final String path;
  final int sizeBytes;
  final DateTime lastUsed;

  const RommCoverCacheEntry({
    required this.path,
    required this.sizeBytes,
    required this.lastUsed,
  });

  RommCoverCacheEntry touched(DateTime now) =>
      RommCoverCacheEntry(path: path, sizeBytes: sizeBytes, lastUsed: now);
}

/// On-disk cache of RomM's small covers, so a remote entry in the library
/// draws its art offline and without a request.
///
/// Files live under `<mediaCache>/romm_covers/<serverHash>/<romId>.<ext>`:
/// one directory per server so [clear] on disconnect is one delete, the RomM
/// rom id as the name because it is the key the catalog, the link map and the
/// downloads all share, and the extension from the bytes because RomM serves
/// JPEG from `*.png` paths and the image lookup is extension-sensitive.
///
/// An in-memory index of `(path, size, lastUsed)` is rebuilt from the
/// directory on [initialize] and kept current by every fill, touch and
/// eviction, which is what lets [pathFor] answer synchronously in a build
/// method. `lastUsed` is in-memory only: touching a file's mtime on every
/// render would cost a write per card, so a rebuild after a restart orders
/// files by fill time instead. That only affects which files go first when
/// the cache is over its cap — never whether a cover is found.
///
/// Neither [MediaCacheService] nor [ImageCacheBudget] does this job: the
/// former caches *availability* of scraped media in memory (no bytes, no
/// disk) and the latter sizes Flutter's decoded-bitmap cache. This is the
/// only disk-backed cover store in the app.
///
/// Everything with a side effect is injectable — the root directory, the
/// fetcher, the URL resolver, the cap, the stop signal and the clock — so a
/// test runs it against a temp directory and a fake fetcher.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
class RommCoverCache {
  static final _defaultLog = LoggerService.instance;

  /// The directory under the media cache root that holds every server's
  /// covers.
  static const String directoryName = 'romm_covers';

  /// Default cap when the config has no value.
  static const int defaultCapMb = 200;

  /// Default bound on covers fetched by one [prefetch].
  static const int defaultPrefetchMax = 300;

  /// Default number of concurrent fetches in a [prefetch].
  static const int defaultPrefetchConcurrency = 3;

  /// Fills between the periodic size checks lazy fills trigger.
  static const int fillsPerEvictionCheck = 100;

  static const String _logLabel = 'RomM cover cache';

  final RommCoverCacheRoot _root;
  final RommCoverFetcher _fetch;
  final RommCoverUrlResolver _coverUrls;
  final RommCoverCacheCap _capMb;
  final bool Function() _shouldStop;
  final DateTime Function() _clock;
  final LoggerService _log;

  /// `serverHash -> romId -> entry`.
  final Map<String, Map<int, RommCoverCacheEntry>> _index = {};

  /// Fills in flight, keyed by `serverHash/romId`, so two cards asking for the
  /// same cover share one fetch.
  final Map<String, Future<String?>> _inFlight = {};

  /// `serverUrl -> serverHash`, so [pathFor] does not hash on every build.
  final Map<String, String> _hashes = {};

  String? _rootPath;
  Future<void>? _initializing;
  int _fillsSinceCheck = 0;
  Future<void>? _evicting;

  RommCoverCache({
    required RommCoverCacheRoot root,
    required RommCoverFetcher fetch,
    required RommCoverUrlResolver coverUrls,
    RommCoverCacheCap? capMb,
    bool Function()? shouldStop,
    DateTime Function()? clock,
    LoggerService? logger,
  }) : _root = root,
       _fetch = fetch,
       _coverUrls = coverUrls,
       _capMb = capMb ?? ConfigRepository.getRommCoverCacheMb,
       _shouldStop = shouldStop ?? _neverStop,
       _clock = clock ?? DateTime.now,
       _log = logger ?? _defaultLog;

  /// The production cache: files under the app's media cache, bytes through
  /// [service] (which adds the auth headers and refuses non-image bodies),
  /// URLs in the tile order (small file first), the cap from the config.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  factory RommCoverCache.forService(
    RommService service, {
    bool Function()? shouldStop,
  }) => RommCoverCache(
    root: () async => p.join(await ConfigService.getMediaPath(), directoryName),
    fetch: (url) => service.fetchImageBytes(url, quiet: true),
    coverUrls: (row) => service.tileCoverUrlCandidatesFor(
      pathCoverSmall: row.pathCoverSmall,
      pathCoverLarge: row.pathCoverLarge,
      urlCover: row.urlCover,
    ),
    shouldStop: shouldStop,
  );

  static bool _neverStop() => false;

  /// The directory this cache reads and writes, once initialized.
  String? get rootPath => _rootPath;

  /// Files in the index, over every server.
  int get entryCount => _index.values.fold(0, (n, m) => n + m.length);

  /// Bytes in the index, over every server.
  int get totalBytes => _index.values.fold(
    0,
    (n, m) => n + m.values.fold(0, (s, e) => s + e.sizeBytes),
  );

  /// Resolves the root directory and rebuilds the index from what is on
  /// disk. Idempotent; concurrent callers share one scan. Never throws: an
  /// unreadable root leaves the cache empty and every fill a miss.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final root = await _root();
      _rootPath = root;
      final dir = Directory(root);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        return;
      }
      var files = 0;
      await for (final serverDir in dir.list(followLinks: false)) {
        if (serverDir is! Directory) continue;
        final serverHash = p.basename(serverDir.path);
        final entries = _index.putIfAbsent(serverHash, () => {});
        await for (final file in serverDir.list(followLinks: false)) {
          if (file is! File) continue;
          final romId = int.tryParse(p.basenameWithoutExtension(file.path));
          if (romId == null) continue;
          try {
            final stat = await file.stat();
            entries[romId] = RommCoverCacheEntry(
              path: file.path,
              sizeBytes: stat.size,
              lastUsed: stat.modified,
            );
            files++;
          } catch (e) {
            _log.d('$_logLabel: skipped unreadable file=${file.path} cause=$e');
          }
        }
      }
      _log.i(
        '$_logLabel ready: root=$root files=$files '
        'bytes=$totalBytes',
      );
    } catch (e) {
      // A root that cannot be created or listed. Every pathFor is a miss and
      // every ensure fails quietly, which the cards read as "placeholder".
      _log.w('$_logLabel: could not initialize: $e');
    }
  }

  /// The cached file for [romId] on [serverUrl], or null when the cache does
  /// not have it. Synchronous and cheap on purpose: this is called from build
  /// methods. A hit counts as a use for eviction.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  String? pathFor(String serverUrl, int romId) {
    final entries = _index[_hashFor(serverUrl)];
    if (entries == null) return null;
    final entry = entries[romId];
    if (entry == null) return null;
    entries[romId] = entry.touched(_clock());
    return entry.path;
  }

  /// The cached path for [row], filling it from the server first when it is
  /// missing. Returns null when every candidate URL failed; never throws. A
  /// failed fill is logged at debug and the next call tries again, so a
  /// server that is briefly unreachable costs one placeholder, not a
  /// permanent miss.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  // Governing: SPEC-0019 REQ "Error Handling Standards"
  Future<String?> ensure(String serverUrl, RommCatalogRow row) async {
    await initialize();
    final existing = pathFor(serverUrl, row.rommRomId);
    if (existing != null) return existing;
    final root = _rootPath;
    if (root == null) return null;

    final serverHash = _hashFor(serverUrl);
    final key = '$serverHash/${row.rommRomId}';
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final fill = _fill(root, serverHash, serverUrl, row);
    _inFlight[key] = fill;
    try {
      return await fill;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _fill(
    String root,
    String serverHash,
    String serverUrl,
    RommCatalogRow row,
  ) async {
    final urls = _coverUrls(row);
    if (urls.isEmpty) return null;
    for (final url in urls) {
      if (_shouldStop()) return null;
      Uint8List? bytes;
      try {
        bytes = await _fetch(url);
      } catch (e) {
        _log.d(
          '$_logLabel: fetch failed: rom=${row.rommRomId} url=$url cause=$e',
        );
        continue;
      }
      if (bytes == null || bytes.isEmpty) {
        _log.d('$_logLabel: miss: rom=${row.rommRomId} url=$url');
        continue;
      }
      final path = await _write(root, serverHash, row.rommRomId, bytes);
      if (path == null) return null;
      _fillsSinceCheck++;
      if (_fillsSinceCheck >= fillsPerEvictionCheck) {
        _fillsSinceCheck = 0;
        unawaited(evictIfNeeded());
      }
      return path;
    }
    return null;
  }

  /// Writes [bytes] as `<root>/<serverHash>/<romId>.<ext>` through a temp
  /// file and a rename, so a card never reads a half-written cover, and
  /// records it in the index. Returns null when the write failed.
  Future<String?> _write(
    String root,
    String serverHash,
    int romId,
    Uint8List bytes,
  ) async {
    final ext = RommService.imageExtensionFor(bytes);
    final dir = Directory(p.join(root, serverHash));
    final path = p.join(dir.path, '$romId.$ext');
    try {
      await dir.create(recursive: true);
      final tmp = File('$path.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    } catch (e) {
      _log.d('$_logLabel: write failed: path=$path cause=$e');
      return null;
    }
    final entries = _index.putIfAbsent(serverHash, () => {});
    // A refill under a different extension leaves the old file behind
    // otherwise; the index only ever knows one file per rom id.
    final previous = entries[romId];
    if (previous != null && previous.path != path) {
      await _delete(previous.path);
    }
    entries[romId] = RommCoverCacheEntry(
      path: path,
      sizeBytes: bytes.length,
      lastUsed: _clock(),
    );
    return path;
  }

  /// Fills the covers [rows] are missing, at most [max] of them with
  /// [concurrency] fetches in flight, then evicts down to the cap. Runs
  /// detached from the refresh that calls it; the stop signal is checked
  /// between files. Returns how many covers were filled.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  // Governing: SPEC-0019 REQ "Concurrency Safety"
  Future<int> prefetch(
    List<RommCatalogRow> rows, {
    int max = defaultPrefetchMax,
    int concurrency = defaultPrefetchConcurrency,
  }) async {
    await initialize();
    if (_rootPath == null || rows.isEmpty || max <= 0) return 0;
    final seen = <String>{};
    final missing = <RommCatalogRow>[];
    for (final row in rows) {
      if (missing.length >= max) break;
      if (!seen.add('${row.serverUrl}/${row.rommRomId}')) continue;
      if (_index[_hashFor(row.serverUrl)]?[row.rommRomId] != null) continue;
      missing.add(row);
    }
    if (missing.isEmpty) return 0;

    var filled = 0;
    await runBounded<RommCatalogRow>(
      missing,
      concurrency < 1 ? 1 : concurrency,
      (row) async {
        if (_shouldStop()) return;
        if (await ensure(row.serverUrl, row) != null) filled++;
      },
      label: '$_logLabel prefetch',
    );
    _log.i(
      '$_logLabel prefetch: candidates=${rows.length} '
      'missing=${missing.length} filled=$filled bytes=$totalBytes',
    );
    await evictIfNeeded();
    return filled;
  }

  /// Removes least-recently-used files until the cache is under the cap.
  /// Concurrent callers share one pass.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
  Future<void> evictIfNeeded() => _evicting ??= _evict().whenComplete(() {
    _evicting = null;
  });

  Future<void> _evict() async {
    int capMb;
    try {
      capMb = await _capMb();
    } catch (e) {
      _log.d('$_logLabel: cap unreadable, using default: $e');
      capMb = defaultCapMb;
    }
    if (capMb <= 0) capMb = defaultCapMb;
    final capBytes = capMb * 1024 * 1024;
    var total = totalBytes;
    if (total <= capBytes) return;

    final all = <(String serverHash, int romId, RommCoverCacheEntry entry)>[
      for (final server in _index.entries)
        for (final e in server.value.entries) (server.key, e.key, e.value),
    ]..sort((a, b) => a.$3.lastUsed.compareTo(b.$3.lastUsed));

    var removed = 0;
    var freed = 0;
    for (final (serverHash, romId, entry) in all) {
      if (total <= capBytes) break;
      if (_shouldStop()) break;
      _index[serverHash]?.remove(romId);
      total -= entry.sizeBytes;
      freed += entry.sizeBytes;
      removed++;
      await _delete(entry.path);
    }
    _log.i(
      '$_logLabel evicted: files=$removed bytes=$freed '
      'cap_mb=$capMb remaining_bytes=$total',
    );
  }

  /// Deletes every cached cover of [serverUrl] and forgets it. Never throws.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Settings And Actions"
  Future<void> clear(String serverUrl) async {
    await initialize();
    final serverHash = _hashFor(serverUrl);
    final entries = _index.remove(serverHash);
    final root = _rootPath;
    if (root == null) return;
    final dir = Directory(p.join(root, serverHash));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      _log.i(
        '$_logLabel cleared: server=$serverUrl files=${entries?.length ?? 0}',
      );
    } catch (e) {
      _log.w('$_logLabel: clear failed: server=$serverUrl cause=$e');
    }
  }

  Future<void> _delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.d('$_logLabel: delete failed: path=$path cause=$e');
    }
  }

  String _hashFor(String serverUrl) =>
      _hashes[serverUrl] ??= serverHash(serverUrl);

  /// The directory name for [serverUrl]: a short SHA-1 of the URL with any
  /// trailing slash dropped, so `https://romm.lan` and `https://romm.lan/`
  /// share a cache and no URL character ever reaches the filesystem.
  @visibleForTesting
  static String serverHash(String serverUrl) {
    var normalized = serverUrl.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return crypto.sha1
        .convert(utf8.encode(normalized))
        .toString()
        .substring(0, 16);
  }
}

/// The file a card should draw for a game, or null for the placeholder.
///
/// A local game always draws its own scraped media ([scrapedMediaPath], as
/// `FileProvider.getMediaPath` resolves it) and never the RomM cache, even
/// when it is linked to a RomM rom id; a remote entry draws whatever the cache
/// has for its rom id, and nothing until the cache has it. The caller owns
/// the decode: pass the result to the image widget with `cacheWidth` from
/// `coverDecodeWidth` (`lib/utils/cover_decode.dart`), the SPEC-0008 rule.
///
/// Pure on purpose — no lookups, no I/O — so a build method can call it and a
/// test can pin the precedence with three arguments.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Cover Cache"
// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Decode At Tile Size"
String? rommCoverPathFor({
  required bool isLocal,
  required String? scrapedMediaPath,
  required String serverUrl,
  required int? rommRomId,
  required RommCoverCache cache,
}) {
  if (isLocal) {
    return (scrapedMediaPath == null || scrapedMediaPath.isEmpty)
        ? null
        : scrapedMediaPath;
  }
  if (rommRomId == null || serverUrl.isEmpty) return null;
  return cache.pathFor(serverUrl, rommRomId);
}
