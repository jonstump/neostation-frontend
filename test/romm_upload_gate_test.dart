import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_rom_upload.dart';

/// The context menu's "Upload to RomM" gate: offered for an unlinked,
/// single-file local game while the provider's server-side gate is open,
/// and for nothing else. The settings row reads the same server gate.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload
/// Surfaces"
void main() {
  const snes = SystemModel(
    id: 'snes',
    folderName: 'snes',
    realName: 'Super Nintendo',
    iconImage: '/images/icons/snes.png',
    color: '#000000',
  );

  GameModel local(String path) => GameModel(
    romname: 'Game',
    realname: 'Game',
    name: 'Game',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: path,
    systemFolderName: 'snes',
  );

  GameModel remote() => GameModel.fromCatalogRow(
    RommCatalogRow(
      serverUrl: 'https://romm.local',
      rommRomId: 9,
      platformId: 1,
      systemFolder: 'snes',
      name: 'Game',
      fsName: 'Game.sfc',
      fsSizeBytes: 4096,
      seenAt: DateTime.utc(2026, 9, 8),
    ),
    snes,
  );

  test('an unlinked single-file local game is offered', () {
    expect(
      rommUploadGateFor(
        local('/roms/snes/Game.sfc'),
        linked: false,
        serverAllows: true,
      ),
      RommUploadGate.offered,
    );
  });

  test('a SAF path is a single file like any other', () {
    expect(
      rommUploadGateFor(
        local(
          'content://com.android.externalstorage.documents/document/primary%3Aemu%2Froms%2Fsnes%2FGame.sfc',
        ),
        linked: false,
        serverAllows: true,
      ),
      RommUploadGate.offered,
    );
  });

  test('the server gate closes everything, whatever the game', () {
    expect(
      rommUploadGateFor(
        local('/roms/snes/Game.sfc'),
        linked: false,
        serverAllows: false,
      ),
      RommUploadGate.serverGateClosed,
    );
  });

  test('a linked game is not offered', () {
    expect(
      rommUploadGateFor(
        local('/roms/snes/Game.sfc'),
        linked: true,
        serverAllows: true,
      ),
      RommUploadGate.linked,
    );
  });

  test('a remote entry has nothing to send', () {
    expect(
      rommUploadGateFor(remote(), linked: false, serverAllows: true),
      RommUploadGate.notLocal,
    );
  });

  test('a playlist or a disc image is not a single file', () {
    expect(
      rommUploadGateFor(
        local('/roms/psx/Game.m3u'),
        linked: false,
        serverAllows: true,
      ),
      RommUploadGate.notSingleFile,
    );
    expect(
      rommUploadGateFor(
        local('/roms/psx/Game.chd'),
        linked: false,
        serverAllows: true,
      ),
      RommUploadGate.notSingleFile,
    );
  });
}
