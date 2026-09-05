import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/utils/romm_link_state.dart';

/// The Manage tab's link-state derivation (SPEC-0004 "Link State Display")
/// and the key a manual write is filed under (the on-disk filename, as the
/// download path and `linkLocalCopy` write it), both as pure functions.

// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link State Display"

RommSaveMapping _row(RommLinkSource source, {String? fsName}) =>
    (rommRomId: 12, fsName: fsName, source: source);

void main() {
  group('rommLinkStateOf', () {
    test('no row reads as not linked', () {
      expect(rommLinkStateOf(null), RommLinkState.notLinked);
    });

    test('a manual row reads as linked manually', () {
      expect(
        rommLinkStateOf(_row(RommLinkSource.manual, fsName: 'ct-final.sfc')),
        RommLinkState.manual,
      );
    });

    test('an auto row reads as linked automatically', () {
      expect(rommLinkStateOf(_row(RommLinkSource.auto)), RommLinkState.auto);
    });

    test('a download row reads as linked automatically', () {
      expect(
        rommLinkStateOf(_row(RommLinkSource.download)),
        RommLinkState.auto,
      );
    });

    test(
      'a legacy null link_source decodes to auto and reads as automatic',
      () {
        final legacy = _row(RommLinkSource.fromDb(null));
        expect(legacy.source, RommLinkSource.auto);
        expect(rommLinkStateOf(legacy), RommLinkState.auto);
      },
    );
  });

  group('rommLinkKeyFor', () {
    test('desktop path: basename with extension', () {
      expect(
        rommLinkKeyFor(
          romPath: '/home/me/roms/snes/ct-final.sfc',
          romname: 'ct-final',
        ),
        'ct-final.sfc',
      );
    });

    test('Android SAF content URI: decoded basename with extension', () {
      expect(
        rommLinkKeyFor(
          romPath:
              'content://com.android.externalstorage.documents/tree/primary%3Aemu/document/primary%3Aemu%2Froms%2Fsnes%2Fct-final.sfc',
          romname: 'ct-final',
        ),
        'ct-final.sfc',
      );
    });

    test('multi-disc game keyed by its .m3u', () {
      expect(
        rommLinkKeyFor(
          romPath: '/roms/psx/Final Fantasy VII/Final Fantasy VII.m3u',
          romname: 'Final Fantasy VII',
        ),
        'Final Fantasy VII.m3u',
      );
    });

    test('no path falls back to the stripped name', () {
      expect(rommLinkKeyFor(romPath: null, romname: 'ct-final'), 'ct-final');
      expect(rommLinkKeyFor(romPath: '', romname: 'ct-final'), 'ct-final');
    });
  });

  group('cleanRomTitle', () {
    test('strips region and language tags', () {
      expect(cleanRomTitle('Chrono Trigger (USA) [EN,FR]'), 'Chrono Trigger');
    });

    test('strips several tags of both kinds in any order', () {
      expect(cleanRomTitle('Game [!] (Europe) (En,Fr,De) [T+Eng]'), 'Game');
    });

    test('strips nested brackets layer by layer', () {
      expect(cleanRomTitle('Game (USA (Beta [proto]))'), 'Game');
      expect(cleanRomTitle('Game [Rev (1)] (Japan)'), 'Game');
    });

    test('strips a bracketed revision', () {
      expect(cleanRomTitle('Game (USA) (Rev A)'), 'Game');
      expect(cleanRomTitle('Game (Rev 1)'), 'Game');
    });

    test('strips a trailing revision or version token outside brackets', () {
      expect(cleanRomTitle('Game Rev 1'), 'Game');
      expect(cleanRomTitle('Game Rev A'), 'Game');
      expect(cleanRomTitle('Game v1.2'), 'Game');
      expect(cleanRomTitle('Game V2'), 'Game');
      expect(cleanRomTitle('Game (USA) v1.1'), 'Game');
      expect(cleanRomTitle('Game v1.2 Rev 1'), 'Game');
      expect(cleanRomTitle('Game Rev 1.1 (USA)'), 'Game');
      expect(cleanRomTitle('Game Rev 2'), 'Game');
    });

    test('keeps a last word that merely starts with "rev"', () {
      expect(cleanRomTitle('Dance Dance Revolution'), 'Dance Dance Revolution');
      expect(
        cleanRomTitle('Resident Evil Revelations'),
        'Resident Evil Revelations',
      );
      expect(cleanRomTitle('Shadow Revenge'), 'Shadow Revenge');
      expect(
        cleanRomTitle('Resident Evil - Revelations (USA)'),
        'Resident Evil - Revelations',
      );
      expect(cleanRomTitle('Game Rev AB'), 'Game Rev AB');
    });

    test('keeps numbers and numerals that belong to the title', () {
      expect(cleanRomTitle('Super Mario Bros. 3 (USA)'), 'Super Mario Bros. 3');
      expect(
        cleanRomTitle('Final Fantasy VII (USA) (Disc 1)'),
        'Final Fantasy VII',
      );
      expect(cleanRomTitle('Sonic the Hedgehog 2'), 'Sonic the Hedgehog 2');
      expect(cleanRomTitle('Revelations'), 'Revelations');
      expect(cleanRomTitle('Gran Turismo V'), 'Gran Turismo V');
    });

    test('keeps a subtitle separator that still joins two parts', () {
      expect(cleanRomTitle('Game - Subtitle (USA)'), 'Game - Subtitle');
    });

    test('drops a separator left dangling by the removal', () {
      expect(cleanRomTitle('Game - (USA)'), 'Game');
      expect(cleanRomTitle('Game – [EN]'), 'Game');
    });

    test('collapses whitespace', () {
      expect(
        cleanRomTitle('  Chrono   Trigger (USA)   [!]  '),
        'Chrono Trigger',
      );
    });

    test('a name with no tags comes back trimmed and otherwise unchanged', () {
      expect(cleanRomTitle('ct-final'), 'ct-final');
      expect(cleanRomTitle('  Chrono Trigger  '), 'Chrono Trigger');
    });

    test('a name that was only tags returns the trimmed original', () {
      expect(cleanRomTitle('(USA) [!]'), '(USA) [!]');
      expect(cleanRomTitle('  [EN,FR] '), '[EN,FR]');
      expect(cleanRomTitle(''), '');
    });

    test('unbalanced brackets are left alone', () {
      expect(cleanRomTitle('Game (USA'), 'Game (USA');
      expect(cleanRomTitle('Game [EN'), 'Game [EN');
    });
  });
}
