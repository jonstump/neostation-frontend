import 'package:neostation/services/esde_import_service.dart';

/// Which headline the directories settings shows for a finished in-folder
/// (ROM folder) import.
enum InFolderSummaryKind {
  /// The run never started: another import was still in progress.
  refusedAlreadyRunning,

  /// The user stopped the run between files. Whatever was imported or
  /// mirrored before the stop is kept, so the counts are still shown under
  /// the cancelled headline.
  cancelled,

  /// Nothing was imported and at least one ROM folder was skipped because it
  /// is a SAF tree with no readable real path. That, not a missing gamelist,
  /// explains the empty result, so it is reported first.
  foldersSkippedSaf,

  /// No readable ROM folder held a `<system>/gamelist.xml` and no media-only
  /// system was linked. Distinct from the ES-DE "not an ES-DE folder" outcome.
  noGamelistsFound,

  /// The SAF media mirror was refused for want of free space and nothing was
  /// mirrored at all this run. Metadata still imported, so the counts follow
  /// the budget headline.
  budgetRefused,

  /// Show the per-count summary (which itself lists any skipped folders, the
  /// SAF mirror tallies, and a budget line when a later system was refused).
  counts,
}

/// Decides how an in-folder import result is worded. Pure so the branching
/// can be unit-tested without the settings screen.
///
/// Order matters: a refused start says nothing about the folders, and a
/// cancel explains any partial result, so both come before the empty-result
/// reasons. When every folder is SAF-skipped the service also reports
/// `noInFolderGamelistsFound == true` (and `gamelistsDirFound` stays true), so
/// the SAF check must come before the "no gamelists" wording. A budget
/// refusal with nothing mirrored gets its own headline; one that came after
/// some systems were mirrored is a line inside the counts instead.
// Governing: ADR-0002 (in-folder gamelist import), SPEC-0002 REQ "Import Entry Point and Results"
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
InFolderSummaryKind inFolderSummaryKind(EsdeImportResult result) {
  if (result.mode != GamelistSourceMode.inFolder) {
    return InFolderSummaryKind.counts;
  }
  if (result.refusedAlreadyRunning) {
    return InFolderSummaryKind.refusedAlreadyRunning;
  }
  if (result.cancelled) {
    return InFolderSummaryKind.cancelled;
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
  if (result.safBudgetRefused &&
      result.safFilesCopied == 0 &&
      result.safSystemsMirrored == 0) {
    return InFolderSummaryKind.budgetRefused;
  }
  return InFolderSummaryKind.counts;
}

/// Whether the result carries anything from the SAF mirror worth a line in
/// the summary: a folder that went over SAF, or any mirror tally.
// Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
bool inFolderResultHasSafActivity(EsdeImportResult result) =>
    result.folderOutcomes.any((o) => o.kind == EsdeImportPathKind.saf) ||
    result.safSystemsMirrored > 0 ||
    result.safFilesCopied > 0 ||
    result.safFilesSkippedUnchanged > 0 ||
    result.safFilesFailed > 0 ||
    result.safSystemsListingFailed > 0 ||
    result.safBudgetRefused;
