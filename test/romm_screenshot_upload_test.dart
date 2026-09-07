import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/retroarch_config_model.dart';
import 'package:neostation/models/romm_screenshot.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/romm_screenshot_map_repository.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm/screenshot_collector.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';
import 'package:neostation/sync/sync_manager.dart';

import 'database_test_helper.dart';

/// [RommService.uploadScreenshot] over a scripted HTTP client, and the
/// session-end pass on [RomMSyncProvider] that drives it.
///
/// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
/// "Upload And Ledger", REQ "Concurrency Safety"
void main() {
  group('RommService.uploadScreenshot', () {
    late Directory tempDir;
    final requests = <http.Request>[];

    /// The requests this test cares about. An API-key connection now verifies
    /// itself once — a heartbeat plus `GET /api/users/me`, where it learns the
    /// scopes its key holds — before its first authenticated call.
    // Governing: ADR-0013, SPEC-0013 REQ "Optional Scope Groups",
    // ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
    Iterable<http.Request> calls() => requests.where(
      (r) => !const {'/api/heartbeat', '/api/users/me'}.contains(r.url.path),
    );

    void serve(FutureOr<http.Response> Function(http.Request) respond) {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          return await respond(request);
        }),
      );
    }

    RommService service() =>
        RommService()
          ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');

    File shot(String name, {int bytes = 8}) =>
        File('${tempDir.path}${Platform.pathSeparator}$name')
          ..writeAsBytesSync(List<int>.filled(bytes, 65));

    setUp(() {
      requests.clear();
      tempDir = Directory.systemTemp.createTempSync('romm_shot_upload_test');
    });

    tearDown(() {
      RommService.debugUseHttpClient(null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('POSTs multipart screenshotFile to /api/screenshots', () async {
      serve(
        (_) async => http.Response(
          jsonEncode({
            'id': 12,
            'file_name': 'Game-a.png',
            'file_size_bytes': 8,
            'download_path': 'assets/1/Game-a.png',
            'is_gallery': true,
            'is_public': false,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        ),
      );

      final result = await service().uploadScreenshot(7, shot('Game-a.png'));

      expect(calls(), hasLength(1));
      final request = calls().single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/screenshots');
      expect(request.url.queryParameters['rom_id'], '7');
      expect(
        request.headers['content-type'],
        startsWith('multipart/form-data'),
      );
      expect(request.body, contains('name="screenshotFile"'));
      expect(request.body, contains('filename="Game-a.png"'));

      expect(result, isNotNull);
      expect(result!.id, 12);
      expect(result.fileName, 'Game-a.png');
      expect(result.fileSizeBytes, 8);
      expect(result.downloadPath, 'assets/1/Game-a.png');
      expect(result.isGallery, isTrue);
      expect(result.isPublic, isFalse);
    });

    test('a 413 throws the payloadTooLarge kind, naming the file', () async {
      serve((_) async => http.Response('too large', 413));

      await expectLater(
        service().uploadScreenshot(7, shot('Game-huge.png')),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.payloadTooLarge)
              .having((e) => e.statusCode, 'statusCode', 413)
              .having((e) => e.message, 'message', contains('Game-huge.png')),
        ),
      );
    });

    test('any other failure keeps the default kind and the status', () async {
      serve((_) async => http.Response('nope', 500));

      await expectLater(
        service().uploadScreenshot(7, shot('Game-a.png')),
        throwsA(
          isA<RommException>()
              .having((e) => e.kind, 'kind', RommErrorKind.other)
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('reads the screenshot out of a ROM-detail response body', () async {
      serve(
        (_) async => http.Response(
          jsonEncode({
            'id': 7,
            'name': 'Game',
            'user_screenshots': [
              {'id': 1, 'file_name': 'old.png', 'file_size_bytes': 2},
              {'id': 2, 'file_name': 'Game-a.png', 'file_size_bytes': 8},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );

      final result = await service().uploadScreenshot(7, shot('Game-a.png'));

      expect(result?.id, 2);
      expect(result?.fileName, 'Game-a.png');
    });

    test(
      'an unrecognisable success body is not treated as a failure',
      () async {
        serve((_) async => http.Response('[]', 200));

        expect(await service().uploadScreenshot(7, shot('Game-a.png')), isNull);
      },
    );
  });

  group('RommScreenshot.fromUploadResponse', () {
    test('returns null for a shape it does not recognise', () {
      expect(RommScreenshot.fromUploadResponse(null), isNull);
      expect(RommScreenshot.fromUploadResponse(<Object>[]), isNull);
      expect(RommScreenshot.fromUploadResponse(const {'id': 1}), isNull);
    });
  });

  group('RomMSyncProvider.uploadSessionScreenshots', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter db;
    late Directory shotsDir;
    late _FakeRommService svc;
    late _FakeBrowse browse;

    final sessionStart = DateTime(2026, 9, 6, 10, 0, 0);

    const romPath = '/roms/snes/Game.sfc';

    final game = GameModel(
      romname: 'Game.sfc',
      realname: 'Game',
      name: 'Game',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0,
      romPath: romPath,
      systemFolderName: 'snes',
    );

    File write(String name, {int bytes = 16, Duration? offset}) {
      final file = File('${shotsDir.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(List<int>.filled(bytes, 0));
      file.setLastModifiedSync(
        sessionStart.add(offset ?? const Duration(minutes: 1)),
      );
      return file;
    }

    RomMSyncProvider build() => RomMSyncProvider(
      browse,
      NeoSyncProvider(NeoSyncService()),
      autoSweep: false,
      listGames: () async => [game],
      screenshots: ScreenshotCollector(
        loadConfig: () async => RetroArchConfig(
          configPath: '/cfg/retroarch.cfg',
          screenshotDirectory: shotsDir.path,
        ),
        loadLedger: RommScreenshotMapRepository.recordedFor,
      ),
    );

    setUp(() async {
      db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(SqliteMigrations.createAppRommScreenshotMapTableSql);
      await db.execute('INSERT INTO user_config (id) VALUES (1)');
      shotsDir = Directory.systemTemp.createTempSync('romm_shot_pass_test');
      svc = _FakeRommService();
      browse = _FakeBrowse(svc);
    });

    tearDown(() async {
      await helper.tearDown();
      if (shotsDir.existsSync()) shotsDir.deleteSync(recursive: true);
    });

    Future<void> link() => RommSaveMapRepository.putMapping(
      source: RommLinkSource.download,
      romname: 'Game.sfc',
      systemFolder: 'snes',
      rommRomId: 42,
    );

    test('uploads each new capture once and records it', () async {
      await link();
      write('Game-a.png', bytes: 10);
      write('Game-b.png', bytes: 20, offset: const Duration(minutes: 2));

      final provider = build();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 2);
      expect(svc.uploaded.map((u) => u.name), ['Game-a.png', 'Game-b.png']);
      expect(svc.uploaded.every((u) => u.romId == 42), isTrue);

      // The ledger now covers both, so a second pass sends nothing.
      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-a.png': 10,
        'Game-b.png': 20,
      });
      svc.uploaded.clear();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });

    test('a failed upload stays unrecorded and retries next session', () async {
      await link();
      write('Game-a.png', bytes: 10);
      write('Game-b.png', bytes: 20, offset: const Duration(minutes: 2));
      svc.failWith['Game-a.png'] = const SocketException('connection reset');

      final provider = build();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 1);
      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-b.png': 20,
      });

      // Next session: only the one that failed is offered, and it lands.
      svc.failWith.clear();
      svc.uploaded.clear();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 1);
      expect(svc.uploaded.map((u) => u.name), ['Game-a.png']);
      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-a.png': 10,
        'Game-b.png': 20,
      });
    });

    test('a 413 is recorded as skipped and never offered again', () async {
      await link();
      write('Game-huge.png', bytes: 99);
      svc.failWith['Game-huge.png'] = RommException(
        'too large',
        statusCode: 413,
        kind: RommErrorKind.payloadTooLarge,
      );

      final provider = build();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 0);
      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-huge.png': null,
      });

      svc.failWith.clear();
      svc.uploaded.clear();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });

    test(
      'a disconnect mid-pass stops it, leaving the rest unrecorded',
      () async {
        await link();
        write('Game-a.png', bytes: 10);
        write('Game-b.png', bytes: 20, offset: const Duration(minutes: 2));
        write('Game-c.png', bytes: 30, offset: const Duration(minutes: 3));
        svc.onUpload = (name) {
          if (name == 'Game-a.png') browse.connected = false;
        };

        final provider = build();
        expect(await provider.uploadSessionScreenshots(game, sessionStart), 1);
        expect(svc.uploaded.map((u) => u.name), ['Game-a.png']);
        expect(await RommScreenshotMapRepository.recordedFor(romPath), {
          'Game-a.png': 10,
        });
      },
    );

    test('does nothing while disconnected', () async {
      await link();
      write('Game-a.png');
      browse.connected = false;

      expect(await build().uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });

    test('does nothing when the toggle is off', () async {
      await link();
      write('Game-a.png');
      await db.execute('UPDATE user_config SET romm_upload_screenshots = 0');

      expect(await build().uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });

    test('does nothing for a game that is not linked to RomM', () async {
      write('Game-a.png');

      expect(await build().uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });

    test('does nothing after the provider is disposed', () async {
      await link();
      write('Game-a.png');

      final provider = build()..dispose();
      expect(await provider.uploadSessionScreenshots(game, sessionStart), 0);
      expect(svc.uploaded, isEmpty);
    });
  });

  group('the session-end hook', () {
    final helper = DatabaseTestHelper();
    late _RecordingProvider provider;

    const system = SystemModel(
      folderName: 'snes',
      realName: 'Super Nintendo',
      iconImage: '',
      color: '#7E57C2',
    );

    const game = GameModel(
      romname: 'Game.sfc',
      realname: 'Game',
      name: 'Game',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0,
      romPath: '/roms/snes/Game.sfc',
      systemFolderName: 'snes',
    );

    setUp(() async {
      final db = await helper.setUp();
      await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
      await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
      provider = _RecordingProvider(
        _FakeBrowse(_FakeRommService()),
        NeoSyncProvider(NeoSyncService()),
      );
      SyncManager.instance.register(provider);
    });

    tearDown(() async {
      SyncManager.instance.unregister(RomMSyncProvider.kProviderId);
      provider.dispose();
      await helper.tearDown();
    });

    test('ending a session hands the game and its start to the pass', () async {
      GameSessionManager.registerGameLaunch(system, game);
      final launchTime = GameSessionManager.gameLaunchTime;

      provider.gate.complete();
      await GameSessionManager.endGameSession();
      await Future<void>.delayed(Duration.zero);

      expect(provider.calls, hasLength(1));
      expect(provider.calls.single.game.romname, 'Game.sfc');
      expect(provider.calls.single.start, launchTime);
    });

    test('the pass is detached: teardown does not wait for it', () async {
      GameSessionManager.registerGameLaunch(system, game);

      // The gate is still closed, so the pass cannot have finished.
      await GameSessionManager.endGameSession();

      expect(GameSessionManager.isGameLaunched, isFalse);
      expect(provider.finished, isFalse);

      provider.gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(provider.finished, isTrue);
    });
  });
}

