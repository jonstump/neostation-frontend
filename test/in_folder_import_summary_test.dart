import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/in_folder_import_summary.dart';
import 'package:neostation/services/esde_import_service.dart';

void main() {
  group('inFolderSummaryKind', () {
    test('all folders SAF-skipped wins over "no gamelists" wording', () {
      // The service reports noInFolderGamelistsFound (and gamelistsDirFound)
      // when every folder was skipped; the SAF reason must be shown instead.
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        foldersSkippedSaf: 2,
        noInFolderGamelistsFound: true,
        gamelistsDirFound: true,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.foldersSkippedSaf);
    });

    test('readable folders with no gamelist.xml report no gamelists', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        noInFolderGamelistsFound: true,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.noGamelistsFound);
    });

    test('a skipped folder next to an import that matched shows counts', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        foldersSkippedSaf: 1,
        systemsFound: 1,
        systemsMatched: 1,
        gamesImported: 3,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
    });

    test('media-only linking counts as an import', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        noInFolderGamelistsFound: true,
        foldersSkippedSaf: 1,
        mediaOnlyLinked: 1,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
    });

    test('gamelists found but nothing matched still shows counts', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        systemsFound: 2,
        systemsUnmatched: 2,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
    });

    test('ES-DE root results are never reworded', () {
      const r = EsdeImportResult(
        foldersSkippedSaf: 1,
        gamelistsDirFound: false,
      );
      expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
    });

    // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
    group('SAF mirror kinds', () {
      test('a refused start is reported before anything else', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          refusedAlreadyRunning: true,
          noInFolderGamelistsFound: true,
          foldersSkippedSaf: 1,
        );
        expect(
          inFolderSummaryKind(r),
          InFolderSummaryKind.refusedAlreadyRunning,
        );
      });

      test('an ES-DE root refusal keeps the ES-DE wording', () {
        const r = EsdeImportResult(refusedAlreadyRunning: true);
        expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
      });

      test('a cancelled run is reported even when it imported', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          cancelled: true,
          systemsFound: 1,
          systemsMatched: 1,
          gamesImported: 5,
          safFilesCopied: 100,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.cancelled);
      });

      test('a cancel explains an otherwise empty result', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          cancelled: true,
          noInFolderGamelistsFound: true,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.cancelled);
      });

      test('a budget refusal with nothing mirrored gets its own headline', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          systemsFound: 1,
          systemsMatched: 1,
          gamesImported: 3,
          safBudgetRefused: true,
          safBudgetRequiredBytes: 5000,
          safBudgetAvailableBytes: 10,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.budgetRefused);
      });

      test('a budget refusal after some systems mirrored shows counts', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          systemsFound: 2,
          systemsMatched: 2,
          gamesImported: 3,
          safSystemsMirrored: 1,
          safFilesCopied: 280,
          safFilesSkippedUnchanged: 20,
          safBudgetRefused: true,
          safBudgetRequiredBytes: 5000,
          safBudgetAvailableBytes: 10,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
      });

      test('all-SAF-skipped still wins over a budget refusal', () {
        // A refusal cannot happen without discovery, but the ordering must
        // hold if both flags are ever set: the empty result is explained
        // by the skipped folders.
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          foldersSkippedSaf: 1,
          noInFolderGamelistsFound: true,
          safBudgetRefused: true,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.foldersSkippedSaf);
      });

      test('a SAF mirror with copies and skips shows counts', () {
        const r = EsdeImportResult(
          mode: GamelistSourceMode.inFolder,
          systemsFound: 1,
          systemsMatched: 1,
          gamesImported: 3,
          safSystemsMirrored: 1,
          safFilesCopied: 280,
          safFilesSkippedUnchanged: 20,
          safBytesCopied: 1234567,
        );
        expect(inFolderSummaryKind(r), InFolderSummaryKind.counts);
        expect(inFolderResultHasSafActivity(r), isTrue);
      });
    });
  });

  // Governing: ADR-0003 (SAF mirror import), SPEC-0003 REQ "Result Reporting"
  group('inFolderResultHasSafActivity', () {
    test('a real-path-only run has no SAF lines', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        systemsFound: 1,
        systemsMatched: 1,
        gamesImported: 3,
        folderOutcomes: [
          EsdeImportFolderOutcome(
            folder: '/roms',
            kind: EsdeImportPathKind.real,
          ),
        ],
      );
      expect(inFolderResultHasSafActivity(r), isFalse);
    });

    test('a folder that went over SAF shows the SAF lines even at zero', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        systemsFound: 1,
        systemsMatched: 1,
        gamesImported: 3,
        folderOutcomes: [
          EsdeImportFolderOutcome(
            folder: 'content://tree',
            kind: EsdeImportPathKind.saf,
          ),
        ],
      );
      expect(inFolderResultHasSafActivity(r), isTrue);
    });

    test('a skipped SAF folder alone is not mirror activity', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        foldersSkippedSaf: 1,
        folderOutcomes: [
          EsdeImportFolderOutcome(
            folder: 'content://tree',
            kind: EsdeImportPathKind.skippedSaf,
          ),
        ],
      );
      expect(inFolderResultHasSafActivity(r), isFalse);
    });

    test('an unreadable SAF system folder counts as activity', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        safSystemsListingFailed: 1,
      );
      expect(inFolderResultHasSafActivity(r), isTrue);
    });

    test('a budget refusal counts as activity', () {
      const r = EsdeImportResult(
        mode: GamelistSourceMode.inFolder,
        safBudgetRefused: true,
      );
      expect(inFolderResultHasSafActivity(r), isTrue);
    });
  });
}
