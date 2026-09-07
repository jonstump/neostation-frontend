/// The boolean filters RomM's `GET /api/roms` accepts, as a value object.
///
/// Pure data: no Flutter, no HTTP, no logging. [RommService.getRomsPage] turns
/// a set field into the query parameter of the same snake_case name; an unset
/// (null) field sends nothing, which is *not* the same as sending `false` —
/// `favorite=false` asks RomM for the ROMs that are explicitly not favourites,
/// while omitting it asks for all of them.
// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
// SPEC-0018 REQ "Filter Parameters"
library;

/// One toggleable filter, paired with the query parameter it becomes.
///
/// Enumerated (rather than left as seven booleans) so the filter menu, the
/// chip row and the query builder all walk the same list in the same order —
/// adding a filter is one entry here plus its label key.
// Governing: ADR-0019, SPEC-0018 REQ "Filter Menu And Chips"
enum RommRomFilter {
  favorite('favorite'),
  hasSaves('has_saves'),
  hasStates('has_states'),
  hasRa('has_ra'),
  playable('playable'),
  duplicate('duplicate'),
  missing('missing');

  const RommRomFilter(this.param);

  /// RomM's query-parameter name for this filter.
  final String param;
}

/// An immutable set of RomM ROM filters, each tri-state: on, off, or unset.
///
/// The browse screen only ever sets a filter to `true` or clears it — "with
/// saves" means "show me the ones that have saves", never "show me the ones
/// that don't" — but the model keeps the full tri-state because the query
/// parameters do, and a caller that wants the negative should not have to
/// route around the model.
// Governing: ADR-0019, SPEC-0018 REQ "Filter Parameters"
class RommRomFilters {
  final bool? favorite;
  final bool? hasSaves;
  final bool? hasStates;
  final bool? hasRa;
  final bool? playable;
  final bool? duplicate;
  final bool? missing;

  const RommRomFilters({
    this.favorite,
    this.hasSaves,
    this.hasStates,
    this.hasRa,
    this.playable,
    this.duplicate,
    this.missing,
  });

  /// Nothing set: every query goes out exactly as it did before SPEC-0018.
  static const RommRomFilters none = RommRomFilters();

  /// The value of [filter], or null when it is unset.
  bool? operator [](RommRomFilter filter) {
    switch (filter) {
      case RommRomFilter.favorite:
        return favorite;
      case RommRomFilter.hasSaves:
        return hasSaves;
      case RommRomFilter.hasStates:
        return hasStates;
      case RommRomFilter.hasRa:
        return hasRa;
      case RommRomFilter.playable:
        return playable;
      case RommRomFilter.duplicate:
        return duplicate;
      case RommRomFilter.missing:
        return missing;
    }
  }

  /// A copy with [filter] set to [value], or cleared when [value] is null.
  RommRomFilters withFilter(RommRomFilter filter, bool? value) {
    return RommRomFilters(
      favorite: filter == RommRomFilter.favorite ? value : favorite,
      hasSaves: filter == RommRomFilter.hasSaves ? value : hasSaves,
      hasStates: filter == RommRomFilter.hasStates ? value : hasStates,
      hasRa: filter == RommRomFilter.hasRa ? value : hasRa,
      playable: filter == RommRomFilter.playable ? value : playable,
      duplicate: filter == RommRomFilter.duplicate ? value : duplicate,
      missing: filter == RommRomFilter.missing ? value : missing,
    );
  }

  /// A copy with [filter] flipped between "on" and "unset" — the only two
  /// states the browse menu offers, since the negative reads as a different
  /// question than the one the user asked.
  RommRomFilters toggled(RommRomFilter filter) =>
      withFilter(filter, this[filter] == true ? null : true);

  /// The filters that are set, in enum order — the chip row's contents.
  List<RommRomFilter> get active => [
    for (final filter in RommRomFilter.values)
      if (this[filter] != null) filter,
  ];

  bool get isEmpty => active.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// The set filters as query parameters. Unset filters contribute nothing.
  // Governing: ADR-0019, SPEC-0018 REQ "Filter Parameters"
  Map<String, String> toQueryParameters() => {
    for (final filter in RommRomFilter.values)
      if (this[filter] != null) filter.param: '${this[filter]}',
  };

  @override
  bool operator ==(Object other) =>
      other is RommRomFilters &&
      other.favorite == favorite &&
      other.hasSaves == hasSaves &&
      other.hasStates == hasStates &&
      other.hasRa == hasRa &&
      other.playable == playable &&
      other.duplicate == duplicate &&
      other.missing == missing;

  @override
  int get hashCode => Object.hash(
    favorite,
    hasSaves,
    hasStates,
    hasRa,
    playable,
    duplicate,
    missing,
  );

  @override
  String toString() => 'RommRomFilters(${toQueryParameters()})';
}
