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
  });
}
