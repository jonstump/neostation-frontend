import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm/romm_collection_mirror.dart';

/// The sentence the sync outcome toast adds about the mirrored local
/// collection: an `AppLocale` key plus the verbatim values for its
/// placeholders, kept apart from `BuildContext` so the mapping is testable.
class RommCollectionSyncMessage {
  /// `AppLocale` key of the sentence.
  final String key;

  /// Verbatim substitutions for the `{placeholder}` tokens in [key].
  final Map<String, String> placeholders;

  const RommCollectionSyncMessage({
    required this.key,
    this.placeholders = const {},
  });

  /// Resolves [key] through [t] and fills the placeholders.
  String format(String Function(String key) t) {
    var text = t(key);
    for (final entry in placeholders.entries) {
      text = text.replaceFirst('{${entry.key}}', entry.value);
    }
    return text;
  }
}

/// The outcome sentence for a collection sync, or null when there is nothing
/// to say: no mirror ran ([summary] is null), or it stopped before writing
/// membership without failing (a disconnect mid-run).
///
/// Created and updated read the same — both say how many games the local
/// collection now holds ([RommCollectionMirrorSummary.members]); a failed run
/// says the collection could not be updated. [name] is the RomM collection's
/// name, which is also the local collection's name at creation.
// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Sync Dialog And Outcome"
RommCollectionSyncMessage? rommCollectionOutcomeMessage(
  RommCollectionMirrorSummary? summary, {
  required String name,
}) {
  if (summary == null) return null;
  if (summary.failed) {
    return RommCollectionSyncMessage(
      key: AppLocale.rommSyncOutcomeCollectionFailed,
      placeholders: {'name': name},
    );
  }
  if (!summary.wroteMembership) return null;
  return RommCollectionSyncMessage(
    key: AppLocale.rommSyncOutcomeCollection,
    placeholders: {'name': name, 'count': '${summary.members}'},
  );
}
