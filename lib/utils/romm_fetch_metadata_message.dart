import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_metadata_fetch.dart';

/// How a fetch-outcome notification should read: a success, a neutral note,
/// or an error. Mapped onto the notification widget's own type by the caller
/// so this file stays free of widget imports.
enum RommFetchMetadataTone { success, info, error }

/// The localized notification for one [RommMetadataOutcome]: the `AppLocale`
/// key, the placeholder values to substitute into it, and its tone.
class RommFetchMetadataMessage {
  final String key;
  final Map<String, String> placeholders;
  final RommFetchMetadataTone tone;

  const RommFetchMetadataMessage({
    required this.key,
    this.placeholders = const {},
    required this.tone,
  });

  /// Resolves [key] through [t] and substitutes every placeholder.
  String format(String Function(String key) t) {
    var text = t(key);
    for (final entry in placeholders.entries) {
      text = text.replaceFirst('{${entry.key}}', entry.value);
    }
    return text;
  }
}

/// Picks the notification for [outcome].
///
/// A fill-gaps fetch that wrote nothing is reported as "nothing to fill"
/// rather than "filled 0", since the user asked for gaps and there were none;
/// a replace always reports its counts. A partial outcome names the columns
/// that were written and the artwork that was not, so the user knows the
/// text is there but a picture is missing. Pure so the choice is testable
/// without widgets.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-Game Fetch Action"
RommFetchMetadataMessage rommFetchMetadataMessageFor(
  RommMetadataOutcome outcome,
) {
  final counts = {
    'count': '${outcome.columnsWritten}',
    'media': '${outcome.mediaWritten}',
  };
  switch (outcome.kind) {
    case RommMetadataOutcomeKind.filled:
      if (outcome.columnsWritten == 0 && outcome.mediaWritten == 0) {
        return const RommFetchMetadataMessage(
          key: AppLocale.rommFetchMetadataNothingToFill,
          tone: RommFetchMetadataTone.info,
        );
      }
      return RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataFilled,
        placeholders: counts,
        tone: RommFetchMetadataTone.success,
      );
    case RommMetadataOutcomeKind.replaced:
      return RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataReplaced,
        placeholders: counts,
        tone: RommFetchMetadataTone.success,
      );
    case RommMetadataOutcomeKind.notFound:
      return const RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataNotFound,
        tone: RommFetchMetadataTone.error,
      );
    case RommMetadataOutcomeKind.partial:
      return RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataPartial,
        placeholders: {
          'count': '${outcome.columnsWritten}',
          'media': '${outcome.mediaFailed}',
        },
        tone: RommFetchMetadataTone.info,
      );
    case RommMetadataOutcomeKind.failed:
      return const RommFetchMetadataMessage(
        key: AppLocale.rommFetchMetadataFailed,
        tone: RommFetchMetadataTone.error,
      );
  }
}
