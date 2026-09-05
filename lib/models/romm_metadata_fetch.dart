/// How a RomM metadata fetch treats what the game already has.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "RomM Metadata Writer With Two Modes"
enum RommMetadataMode {
  /// Write only metadata columns that are null or blank and only media files
  /// that do not exist. An existing row keeps its `is_fully_scraped` and
  /// `metadata_source`; a row this mode inserts is fully scraped with source
  /// `romm`.
  fillGaps,

  /// Write every mapped column and replace every mapped media file; the row
  /// becomes fully scraped with source `romm`. Non-English descriptions are
  /// cleared (RomM has none) and the publisher is left empty (RomM has no
  /// developer/publisher split).
  replace,
}

/// What a [RommMetadataOutcome] amounts to.
enum RommMetadataOutcomeKind {
  /// A fill-gaps fetch completed; see the counts for what it wrote.
  filled,

  /// A replace fetch completed.
  replaced,

  /// The server returned no detail for the linked id; nothing was written.
  notFound,

  /// The columns were written but at least one media download failed.
  /// The columns stay; the failed media is logged with its URL.
  partial,

  /// Nothing usable was written; [RommMetadataOutcome.error] says why.
  failed,
}

/// The result of one RomM metadata fetch for one game.
class RommMetadataOutcome {
  final RommMetadataOutcomeKind kind;

  /// Metadata columns written to the row (not counting bookkeeping).
  final int columnsWritten;

  /// Media files written.
  final int mediaWritten;

  /// Media types left alone because a file already existed (fill-gaps only).
  final int mediaSkipped;

  /// Media types whose download or write failed.
  final int mediaFailed;

  /// The failure behind [RommMetadataOutcomeKind.failed], or the first media
  /// failure behind [RommMetadataOutcomeKind.partial].
  final Object? error;

  const RommMetadataOutcome({
    required this.kind,
    this.columnsWritten = 0,
    this.mediaWritten = 0,
    this.mediaSkipped = 0,
    this.mediaFailed = 0,
    this.error,
  });

  const RommMetadataOutcome.notFound()
    : this(kind: RommMetadataOutcomeKind.notFound);

  const RommMetadataOutcome.failed(Object error)
    : this(kind: RommMetadataOutcomeKind.failed, error: error);

  /// True when the fetch left the row with RomM data in it — filled, replaced,
  /// or partial.
  bool get wroteSomething =>
      kind == RommMetadataOutcomeKind.filled ||
      kind == RommMetadataOutcomeKind.replaced ||
      kind == RommMetadataOutcomeKind.partial;

  @override
  String toString() =>
      'RommMetadataOutcome($kind, columns=$columnsWritten, '
      'media=$mediaWritten written/$mediaSkipped skipped/$mediaFailed failed'
      '${error == null ? '' : ', error=$error'})';
}

/// A RomM metadata fetch that could not run to completion, with the stage it
/// failed at and the rom it was for, so a caller can tell a game that is not
/// linked from a server or repository failure.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Error Handling Standards"
class RommMetadataFetchException implements Exception {
  /// `link`, `detail`, `columns`, or `media`.
  final String stage;
  final int? romId;
  final String filename;
  final Object? cause;

  const RommMetadataFetchException({
    required this.stage,
    required this.filename,
    this.romId,
    this.cause,
  });

  /// The game has no `app_romm_rom_map` row, so there is no id to fetch.
  const RommMetadataFetchException.notLinked(String filename)
    : this(stage: 'link', filename: filename);

  bool get isNotLinked => stage == 'link' && cause == null;

  @override
  String toString() =>
      'RomM metadata fetch failed: stage=$stage rom=$romId '
      'filename="$filename"${cause == null ? '' : ' cause=$cause'}';
}
