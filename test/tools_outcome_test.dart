import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/screens/settings_screen/new_settings_options/tools_settings_content.dart';
import 'package:neostation/services/global_notification_service.dart';
import 'package:neostation/services/metadata_cleanup_service.dart';
import 'package:neostation/services/rom_folder_organizer_service.dart';
import 'package:neostation/widgets/custom_notification.dart';

/// The Tools screen's outcomes. A finished tool kept its progress bar in the
/// bell and under the tool (a finished run looked like a running one); an
/// orphan cleanup where some rows failed said it had cleaned them, and one
/// where all failed showed the service's English error; a multi-disc run where
/// every set failed said both that sets failed and that none were found.
void main() {
  group('a finished notification', () {
    final service = GlobalNotificationService();
    setUp(() => service.notifier.value = []);
    tearDown(() => service.notifier.value = []);

    double? progress() => service.notifier.value.single.progress;

    test('drops its progress bar', () {
      service.show(
        id: 'tool',
        message: 'Working',
        progress: 0.4,
        ongoing: true,
      );

      service.update(id: 'tool', message: 'Done');

      expect(progress(), isNull);
    });

    test('a running one keeps its progress when an update has none', () {
      service.show(
        id: 'tool',
        message: 'Working',
        progress: 0.4,
        ongoing: true,
      );

      service.update(id: 'tool', message: 'Still working', ongoing: true);

      expect(progress(), 0.4);
    });
  });

  group('orphan cleanup outcome', () {
    const done = 'Cleaned {entries} entries and {files} files.';
    String outcome(MetadataCleanupResult result) => orphanCleanupOutcome(
      result,
      done: done,
      nothingFound: 'Nothing found.',
      nothingToDelete: 'Nothing to delete.',
      esdeKept: (n) => ' $n kept.',
      notRemoved: (n) => ' $n not removed.',
    ).$1;
    NotificationType type(MetadataCleanupResult result) => orphanCleanupOutcome(
      result,
      done: done,
      nothingFound: 'Nothing found.',
      nothingToDelete: 'Nothing to delete.',
      esdeKept: (n) => ' $n kept.',
      notRemoved: (n) => ' $n not removed.',
    ).$2;

    const a = OrphanedMetadataItem(
      appSystemId: 'psx',
      filename: 'a.chd',
      systemFolderName: 'psx',
      isFullyScraped: true,
      esdeImported: false,
    );
    const e = OrphanedMetadataItem(
      appSystemId: 'psx',
      filename: 'e.chd',
      systemFolderName: 'psx',
      isFullyScraped: true,
      esdeImported: true,
    );

    test('a partial failure says how many were not removed, as an error', () {
      final result = MetadataCleanupResult(
        orphanedItems: const [a, a, a],
        deletedItems: const [a, a],
        deletedMediaFiles: 1,
        errors: const ['Failed to clean metadata for psx/b.chd: locked'],
      );
      expect(outcome(result), 'Cleaned 2 entries and 1 files. 1 not removed.');
      expect(type(result), NotificationType.error);
    });

    test('a total failure says so without the service\'s English', () {
      final result = MetadataCleanupResult(
        orphanedItems: const [a, a],
        errors: const ['Failed to clean metadata for psx/a.chd: locked', 'x'],
      );
      expect(outcome(result), '2 not removed.');
      expect(outcome(result), isNot(contains('Failed to clean metadata')));
      expect(type(result), NotificationType.error);
    });

    test('a partial failure lists the ES-DE note before the failures', () {
      final result = MetadataCleanupResult(
        orphanedItems: const [a, a, e],
        deletedItems: const [a],
        skippedEsdeItems: const [e],
        errors: const ['x'],
      );
      expect(
        outcome(result),
        'Cleaned 1 entries and 0 files. 1 kept. 1 not removed.',
      );
    });

    test('media files alone count as a cleanup', () {
      final result = MetadataCleanupResult(
        orphanedItems: const [a],
        deletedMediaFiles: 2,
      );
      expect(outcome(result), 'Cleaned 0 entries and 2 files.');
      expect(type(result), NotificationType.success);
    });

    test('a clean run is a success, with the ES-DE note', () {
      final result = MetadataCleanupResult(
        orphanedItems: const [a, e],
        deletedItems: const [a],
        skippedEsdeItems: const [e],
      );
      expect(outcome(result), 'Cleaned 1 entries and 0 files. 1 kept.');
      expect(type(result), NotificationType.success);
    });

    test('nothing to clean is information', () {
      expect(outcome(const MetadataCleanupResult()), 'Nothing found.');
      expect(
        outcome(
          const MetadataCleanupResult(
            orphanedItems: [e],
            skippedEsdeItems: [e],
          ),
        ),
        'Nothing to delete. 1 kept.',
      );
      expect(type(const MetadataCleanupResult()), NotificationType.info);
    });
  });

  group('multi-disc organiser outcome', () {
    RomFolderOrganizerResult org({
      int groupsOrganized = 0,
      int? foldersCreated,
      int filesMoved = 0,
      int playlistsCreated = 0,
      int rootsSkipped = 0,
      int groupsFailed = 0,
    }) => RomFolderOrganizerResult(
      groupsOrganized: groupsOrganized,
      foldersCreated: foldersCreated ?? groupsOrganized,
      filesMoved: filesMoved,
      playlistsCreated: playlistsCreated,
      rootsSkipped: rootsSkipped,
      groupsFailed: groupsFailed,
    );
    (String, NotificationType) outcome(RomFolderOrganizerResult result) =>
        multiDiscOutcome(
          result,
          done:
              'Organized {groups} sets, {files} files, {playlists} '
              'playlists{skipped}.',
          noSetsFound: 'No sets found{skipped}.',
          partialFailure: '{failed} sets failed. {result}',
          skippedSuffix: ' ({count} skipped)',
        );

    test('every set failing does not also say none were found', () {
      final (message, type) = outcome(org(groupsFailed: 2));
      expect(message, '2 sets failed.');
      expect(type, NotificationType.error);
    });

    test('every set failing after its folder was made says only that', () {
      // On SAF the folder is created before a move fails.
      final (message, type) = outcome(org(groupsFailed: 2, foldersCreated: 2));
      expect(message, '2 sets failed.');
      expect(type, NotificationType.error);
    });

    test('every set failing keeps the skipped folders note', () {
      final (message, _) = outcome(org(groupsFailed: 2, rootsSkipped: 1));
      expect(message, '2 sets failed. (1 skipped)');
    });

    test('a partial failure keeps what was done', () {
      final (message, type) = outcome(
        org(
          groupsOrganized: 1,
          filesMoved: 2,
          playlistsCreated: 1,
          groupsFailed: 1,
        ),
      );
      expect(message, '1 sets failed. Organized 1 sets, 2 files, 1 playlists.');
      expect(type, NotificationType.error);
    });

    test('nothing found is information, with the skipped folders', () {
      final (message, type) = outcome(org(rootsSkipped: 2));
      expect(message, 'No sets found (2 skipped).');
      expect(type, NotificationType.info);
    });
  });

  group('source', () {
    final tools = File(
      'lib/screens/settings_screen/new_settings_options/'
      'tools_settings_content.dart',
    ).readAsStringSync();

    test('the screen uses the outcome functions', () {
      expect(
        tools,
        contains('(completionMessage, completionType) = orphanCleanupOutcome('),
      );
      expect(
        tools,
        contains('(completionMessage, completionType) = multiDiscOutcome('),
      );
      expect(tools, isNot(contains('result.errors.first')));
    });
  });

  test('the not-removed message is in every language', () {
    for (final map in [
      AppLocale.de,
      AppLocale.en,
      AppLocale.es,
      AppLocale.fr,
      AppLocale.id,
      AppLocale.it,
      AppLocale.ja,
      AppLocale.ko,
      AppLocale.pt,
      AppLocale.ru,
      AppLocale.zh,
      AppLocale.zhHant,
    ]) {
      for (final key in [
        AppLocale.cleanOrphanedMetadataNotRemoved,
        AppLocale.cleanOrphanedMetadataNotRemovedOne,
      ]) {
        final value = map[key];
        expect(value, isA<String>(), reason: key);
        expect(value as String, contains('{count}'), reason: key);
        if (!identical(map, AppLocale.en)) {
          expect(value, isNot(AppLocale.en[key]), reason: key);
        }
        // Appended to another sentence: it brings the language's own
        // separator (none after 。).
        final unspaced =
            identical(map, AppLocale.ja) ||
            identical(map, AppLocale.zh) ||
            identical(map, AppLocale.zhHant);
        expect(value.startsWith(' '), !unspaced, reason: key);
      }
    }
  });

  group('a tool\'s status under its card', () {
    Future<void> pump(WidgetTester tester, GlobalNotificationData data) =>
        tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(640, 480),
            builder: (context, _) => MaterialApp(
              home: Scaffold(body: ToolInlineStatus(notification: data)),
            ),
          ),
        );

    testWidgets('a running tool shows its bar and progress', (tester) async {
      await pump(
        tester,
        const GlobalNotificationData(
          id: 't',
          type: GlobalNotificationType.info,
          message: 'Cleaning a.chd',
          progress: 0.5,
          ongoing: true,
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Cleaning a.chd'), findsOneWidget);
    });

    testWidgets('a finished tool keeps its message, without a bar', (
      tester,
    ) async {
      await pump(
        tester,
        const GlobalNotificationData(
          id: 't',
          type: GlobalNotificationType.info,
          message: 'Cleaned 3 entries.',
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Cleaned 3 entries.'), findsOneWidget);
    });

    testWidgets('a running tool without progress yet shows nothing', (
      tester,
    ) async {
      await pump(
        tester,
        const GlobalNotificationData(
          id: 't',
          type: GlobalNotificationType.info,
          message: 'Starting',
          ongoing: true,
        ),
      );
      expect(find.text('Starting'), findsNothing);
    });
  });
}
