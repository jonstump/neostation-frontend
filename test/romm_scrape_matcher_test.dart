import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/utils/romm_scrape_matcher.dart';

/// The rule that decides which RomM ROM a local game with no link
/// corresponds to when there is no link: file name first, then a unique normalized
/// title, and never a guess between two candidates.

RommRom rom(int id, String name, String fsName, {bool multi = false}) {
  final dot = fsName.lastIndexOf('.');
  return RommRom.fromJson({
    'id': id,
    'name': name,
    'fs_name': fsName,
    'fs_name_no_ext': dot > 0 ? fsName.substring(0, dot) : fsName,
    'fs_extension': dot > 0 ? fsName.substring(dot + 1) : '',
    'platform_id': 1,
    'platform_slug': 'snes',
    if (multi) 'has_multiple_files': true,
  });
}

void main() {
  group('file name tier', () {
    test('an identical file name matches', () {
      final index = RommScrapeIndex.build([
        rom(1, 'Chrono Trigger', 'Chrono Trigger (USA).sfc'),
        rom(2, 'Secret of Mana', 'Secret of Mana (USA).sfc'),
      ]);
      final match = index.lookup('Chrono Trigger (USA).sfc');
      expect(match.kind, RommScrapeMatchKind.matched);
      expect(match.romId, 1);
      expect(match.tier, RommScrapeMatchTier.fileName);
    });

    test('case never decides it', () {
      final index = RommScrapeIndex.build([rom(7, 'Zelda', 'ZELDA (USA).sfc')]);
      expect(index.lookup('zelda (usa).SFC').romId, 7);
    });

    test('a multi-file ROM matches the playlist it unpacks to', () {
      final index = RommScrapeIndex.build([
        rom(9, 'Final Fantasy VII', 'Final Fantasy VII (USA).zip', multi: true),
      ]);
      final match = index.lookup('Final Fantasy VII (USA).zip.m3u');
      expect(match.romId, 9);
      expect(match.tier, RommScrapeMatchTier.fileName);
    });

    test('two ROMs claiming one file name is ambiguous, never a pick', () {
      final index = RommScrapeIndex.build([
        rom(1, 'Game', 'Game.sfc'),
        rom(2, 'Game (copy)', 'Game.sfc'),
      ]);
      final match = index.lookup('Game.sfc');
      expect(match.kind, RommScrapeMatchKind.ambiguous);
      expect(match.romId, isNull);
      expect(match.tier, RommScrapeMatchTier.fileName);
    });

    test('an exact file name wins over an ambiguous title', () {
      final index = RommScrapeIndex.build([
        rom(1, 'ActRaiser', 'ActRaiser (USA).sfc'),
        rom(2, 'ActRaiser', 'ActRaiser (Europe).sfc'),
      ]);
      final match = index.lookup('ActRaiser (USA).sfc');
      expect(match.romId, 1, reason: 'the name picks one; the title could not');
      expect(match.tier, RommScrapeMatchTier.fileName);
    });
  });

  group('title tier', () {
    test('a different file name with the same title matches', () {
      final index = RommScrapeIndex.build([
        rom(5, 'ActRaiser', 'actraiser.zip'),
        rom(6, 'Chrono Trigger', 'ct.zip'),
      ]);
      final match = index.lookup('ActRaiser (USA).sfc');
      expect(match.kind, RommScrapeMatchKind.matched);
      expect(match.romId, 5);
      expect(match.tier, RommScrapeMatchTier.title);
    });

    test('regional variants of one title are ambiguous, not a pick', () {
      final index = RommScrapeIndex.build([
        rom(1, 'ActRaiser', 'ActRaiser (USA).sfc'),
        rom(2, 'ActRaiser', 'ActRaiser (Europe).sfc'),
      ]);
      final match = index.lookup('ActRaiser (Japan).sfc');
      expect(match.kind, RommScrapeMatchKind.ambiguous);
      expect(match.tier, RommScrapeMatchTier.title);
    });

    test('region, revision and dump tags are ignored', () {
      final index = RommScrapeIndex.build([
        rom(3, 'Sonic The Hedgehog', 'sonic.md'),
      ]);
      expect(
        index.lookup('Sonic The Hedgehog (USA, Europe) (Rev A) [!].md').romId,
        3,
      );
    });

    test('"&" and "and" are the same word', () {
      final index = RommScrapeIndex.build([
        rom(4, 'Ratchet and Clank', 'rc.iso'),
      ]);
      expect(index.lookup('Ratchet & Clank.iso').romId, 4);
    });

    test('a trailing ", The" is the same title as a leading "The"', () {
      final index = RommScrapeIndex.build([
        rom(8, 'The Legend of Zelda: A Link to the Past', 'alttp.sfc'),
      ]);
      expect(
        index
            .lookup('Legend of Zelda, The - A Link to the Past (USA).sfc')
            .romId,
        8,
      );
    });

    test('diacritics fold', () {
      final index = RommScrapeIndex.build([rom(10, 'Pokemon Red', 'pr.gb')]);
      expect(index.lookup('Pokémon Red (USA).gb').romId, 10);
    });

    test('the on-disk stem names the game when the display name differs', () {
      final index = RommScrapeIndex.build([
        rom(11, 'MMX', 'Mega Man X (USA).sfc'),
      ]);
      final match = index.lookup('Mega Man X (Europe).sfc');
      expect(match.romId, 11);
      expect(match.tier, RommScrapeMatchTier.title);
    });

    test('a different game is not matched', () {
      final index = RommScrapeIndex.build([rom(1, 'Chrono Trigger', 'ct.sfc')]);
      expect(index.lookup('Chrono Cross.sfc').kind, RommScrapeMatchKind.none);
    });

    test('a similar title is not matched', () {
      final index = RommScrapeIndex.build([rom(1, 'Mario', 'm.sfc')]);
      expect(
        index.lookup('Super Mario World.sfc').kind,
        RommScrapeMatchKind.none,
      );
    });

    test('a name that is only tags has no title and matches nothing', () {
      final index = RommScrapeIndex.build([rom(1, 'Mario', 'm.sfc')]);
      expect(index.lookup('(USA).sfc').kind, RommScrapeMatchKind.none);
    });
  });

  group('a name that is only tags', () {
    test('never matches a ROM whose own name is only tags', () {
      final index = RommScrapeIndex.build([
        rom(1, '(Unknown)', '(Unknown).sfc'),
      ]);
      expect(index.lookup('(USA).sfc').kind, RommScrapeMatchKind.none);
    });
  });

  group('empty and shape', () {
    test('an empty index matches nothing', () {
      expect(
        RommScrapeIndex.empty().lookup('Anything.sfc').kind,
        RommScrapeMatchKind.none,
      );
      expect(RommScrapeIndex.build(const []).size, 0);
    });

    test('size counts the ROMs indexed', () {
      expect(
        RommScrapeIndex.build([
          rom(1, 'A', 'a.sfc'),
          rom(2, 'B', 'b.sfc'),
        ]).size,
        2,
      );
    });
  });

  group('titleKey and searchTerm', () {
    test('titleKey drops tags, folds case and punctuation', () {
      expect(
        RommScrapeIndex.titleKey('Super Mario World (USA) [!]'),
        'super mario world',
      );
      expect(
        RommScrapeIndex.titleKey("Kirby's Dream Land"),
        'kirby s dream land',
      );
      expect(RommScrapeIndex.titleKey('(USA)'), isEmpty);
    });

    test('searchTerm is the title in the file\'s own case', () {
      expect(
        RommScrapeIndex.searchTerm('ActRaiser (USA) [!].sfc'),
        'ActRaiser',
      );
      expect(RommScrapeIndex.searchTerm('(USA).sfc'), isEmpty);
    });
  });
}
