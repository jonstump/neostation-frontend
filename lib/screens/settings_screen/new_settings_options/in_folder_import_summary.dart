import 'package:neostation/services/esde_import_service.dart';

/// Which headline the directories settings shows for a finished in-folder
/// (ROM folder) import.
enum InFolderSummaryKind {
  /// Nothing was imported and at least one ROM folder was skipped because it
  /// is a SAF tree with no readable real path. That, not a missing gamelist,
  /// explains the empty result, so it is reported first.
  foldersSkippedSaf,

  /// No readable ROM folder held a `<system>/gamelist.xml` and no media-only
  /// system was linked. Distinct from the ES-DE "not an ES-DE folder" outcome.
  noGamelistsFound,

  /// Show the per-count summary (which itself lists any skipped folders).
  counts,
}

/// Decides how an in-folder import result is worded. Pure so the branching
/// can be unit-tested without the settings screen.
///
/// When every folder is SAF-skipped the service also reports
/// `noInFolderGamelistsFound == true` (and `gamelistsDirFound` stays true), so
/// the SAF check must come before the "no gamelists" wording.
// Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Import Entry Point and Results"
InFolderSummaryKind inFolderSummaryKind(EsdeImportResult result) {
  if (result.mode != GamelistSourceMode.inFolder) {
    return InFolderSummaryKind.counts;
  }
  final nothingImported =
      result.gamesImported == 0 &&
      result.systemsMatched == 0 &&
      result.mediaOnlyLinked == 0;
  if (nothingImported && result.foldersSkippedSaf > 0) {
    return InFolderSummaryKind.foldersSkippedSaf;
  }
  if (nothingImported && result.noInFolderGamelistsFound) {
    return InFolderSummaryKind.noGamelistsFound;
  }
  return InFolderSummaryKind.counts;
}
