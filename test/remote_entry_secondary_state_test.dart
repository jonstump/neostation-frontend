import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/utils/remote_entry_secondary_state.dart';

/// What a selected remote entry pushes to the second screen: its cached
/// cover (when the file is there) and a rom-id keyed game id, built from
/// the cache alone — the entry's own media paths are never consulted.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display
/// And Search"
GameModel _game({String? romPath, int? rommRomId}) => GameModel(
  romname: 'Game.gba',
  realname: 'Game',
  name: 'Game',
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: romPath,
  rommRomId: rommRomId,
);

void main() {
  test('a local game takes the media path: null here', () {
    final push = remoteEntrySecondaryStateFor(
      _game(romPath: '/roms/gba/Game.gba', rommRomId: 9),
      cachedCoverPath: '/cache/romm_covers/abc/9.png',
      exists: (_) => true,
    );
    expect(push, isNull);
  });

  test('a remote entry with a cached cover pushes it and a romm: id', () {
    final push = remoteEntrySecondaryStateFor(
      _game(rommRomId: 9),
      cachedCoverPath: '/cache/romm_covers/abc/9.png',
      exists: (_) => true,
    );
    expect(push, isNotNull);
    expect(push!.coverPath, '/cache/romm_covers/abc/9.png');
    expect(push.gameId, 'romm:9');
  });

  test('no cached cover, or an evicted file, pushes the placeholder', () {
    final missing = remoteEntrySecondaryStateFor(
      _game(rommRomId: 9),
      cachedCoverPath: null,
      exists: (_) => true,
    );
    expect(missing!.coverPath, isNull);
    expect(missing.gameId, 'romm:9');

    final evicted = remoteEntrySecondaryStateFor(
      _game(rommRomId: 9),
      cachedCoverPath: '/cache/romm_covers/abc/9.png',
      exists: (_) => false,
    );
    expect(evicted!.coverPath, isNull);
  });

  test('only the cache path is ever checked for existence', () {
    final probed = <String>[];
    remoteEntrySecondaryStateFor(
      _game(rommRomId: 9),
      cachedCoverPath: '/cache/romm_covers/abc/9.png',
      exists: (path) {
        probed.add(path);
        return true;
      },
    );
    expect(probed, ['/cache/romm_covers/abc/9.png']);
  });
}
