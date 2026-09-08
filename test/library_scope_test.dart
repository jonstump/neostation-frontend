import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/library_scope.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/system_model.dart';

/// The library scope on its own: how it opens, how it toggles, and that the
/// `downloaded` predicate is a pure pass over a list already in memory.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope",
/// REQ "Remote Entries In The Game Model", REQ "Concurrency Safety"
void main() {
  const gba = SystemModel(
    id: 'gba',
    folderName: 'gba',
    realName: 'Game Boy Advance',
    iconImage: '/images/icons/gba.png',
    color: '#000000',
    raId: '5',
  );

  GameModel local(String name, {bool favorite = false}) => GameModel(
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
    isFavorite: favorite,
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
    genres: 'Platformer, Action',
    releaseYear: '2001',
    seenAt: DateTime.utc(2026, 9, 8),
  );

  group('LibraryScope.initial', () {
    test('opens in the configured scope while the server is reachable', () {
      expect(
        LibraryScope.initial(configured: 'all', offline: false),
        LibraryScope.all,
      );
      expect(
        LibraryScope.initial(configured: 'downloaded', offline: false),
        LibraryScope.downloaded,
      );
    });

    test('opens in downloaded while offline, whatever the default', () {
      expect(
        LibraryScope.initial(configured: 'all', offline: true),
        LibraryScope.downloaded,
      );
    });

    test('an unknown or missing stored value reads as all', () {
      expect(LibraryScope.fromConfig(null), LibraryScope.all);
      expect(LibraryScope.fromConfig(''), LibraryScope.all);
      expect(LibraryScope.fromConfig('everything'), LibraryScope.all);
    });

    test('config value round-trips through the enum', () {
      for (final scope in LibraryScope.values) {
        expect(LibraryScope.fromConfig(scope.configValue), scope);
      }
    });
  });

  test('toggled flips between the two scopes', () {
    expect(LibraryScope.all.toggled, LibraryScope.downloaded);
    expect(LibraryScope.downloaded.toggled, LibraryScope.all);
  });

  group('GameModel remote fields', () {
    test('a catalog row becomes a remote entry with no path', () {
      final game = GameModel.fromCatalogRow(
        row(9, 'Metroid Fusion (USA).gba'),
        gba,
      );
      expect(game.isRemote, isTrue);
      expect(game.romPath, isNull);
      expect(game.rommRomId, 9);
      expect(game.remoteSizeBytes, 4096);
      expect(game.romname, 'Metroid Fusion (USA).gba');
      expect(game.name, 'Metroid Fusion (USA)');
      expect(game.idRa, 77);
      expect(game.genre, 'Platformer');
      expect(game.year, '2001');
      expect(game.systemFolderName, 'gba');
      expect(game.systemRaId, '5');
    });

    test('the display name can be resolved by the caller', () {
      final game = GameModel.fromCatalogRow(
        row(9, 'Metroid Fusion (USA).gba'),
        gba,
        displayName: 'Metroid Fusion',
        showRomFileNameSubtitle: true,
      );
      expect(game.name, 'Metroid Fusion');
      expect(game.showRomFileNameSubtitle, isTrue);
    });

    test('a scanned game is never remote, linked or not', () {
      expect(local('a.gba').isRemote, isFalse);
      expect(local('a.gba').copyWith(rommRomId: 3).isRemote, isFalse);
    });

    test('two remote entries with one filename stay distinct', () {
      final a = GameModel.fromCatalogRow(row(1, 'same.gba'), gba);
      final b = GameModel.fromCatalogRow(row(2, 'same.gba'), gba);
      expect(a == b, isFalse);
      expect({a: 0, b: 1}.length, 2);
    });
  });

  group('LibraryScope.filter', () {
    final merged = <GameModel>[
      local('Advance Wars.gba', favorite: true),
      GameModel.fromCatalogRow(row(1, 'Golden Sun.gba'), gba),
      local('Mario Kart.gba'),
      GameModel.fromCatalogRow(row(2, 'Wario Land 4.gba'), gba),
    ];

    test('all keeps the merged list as it is', () {
      expect(identical(LibraryScope.all.filter(merged), merged), isTrue);
    });

    test('downloaded hides the remote entries and nothing else', () {
      final shown = LibraryScope.downloaded.filter(merged);
      expect(shown.map((g) => g.romname), [
        'Advance Wars.gba',
        'Mario Kart.gba',
      ]);
      expect(shown.any((g) => g.isRemote), isFalse);
    });

    test('a toggle is a second pass over the same list, not a reload', () {
      // The source list is untouched by either pass, so a view can flip back
      // and forth over what it already holds.
      final before = List.of(merged);
      LibraryScope.downloaded.filter(merged);
      LibraryScope.all.filter(merged);
      expect(merged, before);
      expect(LibraryScope.all.filter(merged).length, 4);
    });
  });
}
