import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/widgets/remote_entry_badge.dart';

/// The one state machine every card badge and footer label reads from:
/// local, remote, downloading, failed — and the action each maps to.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry
/// Presentation"
GameModel _game({String? romPath, int? rommRomId, int? size}) => GameModel(
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
  remoteSizeBytes: size,
);

void main() {
  final local = _game(romPath: '/roms/gba/Game.gba', rommRomId: 7);
  final remote = _game(rommRomId: 7, size: 12 * 1024 * 1024);

  group('remoteEntryStateFor', () {
    test('a local game is local whatever the tracker says', () {
      for (final status in [...RommDownloadStatus.values, null]) {
        expect(remoteEntryStateFor(local, status), RemoteEntryState.local);
      }
    });

    test('a remote entry with no tracker is remote', () {
      expect(remoteEntryStateFor(remote, null), RemoteEntryState.remote);
    });

    test('a running or finished-but-unindexed tracker is downloading', () {
      expect(
        remoteEntryStateFor(remote, RommDownloadStatus.downloading),
        RemoteEntryState.downloading,
      );
      expect(
        remoteEntryStateFor(remote, RommDownloadStatus.completed),
        RemoteEntryState.downloading,
      );
    });

    test('a failed tracker is failed; a cancelled one is remote again', () {
      expect(
        remoteEntryStateFor(remote, RommDownloadStatus.failed),
        RemoteEntryState.failed,
      );
      expect(
        remoteEntryStateFor(remote, RommDownloadStatus.cancelled),
        RemoteEntryState.remote,
      );
    });
  });

  group('remoteEntryActionFor', () {
    test('Play, Download, Cancel, Retry by state', () {
      expect(
        remoteEntryActionFor(RemoteEntryState.local),
        RemoteEntryAction.play,
      );
      expect(
        remoteEntryActionFor(RemoteEntryState.remote),
        RemoteEntryAction.download,
      );
      expect(
        remoteEntryActionFor(
          RemoteEntryState.downloading,
          status: RommDownloadStatus.downloading,
        ),
        RemoteEntryAction.cancel,
      );
      expect(
        remoteEntryActionFor(RemoteEntryState.failed),
        RemoteEntryAction.retry,
      );
    });

    test(
      'a completed transfer waits for the settle rather than cancelling',
      () {
        expect(
          remoteEntryActionFor(
            RemoteEntryState.downloading,
            status: RommDownloadStatus.completed,
          ),
          RemoteEntryAction.wait,
        );
      },
    );
  });

  group('remoteEntryPercent', () {
    test('40 percent at 40 percent', () {
      final tracker = RommDownload(romId: 7, received: 40, total: 100);
      expect(remoteEntryPercent(tracker), 40);
    });

    test('indeterminate when the server sent no total', () {
      final tracker = RommDownload(romId: 7, received: 4096);
      expect(remoteEntryPercent(tracker), isNull);
    });

    test('100 once completed, and null without a tracker', () {
      final tracker = RommDownload(
        romId: 7,
        status: RommDownloadStatus.completed,
        received: 3,
        total: 100,
      );
      expect(remoteEntryPercent(tracker), 100);
      expect(remoteEntryPercent(null), isNull);
    });
  });

  group('remoteEntrySizeLabel', () {
    test('formats a remote entry\'s size and nothing else', () {
      expect(remoteEntrySizeLabel(remote), '12 MB');
      expect(remoteEntrySizeLabel(local), isNull);
      expect(remoteEntrySizeLabel(_game(rommRomId: 7)), isNull);
      expect(remoteEntrySizeLabel(_game(rommRomId: 7, size: 0)), isNull);
    });
  });
}