/// A [RomMSyncProvider] whose screenshot pass records its arguments and blocks
/// on [gate], so a test can prove the session teardown did not wait for it.
class _RecordingProvider extends RomMSyncProvider {
  _RecordingProvider(super.browse, super.neoSync) : super(autoSweep: false);

  final gate = Completer<void>();
  final List<({GameModel game, DateTime start})> calls = [];
  bool finished = false;

  @override
  Future<int> uploadSessionScreenshots(GameModel game, DateTime start) async {
    calls.add((game: game, start: start));
    await gate.future;
    finished = true;
    return 0;
  }
}

/// Records every screenshot upload and can be told to fail one by name.
class _FakeRommService extends RommService {
  final List<({int romId, String name})> uploaded = [];
  final Map<String, Object> failWith = {};

  /// Runs just before an upload resolves, so a test can change the world
  /// mid-pass (a disconnect, typically).
  void Function(String name)? onUpload;

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<RommScreenshot?> uploadScreenshot(int romId, File file) async {
    final name = file.path.split(Platform.pathSeparator).last;
    onUpload?.call(name);
    final failure = failWith[name];
    if (failure != null) throw failure;
    uploaded.add((romId: romId, name: name));
    return RommScreenshot(
      id: uploaded.length,
      fileName: name,
      fileSizeBytes: file.lengthSync(),
    );
  }
}

class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}
