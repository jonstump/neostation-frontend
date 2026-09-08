import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/utils/scrape_gate.dart';

/// The single-scrape gate on its own: the one decision every scrape entry
/// (card button, context menu, Select + A in every view) makes before it
/// touches RomM or ScreenScraper.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
void main() {
  const gba = SystemModel(
    id: 'gba',
    folderName: 'gba',
    realName: 'Game Boy Advance',
    iconImage: '/images/icons/gba.png',
    color: '#000000',
    raId: '5',
  );

  GameModel local(String name) => GameModel(
    romname: name,
    realname: name,
    name: name,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: '/roms/gba/$name',
  );

  RommCatalogRow row(int id, String fsName) => RommCatalogRow(
    serverUrl: 'https://romm.local',
    rommRomId: id,
    platformId: 1,
    systemFolder: 'gba',
    name: fsName.split('.').first,
    fsName: fsName,
    fsSizeBytes: 4096,
    raId: 77,
    genres: 'Platformer',
    releaseYear: '2001',
    seenAt: DateTime.utc(2026, 9, 8),
  );

  group('scrapeGateFor', () {
    test('a local game may be scraped', () {
      expect(scrapeGateFor(local('a.gba')), ScrapeGate.allowed);
    });

    test('a local game linked to RomM is still local, so still allowed', () {
      expect(
        scrapeGateFor(local('a.gba').copyWith(rommRomId: 3)),
        ScrapeGate.allowed,
      );
    });

    test('a remote entry is answered with the not-downloaded notice', () {
      final remote = GameModel.fromCatalogRow(
        row(9, 'Metroid Fusion (USA).gba'),
        gba,
      );
      expect(remote.isRemote, isTrue);
      expect(scrapeGateFor(remote), ScrapeGate.notDownloaded);
    });

    test(
      'the gate follows the model: a remote entry given a path is local',
      () {
        final remote = GameModel.fromCatalogRow(row(9, 'a.gba'), gba);
        expect(
          scrapeGateFor(remote.copyWith(romPath: '/roms/gba/a.gba')),
          ScrapeGate.allowed,
        );
      },
    );
  });
}
