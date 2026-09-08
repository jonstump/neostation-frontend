import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_catalog_row.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/game_screen/my_games_list/remote_download_flow.dart';

/// The confirm press on a remote entry: offline answers with a notice and
/// sends nothing; online resolves the catalog row, shows name, size and
/// destination, and starts the download only on a yes.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Download From The
/// Library"
GameModel _remote({int id = 42, int? size = 8 * 1024 * 1024}) => GameModel(
  romname: 'Metroid Fusion (USA).gba',
  realname: 'Metroid Fusion',
  name: 'Metroid Fusion',
  year: '2002',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: null,
  rommRomId: id,
  remoteSizeBytes: size,
);

RommCatalogRow _row({int id = 42, bool multi = false}) => RommCatalogRow(
  serverUrl: 'https://romm.lan',
  rommRomId: id,
  platformId: 3,
  systemFolder: 'gba',
  name: 'Metroid Fusion',
  fsName: multi ? 'Metroid Fusion (USA)' : 'Metroid Fusion (USA).gba',
  fsExtension: multi ? null : 'gba',
  fsSizeBytes: 8 * 1024 * 1024,
  hasMultipleFiles: multi,
  pathCoverSmall: '/assets/romm/resources/cover_small.png',
  raId: 3143,
  genres: 'Action, Adventure',
  releaseYear: '2002',
  seenAt: DateTime.utc(2026, 9, 8),
);

class _Harness {
  RommReachability reachability = RommReachability.online;
  RommRom? rom = _row().toRommRom();
  String? destination = '/roms/gba';
  bool confirm = true;
  bool confirmCancel = true;
  final requests = <RemoteDownloadRequest>[];
  final cancelsAsked = <GameModel>[];
  final started = <RommRom>[];
  final cancelled = <int>[];
  final lookedUp = <int>[];

  RemoteDownloadFlow get flow => RemoteDownloadFlow(
    reachability: () => reachability,
    lookupRom: (id) async {
      lookedUp.add(id);
      return rom;
    },
    resolveDestination: (_) async => destination,
    confirmDownload: (request) async {
      requests.add(request);
      return confirm;
    },
    confirmCancel: (game) async {
      cancelsAsked.add(game);
      return confirmCancel;
    },
    startDownload: started.add,
    cancelDownload: cancelled.add,
  );
}

