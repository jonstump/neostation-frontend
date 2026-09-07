import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/bios_destination_service.dart';

/// [BiosDestinationService] precedence: the explicitly chosen `bios_directory`
/// first, RetroArch's `system_directory` second, nothing third — plus the
/// Android SAF translation both candidates go through.
///
/// The order was the other way round until the SPEC-0012 amendment: with the
/// discovered default winning, a folder the user picked in the panel was
/// dropped on the next open, so there was no way to move BIOS files off
/// whatever `retroarch.cfg` happened to name.
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "BIOS Destination"
void main() {
  const psx = SystemModel(
    id: 'psx',
    folderName: 'psx',
    realName: 'PlayStation',
    iconImage: '',
    color: '#000000',
    folders: ['psx'],
  );

  /// Builds a service whose collaborators are scripted: [retroArch] and
  /// [stored] are the two candidates, [existing] the directories that are on
  /// disk, [unwritable] those of them that exist but reject a write (Android
  /// without All Files Access), and [written] collects what would be persisted.
  /// [probed] collects every directory the writability probe was asked about,
  /// which is how the "existence before writability" ordering is pinned: the
  /// real probe *creates* the directory it is handed, so a candidate that is
  /// not on disk must never reach it.
  BiosDestinationService svc({
    String? retroArch,
    String? stored,
    Set<String> existing = const {},
    Set<String> unwritable = const {},
    List<String>? written,
    List<String>? probed,
  }) => BiosDestinationService(
    retroArchSystemDirectory: () async => retroArch,
    storedBiosDirectory: () async => stored,
    persistBiosDirectory: (d) async => written?.add(d),
    directoryExists: (d) async => existing.contains(d),
    directoryIsWritable: (d) async {
      probed?.add(d);
      return !unwritable.contains(d);
    },
  );

  group('resolve', () {
    test('prefers the folder the user chose over RetroArch', () async {
      // Governing: SPEC-0012 REQ "BIOS Destination" scenario "An explicit
      // choice outranks RetroArch". The chosen folder is the only signal that
      // says where *this user* wants BIOS files; a discovered default must not
      // silently overrule it on the next open.
      final dir = await svc(
        retroArch: '/home/deck/.config/retroarch/system',
        stored: '/roms/bios',
        existing: {'/home/deck/.config/retroarch/system', '/roms/bios'},
      ).resolve(psx);

      expect(dir, '/roms/bios');
    });

    test('uses the RetroArch system directory when nothing is chosen', () async {
      // Governing: SPEC-0012 REQ "BIOS Destination" scenario "RetroArch known,
      // nothing chosen".
      final dir = await svc(
        retroArch: '/home/deck/.config/retroarch/system',
        existing: {'/home/deck/.config/retroarch/system'},
      ).resolve(psx);

      expect(dir, '/home/deck/.config/retroarch/system');
    });

    test('falls back to RetroArch when the chosen folder is gone', () async {
      final dir = await svc(
        retroArch: '/home/deck/.config/retroarch/system',
        stored: '/gone/bios',
        existing: {'/home/deck/.config/retroarch/system'},
      ).resolve(psx);

      expect(dir, '/home/deck/.config/retroarch/system');
    });

    test('is nothing when the RetroArch directory does not exist', () async {
      expect(await svc(retroArch: '/gone/system').resolve(psx), isNull);
    });

    test('returns null when neither candidate is usable', () async {
      expect(await svc().resolve(psx), isNull);
      expect(
        await svc(retroArch: '/gone', stored: '/also-gone').resolve(psx),
        isNull,
      );
    });

    test('translates a SAF tree URI on the configured folder', () async {
      final dir = await svc(
        stored:
            'content://com.android.externalstorage.documents/tree/primary%3Aemu%2Fbios',
        existing: {'/storage/emulated/0/emu/bios'},
      ).resolve(psx);

      expect(dir, '/storage/emulated/0/emu/bios');
    });

    test('returns null for a SAF URI that cannot be mapped', () async {
      final dir = await svc(
        stored: 'content://com.example.provider/tree/whatever',
        existing: {'/storage/emulated/0/emu/bios'},
      ).resolve(psx);

      expect(dir, isNull);
    });

    test('normalizes the resolved path', () async {
      final dir = await svc(
        retroArch: '/roms/bios/',
        existing: {'/roms/bios'},
      ).resolve(psx);

      expect(dir, '/roms/bios');
    });

    test('skips a chosen folder that exists but cannot be written to', () async {
      // Governing: ADR-0012, SPEC-0012 REQ "BIOS Destination" — both
      // candidates must be *writable*, not merely present. Android without All
      // Files Access hands back exactly this: a readable, unwritable folder
      // whose failure would otherwise appear at the first byte.
      final dir = await svc(
        retroArch: '/storage/emulated/0/RetroArch/system',
        stored: '/roms/bios',
        existing: {'/storage/emulated/0/RetroArch/system', '/roms/bios'},
        unwritable: {'/roms/bios'},
      ).resolve(psx);

      expect(dir, '/storage/emulated/0/RetroArch/system');
    });

    test('skips a RetroArch directory that cannot be written to', () async {
      final dir = await svc(
        retroArch: '/storage/emulated/0/RetroArch/system',
        existing: {'/storage/emulated/0/RetroArch/system'},
        unwritable: {'/storage/emulated/0/RetroArch/system'},
      ).resolve(psx);

      expect(dir, isNull);
    });

    test('never probes a candidate that is not on disk', () async {
      // The real probe calls `Directory.create(recursive: true)`, so probing
      // before checking existence would recreate a BIOS folder the user
      // deleted (or one on an unmounted card) instead of falling through to
      // RetroArch. Swapping the two candidates did not change that: existence
      // is still asked first, for each of them in turn.
      final probed = <String>[];
      final dir = await svc(
        retroArch: '/ra/system',
        stored: '/gone/bios',
        existing: {'/ra/system'},
        probed: probed,
      ).resolve(psx);

      expect(dir, '/ra/system');
      expect(probed, ['/ra/system']);
    });

    test('returns null when every candidate is read-only', () async {
      final dir = await svc(
        retroArch: '/ra/system',
        stored: '/roms/bios',
        existing: {'/ra/system', '/roms/bios'},
        unwritable: {'/ra/system', '/roms/bios'},
      ).resolve(psx);

      expect(dir, isNull);
    });
  });

  group('resolveDestination', () {
    test('names RetroArch as the source when nothing is chosen', () async {
      // The panel always offers the picker, so the source is what lets it say
      // whether the path on screen is the user's choice or a default the app
      // discovered.
      final resolved = await svc(
        retroArch: '/ra/system',
        existing: {'/ra/system'},
      ).resolveDestination(psx);

      expect(resolved?.directory, '/ra/system');
      expect(resolved?.source, BiosDestinationSource.retroArch);
    });

    test('names the configured folder even when RetroArch has one', () async {
      final resolved = await svc(
        retroArch: '/ra/system',
        stored: '/roms/bios',
        existing: {'/ra/system', '/roms/bios'},
      ).resolveDestination(psx);

      expect(resolved?.directory, '/roms/bios');
      expect(resolved?.source, BiosDestinationSource.configured);
    });

    test('is null when neither candidate is usable', () async {
      expect(await svc().resolveDestination(psx), isNull);
    });
  });

  group('setBiosDirectory', () {
    test('stores the picked path verbatim and returns the real path', () async {
      final written = <String>[];

      final real = await svc(written: written).setBiosDirectory('/roms/bios');

      expect(real, '/roms/bios');
      expect(written, ['/roms/bios']);
    });

    test('stores the SAF URI, not its translation', () async {
      final written = <String>[];
      const uri =
          'content://com.android.externalstorage.documents/tree/primary%3Aemu%2Fbios';

      final real = await svc(written: written).setBiosDirectory(uri);

      expect(real, '/storage/emulated/0/emu/bios');
      expect(written, [uri]);
    });

    test('persists nothing when the SAF URI cannot be mapped', () async {
      final written = <String>[];

      final real = await svc(
        written: written,
      ).setBiosDirectory('content://com.example.provider/tree/x');

      expect(real, isNull);
      expect(written, isEmpty);
    });

    test('persists nothing for a blank choice', () async {
      final written = <String>[];

      expect(await svc(written: written).setBiosDirectory('   '), isNull);
      expect(written, isEmpty);
    });
  });

  group('realPathFor', () {
    test('passes a plain path through', () {
      expect(BiosDestinationService.realPathFor('/roms/bios'), '/roms/bios');
      expect(
        BiosDestinationService.realPathFor(r'D:\roms\bios'),
        r'D:\roms\bios',
      );
    });

    test('maps a removable-volume SAF tree onto /storage/<volume>', () {
      expect(
        BiosDestinationService.realPathFor(
          'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3Abios',
        ),
        '/storage/1A2B-3C4D/bios',
      );
    });

    test('is null for an empty string', () {
      expect(BiosDestinationService.realPathFor('  '), isNull);
    });
  });
}
