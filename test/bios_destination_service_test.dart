import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/bios_destination_service.dart';

/// [BiosDestinationService] precedence: RetroArch's `system_directory` first,
/// the user-chosen `bios_directory` second, nothing third — plus the Android
/// SAF translation both candidates go through.
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
  /// disk, and [written] collects what would be persisted.
  BiosDestinationService svc({
    String? retroArch,
    String? stored,
    Set<String> existing = const {},
    List<String>? written,
  }) => BiosDestinationService(
    retroArchSystemDirectory: () async => retroArch,
    storedBiosDirectory: () async => stored,
    persistBiosDirectory: (d) async => written?.add(d),
    directoryExists: (d) async => existing.contains(d),
  );

  group('resolve', () {
    test('prefers the RetroArch system directory when it exists', () async {
      final dir = await svc(
        retroArch: '/home/deck/.config/retroarch/system',
        stored: '/roms/bios',
        existing: {'/home/deck/.config/retroarch/system', '/roms/bios'},
      ).resolve(psx);

      expect(dir, '/home/deck/.config/retroarch/system');
    });

    test(
      'falls back to the configured folder when RetroArch has none',
      () async {
        final dir = await svc(
          stored: '/roms/bios',
          existing: {'/roms/bios'},
        ).resolve(psx);

        expect(dir, '/roms/bios');
      },
    );

    test('falls back when the RetroArch directory does not exist', () async {
      final dir = await svc(
        retroArch: '/gone/system',
        stored: '/roms/bios',
        existing: {'/roms/bios'},
      ).resolve(psx);

      expect(dir, '/roms/bios');
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