void main() {
  group('RommCatalogRow.toRommRom', () {
    test('carries what the download needs, keyed by the same rom id', () {
      final rom = _row().toRommRom();
      expect(rom.id, 42);
      expect(rom.fsName, 'Metroid Fusion (USA).gba');
      expect(rom.fsNameNoExt, 'Metroid Fusion (USA)');
      expect(rom.fsExtension, 'gba');
      expect(rom.fsSizeBytes, 8 * 1024 * 1024);
      expect(rom.isMultiFile, isFalse);
      expect(rom.pathCoverSmall, '/assets/romm/resources/cover_small.png');
      expect(rom.raId, 3143);
      expect(rom.genres, ['Action', 'Adventure']);
      // The resolved system folder stands in for the platform slug so the
      // system resolves offline without RomM's platform table.
      expect(rom.platformSlug, 'gba');
    });

    test('a multi-file row keeps the flag the unpack rule reads', () {
      final rom = _row(multi: true).toRommRom();
      expect(rom.isMultiFile, isTrue);
      expect(rom.fsNameNoExt, 'Metroid Fusion (USA)');
      expect(rom.fsExtension, '');
    });
  });

  group('RemoteDownloadFlow.press', () {
    test('offline: the notice, and no lookup, dialog or request', () async {
      final h = _Harness()..reachability = RommReachability.offline;
      final outcome = await h.flow.press(_remote(), null);
      expect(outcome, RemoteDownloadOutcome.offlineNotice);
      expect(h.lookedUp, isEmpty);
      expect(h.requests, isEmpty);
      expect(h.started, isEmpty);
    });

    test('online: confirms name, size and destination, then starts', () async {
      final h = _Harness();
      final outcome = await h.flow.press(_remote(), null);
      expect(outcome, RemoteDownloadOutcome.started);
      expect(h.lookedUp, [42]);
      expect(h.requests, hasLength(1));
      final request = h.requests.single;
      expect(request.name, 'Metroid Fusion');
      expect(request.sizeLabel, '8 MB');
      expect(request.destination, '/roms/gba');
      // The ROM handed to downloadRom is the catalog row's, by id.
      expect(h.started.single.id, 42);
      expect(h.started.single.fsName, 'Metroid Fusion (USA).gba');
    });

    test('a cold start (unknown reachability) still asks the server', () async {
      final h = _Harness()..reachability = RommReachability.unknown;
      expect(
        await h.flow.press(_remote(), null),
        RemoteDownloadOutcome.started,
      );
    });

    test('declining the confirmation starts nothing', () async {
      final h = _Harness()..confirm = false;
      final outcome = await h.flow.press(_remote(), null);
      expect(outcome, RemoteDownloadOutcome.declined);
      expect(h.requests, hasLength(1));
      expect(h.started, isEmpty);
    });

    test('a row the catalog no longer has is reported, not started', () async {
      final h = _Harness()..rom = null;
      final outcome = await h.flow.press(_remote(), null);
      expect(outcome, RemoteDownloadOutcome.notCatalogued);
      expect(h.requests, isEmpty);
      expect(h.started, isEmpty);
    });

    test('a failed tracker retries through the same confirmation', () async {
      final h = _Harness();
      final outcome = await h.flow.press(_remote(), RommDownloadStatus.failed);
      expect(outcome, RemoteDownloadOutcome.started);
      expect(h.requests, hasLength(1));
    });

    test('while downloading: asks, then cancels the same rom id', () async {
      final h = _Harness();
      final outcome = await h.flow.press(
        _remote(),
        RommDownloadStatus.downloading,
      );
      expect(outcome, RemoteDownloadOutcome.cancelRequested);
      expect(h.cancelsAsked, hasLength(1));
      expect(h.cancelled, [42]);
      expect(h.started, isEmpty);
    });

    test('keeping the download cancels nothing', () async {
      final h = _Harness()..confirmCancel = false;
      final outcome = await h.flow.press(
        _remote(),
        RommDownloadStatus.downloading,
      );
      expect(outcome, RemoteDownloadOutcome.cancelDeclined);
      expect(h.cancelled, isEmpty);
    });

    test('a completed-but-unindexed entry waits', () async {
      final h = _Harness();
      final outcome = await h.flow.press(
        _remote(),
        RommDownloadStatus.completed,
      );
      expect(outcome, RemoteDownloadOutcome.waiting);
      expect(h.started, isEmpty);
      expect(h.cancelled, isEmpty);
    });

    test('a local game is not this flow\'s to handle', () async {
      final h = _Harness();
      final local = GameModel(
        romname: 'Game.gba',
        realname: 'Game',
        name: 'Game',
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0,
        romPath: '/roms/gba/Game.gba',
        rommRomId: 42,
      );
      expect(await h.flow.press(local, null), RemoteDownloadOutcome.nothing);
      expect(h.lookedUp, isEmpty);
    });
  });

  group('RemoteDownloadFlow.download (context menu)', () {
    test('offline is refused before any lookup', () async {
      final h = _Harness()..reachability = RommReachability.offline;
      expect(
        await h.flow.download(_remote()),
        RemoteDownloadOutcome.offlineNotice,
      );
      expect(h.lookedUp, isEmpty);
    });

    test('a size the server did not send is left to the dialog', () async {
      final h = _Harness();
      await h.flow.download(_remote(size: null));
      expect(h.requests.single.sizeLabel, isNull);
    });
  });
}
