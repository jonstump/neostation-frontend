import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../utils/semaphore.dart';
import '../romm_service.dart';

/// An [ImageProvider] for a RomM cover, fetched through [RommService] under a
/// shared concurrency bound.
///
/// `Image.network` cannot be used for these. `NetworkImage` fetches on
/// Flutter's own process-wide `HttpClient`, which is separate from
/// [RommService]'s and has no `maxConnectionsPerHost`, and production code has
/// no hook to configure it — `debugNetworkImageHttpClientProvider` is
/// debug-only. A screenful of grid tiles therefore opened as many sockets to
/// the RomM server as it had tiles, competing with the request fetching the
/// next page of games on the same host. On a large platform that is how the
/// page request itself came to time out.
///
/// ScreenScraper already solves this for its own client with a semaphore; this
/// is the same answer for RomM's covers. [maxConcurrent] is deliberately small:
/// tiles are fetched to be looked at now, and a queue that drains in order
/// paints the visible rows sooner than a burst that starts everything at once
/// and finishes nothing.
///
/// This writes nothing to disk. The decoded frame lives in Flutter's
/// `ImageCache` exactly as it did before, so SPEC-0008 REQ "In-Memory Cache
/// Only" is unaffected — what changes is how the bytes are fetched, not where
/// they are kept.
// Governing: ADR-0008 (RomM browse cover loading), SPEC-0008 REQ "Tile Cover Source Order", REQ "Concurrency Safety"
@immutable
class RommCoverImage extends ImageProvider<RommCoverImage> {
  /// Concurrent cover fetches allowed across the whole app.
  ///
  /// Five, matching ScreenScraper's bound. Enough to keep a scroll fed on a
  /// LAN server, few enough to leave connections for the API calls the browse
  /// screen needs to keep working while covers load.
  static const int maxConcurrent = 5;

  static final Semaphore _gate = Semaphore(maxConcurrent);

  /// The absolute cover URL, already resolved by
  /// [RommService.tileCoverUrlCandidates].
  final String url;

  /// The service whose auth headers and bounded client the fetch goes through.
  final RommService service;

  /// Applied to the decoded frame, as `Image.network`'s `scale` was.
  final double scale;

  const RommCoverImage(this.url, this.service, {this.scale = 1.0});

  @override
  Future<RommCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RommCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    RommCoverImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [DiagnosticsProperty<String>('URL', key.url)],
    );
  }

  Future<ui.Codec> _load(
    RommCoverImage key,
    ImageDecoderCallback decode,
  ) async {
    await _gate.acquire();
    Uint8List? bytes;
    try {
      // `quiet: true`: a 404 on the first candidate is the documented way to
      // reach the second (see `tileCoverUrlCandidates`), so a miss here is
      // expected traffic rather than something to warn about once per tile.
      bytes = await key.service.fetchImageBytes(key.url, quiet: true);
    } finally {
      _gate.release();
    }
    if (bytes == null || bytes.isEmpty) {
      RommDeadCovers.add(key.url);
      // The same shape `NetworkImage` fails with, so the card's existing
      // `errorBuilder` keeps working and still advances to the next candidate.
      throw NetworkImageLoadException(statusCode: 404, uri: Uri.parse(key.url));
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is RommCoverImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'RommCoverImage("$url", scale: $scale)';
}

/// Cover URLs that came back with nothing this session, so a tile does not
/// re-ask for a dead end every time it is rebuilt.
///
/// The grid keeps two rows either side of the viewport built and disposes the
/// rest, so scrolling away and back gives a tile a fresh `State` with its
/// candidate index at zero. For a library where RomM never cached small
/// thumbnails that meant re-requesting the same 404 on every scrollback,
/// forever — the app kept rediscovering what it already knew.
///
/// In memory only, and deliberately not persisted: a cover missing today may
/// be there after the next RomM scan, and a restart is the cheapest way to
/// ask again. Nothing is written to disk, so SPEC-0008 REQ "In-Memory Cache
/// Only" still holds — this records an *absence*, not an image.
// Governing: ADR-0008 (RomM browse cover loading), SPEC-0008 REQ "Tile Cover Source Order"
class RommDeadCovers {
  static final Set<String> _urls = <String>{};

  /// Whether [url] already answered with nothing this session.
  static bool contains(String url) => _urls.contains(url);

  /// Records that [url] had no usable image behind it.
  static void add(String url) => _urls.add(url);

  /// Forgets everything. Called when the server changes underneath us — a
  /// different RomM, or a fresh scan — and by tests.
  static void clear() => _urls.clear();

  /// How many dead sources are remembered, for tests and logging.
  static int get length => _urls.length;
}
