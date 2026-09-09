import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/screens/game_screen/my_games_list/selection_retention.dart';

GameModel _game(String romname, {String? romPath, int? rommRomId}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: romPath,
  rommRomId: rommRomId,
);

GameModel _local(String romname, {int? rommRomId}) =>
    _game(romname, romPath: '/roms/psx/$romname', rommRomId: rommRomId);

GameModel _remote(String romname, int rommRomId) =>
    _game(romname, rommRomId: rommRomId);

/// The selection a game list keeps across a reload, in particular across the
/// flip of a remote entry to the local game its download became.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The Library"
void main() {
  test('a local game keeps its place by romname', () {
    final games = [_local('A.bin'), _local('B.bin'), _local('C.bin')];
    expect(retainedSelectionIndex(games, _local('B.bin')), 1);
  });

  test('a gone game answers -1', () {
    final games = [_local('A.bin'), _local('C.bin')];
    expect(retainedSelectionIndex(games, _local('B.bin')), -1);
  });

  test('a single-file download keeps the selection by the shared name', () {
    final selected = _remote('Game.bin', 7);
    final games = [_local('A.bin'), _local('Game.bin'), _local('Z.bin')];
    expect(retainedSelectionIndex(games, selected), 1);
  });

  test('a local game carrying the link matches by rom id', () {
    final selected = _remote('Game.zip', 7);
    final games = [_local('A.bin'), _local('Game.bin', rommRomId: 7)];
    expect(retainedSelectionIndex(games, selected), 1);
  });

  test('a multi-disc download is found under its indexed .m3u', () {
    final selected = _remote('Game (Disc 1).chd', 7);
    final games = [_local('A.bin'), _local('X.bin'), _local('Game.m3u')];
    expect(retainedSelectionIndex(games, selected, indexedName: 'Game.m3u'), 2);
  });

  test('an appended .zip is found under the indexed name', () {
    final selected = _remote('Game.bin', 7);
    final games = [_local('A.bin'), _local('Game.bin.zip')];
    expect(
      retainedSelectionIndex(games, selected, indexedName: 'Game.bin.zip'),
      1,
    );
  });

  test('the indexed name never lands on a remote entry', () {
    final selected = _remote('Game.bin', 7);
    final games = [_local('A.bin'), _remote('Game.m3u', 8)];
    expect(
      retainedSelectionIndex(games, selected, indexedName: 'Game.m3u'),
      -1,
    );
  });

  test('without an indexed name a renamed flip is not guessed', () {
    final selected = _remote('Game.bin', 7);
    final games = [_local('A.bin'), _local('Game.m3u')];
    expect(retainedSelectionIndex(games, selected), -1);
  });
}
