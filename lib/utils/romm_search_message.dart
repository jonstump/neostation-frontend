import 'package:neostation/l10n/app_locale.dart';

/// The line drawn under the RomM in-platform search field: the `AppLocale`
/// key and the placeholder values to substitute into it. Free of widget
/// imports so the choice is testable on its own.
class RommSearchMessage {
  final String key;
  final Map<String, String> placeholders;

  const RommSearchMessage({required this.key, this.placeholders = const {}});

  /// Resolves [key] through [t] and substitutes every placeholder.
  String format(String Function(String key) t) {
    var text = t(key);
    for (final entry in placeholders.entries) {
      text = text.replaceFirst('{${entry.key}}', entry.value);
    }
    return text;
  }
}

/// Picks the result line for a scoped RomM search.
///
/// Nothing is said while the field is empty — the grid is the unfiltered
/// platform and needs no caption — or while the first page of a search is
/// still loading, when "no results" would only be a flash of the wrong
/// answer. Otherwise the line reports the loaded count, marks it as a lower
/// bound (`{count}+`) while the server has more pages, or says that nothing
/// matched the term.
// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "In-Platform Search Field", REQ "Localized User-Facing Text"
RommSearchMessage? rommSearchMessageFor({
  required String term,
  required int count,
  required bool hasMore,
  required bool loading,
}) {
  final trimmed = term.trim();
  if (trimmed.isEmpty) return null;
  if (count == 0) {
    if (loading) return null;
    return RommSearchMessage(
      key: AppLocale.rommSearchNoResults,
      placeholders: {'term': trimmed},
    );
  }
  if (hasMore) {
    return RommSearchMessage(
      key: AppLocale.rommSearchResultCountMore,
      placeholders: {'count': '$count'},
    );
  }
  if (count == 1) {
    return const RommSearchMessage(key: AppLocale.rommSearchResultCountOne);
  }
  return RommSearchMessage(
    key: AppLocale.rommSearchResultCount,
    placeholders: {'count': '$count'},
  );
}
