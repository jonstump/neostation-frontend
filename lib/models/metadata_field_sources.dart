import 'dart:convert';

/// Which source last wrote each metadata column of a
/// `user_screenscraper_metadata` row, persisted as JSON in `field_sources`.
///
/// `metadata_source` already records who wrote the *row*, which is the right
/// granularity for "has ScreenScraper ever completed this game" and the wrong
/// one for everything else. A row a RomM fetch created and a ScreenScraper pass
/// later filled the gaps of has two writers, and the column can only name one.
///
/// That matters in two places. A fill-gaps write should be able to say which
/// values are still the other source's, and an upload back to RomM should push
/// what NeoStation learned rather than handing RomM its own values back (#237).
///
/// Stored as one JSON object rather than a column per field: the table already
/// has 21 columns, a per-field scheme would roughly double it, and every new
/// metadata column would then need two columns and another migration. The cost
/// is that it is not SQL-queryable per field — which is acceptable because no
/// query asks per-field questions; the eligibility predicate asks a row-level
/// one and answers it from `metadata_source`.
///
/// Unparseable or absent JSON reads as empty rather than throwing: this is
/// provenance, and losing it must never fail a metadata write.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source Provenance"
class MetadataFieldSources {
  /// The database column this serialises to.
  static const String column = 'field_sources';

  /// Column name to the `dbValue` of the source that last wrote it.
  final Map<String, String> _sources;

  const MetadataFieldSources._(this._sources);

  /// An empty map — nothing known about any field.
  factory MetadataFieldSources.empty() => const MetadataFieldSources._({});

  /// Decodes a stored `field_sources` value.
  ///
  /// Null, blank, malformed JSON, and JSON that is not an object of strings
  /// all read as empty. A partially valid object keeps the entries that are
  /// string-to-string and drops the rest.
  factory MetadataFieldSources.fromDb(Object? value) {
    final text = value?.toString();
    if (text == null || text.trim().isEmpty) {
      return MetadataFieldSources.empty();
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return MetadataFieldSources.empty();
      final out = <String, String>{};
      decoded.forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
      return MetadataFieldSources._(out);
    } on FormatException {
      return MetadataFieldSources.empty();
    }
  }

  /// The source that last wrote [column], or null when unknown.
  String? sourceOf(String column) => _sources[column];

  /// Whether any field is recorded as written by [sourceDbValue].
  bool hasAny(String sourceDbValue) =>
      _sources.values.any((s) => s == sourceDbValue);

  /// The columns recorded as written by [sourceDbValue].
  Set<String> fieldsFrom(String sourceDbValue) => {
    for (final e in _sources.entries)
      if (e.value == sourceDbValue) e.key,
  };

  /// A copy with [columns] attributed to [sourceDbValue].
  ///
  /// Last writer wins per field, which is what makes this usable from a
  /// fill-gaps write: the columns it actually wrote move to the new source and
  /// every other field keeps whoever wrote it.
  MetadataFieldSources withWrites(
    Iterable<String> columns,
    String sourceDbValue,
  ) {
    if (columns.isEmpty) return this;
    return MetadataFieldSources._({
      ..._sources,
      for (final c in columns) c: sourceDbValue,
    });
  }

  /// Whether anything is recorded.
  bool get isEmpty => _sources.isEmpty;

  /// An unmodifiable view, for tests and callers that want the whole map.
  Map<String, String> get asMap => Map.unmodifiable(_sources);

  /// The value to store in [column], or null when nothing is recorded — a null
  /// column is the honest representation of "no provenance known" and keeps
  /// rows written before this existed indistinguishable from rows that learned
  /// nothing.
  String? toDb() => _sources.isEmpty ? null : jsonEncode(_sources);

  @override
  String toString() => 'MetadataFieldSources(${toDb() ?? '{}'})';
}
