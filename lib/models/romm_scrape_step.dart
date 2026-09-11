import 'package:flutter/foundation.dart';

import 'romm_metadata_fetch.dart';

/// One game a scrape entry point asks the RomM step about.
///
/// The step keys the game the way `app_romm_rom_map` is keyed: the on-disk
/// [filename] with its extension (`user_roms.filename`) within the system's
/// canonical [systemFolder]. [appSystemId] is the `app_systems` id the
/// metadata row is filed under, and [forceOverwrite] is the scrape's own
/// overwrite flag, mapped onto the writer's mode by
/// [RommScrapeStepResult.modeFor].
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "RomM Scrape Step"
@immutable
class RommScrapeTarget {
  final String appSystemId;
  final String filename;
  final String systemFolder;
  final bool forceOverwrite;

  const RommScrapeTarget({
    required this.appSystemId,
    required this.filename,
    required this.systemFolder,
    this.forceOverwrite = false,
  });

  @override
  bool operator ==(Object other) =>
      other is RommScrapeTarget &&
      other.appSystemId == appSystemId &&
      other.filename == filename &&
      other.systemFolder == systemFolder &&
      other.forceOverwrite == forceOverwrite;

  @override
  int get hashCode =>
      Object.hash(appSystemId, filename, systemFolder, forceOverwrite);

  @override
  String toString() =>
      'RommScrapeTarget($systemFolder/$filename, system=$appSystemId, '
      'overwrite=$forceOverwrite)';
}

/// What the RomM step did for one target. Only [scraped] stops the chain;
/// every other status falls through to ScreenScraper.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "RomM Scrape Step"
enum RommScrapeStepStatus {
  /// RomM wrote at least one column or media file.
  scraped,

  /// The fetch completed and wrote nothing because every media file RomM
  /// carries was already on disk. The row holds everything RomM offers, which
  /// is not everything the row needs: a RomM fetch fills only the columns RomM
  /// carries, so the game falls through to ScreenScraper for the rest (#233).
  /// With no ScreenScraper to fall through to, the game counts as handled
  /// rather than failed.
  alreadyComplete,

  /// The game has no `app_romm_rom_map` row; no request was made.
  notLinked,

  /// The server returned no detail for the linked id.
  notFound,

  /// The game is linked and the server answered, but nothing was written and
  /// nothing was already there to skip — RomM has nothing for this game.
  empty,

  /// The request or the write failed; see [RommScrapeStepResult.error].
  failed,
}

/// The result of one RomM scrape step.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "RomM Scrape Step"
@immutable
class RommScrapeStepResult {
  final RommScrapeStepStatus status;

  /// The writer's outcome when the step got as far as running it.
  final RommMetadataOutcome? outcome;

  /// The failure behind [RommScrapeStepStatus.failed], or the outcome's own
  /// error when it carries one.
  final Object? error;

  const RommScrapeStepResult({required this.status, this.outcome, this.error});

  const RommScrapeStepResult.notLinked()
    : this(status: RommScrapeStepStatus.notLinked);

  const RommScrapeStepResult.failed(Object error)
    : this(status: RommScrapeStepStatus.failed, error: error);

  /// The result for a writer outcome, classified by [classifyOutcome].
  RommScrapeStepResult.fromOutcome(RommMetadataOutcome outcome)
    : this(
        status: classifyOutcome(outcome),
        outcome: outcome,
        error: outcome.error,
      );

  /// True when RomM handled the game and ScreenScraper must not run.
  bool get scraped => status == RommScrapeStepStatus.scraped;

  /// The one definition of "RomM scraped this game".
  ///
  /// A completed fetch (filled, replaced, or partial) is [scraped] only when
  /// it wrote at least one column or media file. A completed fetch that wrote
  /// nothing because every media file already existed and none failed is
  /// [RommScrapeStepStatus.alreadyComplete]: the row holds everything RomM
  /// offers and RomM has nothing left to give, which is not the same claim as
  /// "this row is fully scraped" — RomM fills only the columns it carries, so
  /// the game is offered onward to ScreenScraper for the rest (#233). That
  /// makes the chain agree with the `new_only` predicate, which offers a row
  /// whose `metadata_source` is not `screenscraper`; classifying this case as
  /// [scraped] terminated the chain at RomM and the offered row went nowhere.
  /// A completed fetch that wrote nothing with nothing to skip is
  /// [RommScrapeStepStatus.empty]; not found and failed map to their own
  /// statuses. All of those fall through to ScreenScraper.
  // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Scrape Success Rule"
  static RommScrapeStepStatus classifyOutcome(RommMetadataOutcome outcome) {
    switch (outcome.kind) {
      case RommMetadataOutcomeKind.filled:
      case RommMetadataOutcomeKind.replaced:
      case RommMetadataOutcomeKind.partial:
        if (outcome.columnsWritten + outcome.mediaWritten > 0) {
          return RommScrapeStepStatus.scraped;
        }
        if (outcome.mediaSkipped > 0 && outcome.mediaFailed == 0) {
          return RommScrapeStepStatus.alreadyComplete;
        }
        return RommScrapeStepStatus.empty;
      case RommMetadataOutcomeKind.notFound:
        return RommScrapeStepStatus.notFound;
      case RommMetadataOutcomeKind.failed:
        return RommScrapeStepStatus.failed;
    }
  }

  /// The writer mode for a scrape's overwrite flag: overwrite replaces,
  /// otherwise only the gaps are filled. ScreenScraper's own handling of the
  /// flag is untouched by this.
  // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Overwrite Mode Mapping"
  static RommMetadataMode modeFor(bool forceOverwrite) =>
      forceOverwrite ? RommMetadataMode.replace : RommMetadataMode.fillGaps;

  @override
  String toString() =>
      'RommScrapeStepResult($status'
      '${outcome == null ? '' : ', $outcome'}'
      '${error == null ? '' : ', error=$error'})';
}

/// The RomM half of a scrape, injected into `ScreenScraperService` so the
/// service never imports a provider. `RommProvider.scrapeStep` builds one when
/// connected; a null step means "RomM is not available, run ScreenScraper as
/// before". A step never throws — every failure is a
/// [RommScrapeStepStatus.failed] result.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "RomM Scrape Step"
typedef RommScrapeStep =
    Future<RommScrapeStepResult> Function(RommScrapeTarget target);
