import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/providers/romm_rom_upload.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm/rom_upload_source.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [RommProvider]'s side of the ROM upload: the gate the surfaces read, the
/// early ends of [RommProvider.uploadToRomm] that send nothing, what the
/// bulk enumeration leaves out, when the scan scope is read, and the
/// disconnect that cancels a batch. The batch engine itself is tested
/// through fakes in `romm_rom_upload_batch_test.dart`; here the engine is
/// real and the server is the fake service.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload
/// Surfaces", REQ "Scan And Link After Upload", REQ "Concurrency Safety";
/// ADR-0013, SPEC-0013 REQ "Optional Scope Groups"

class _FakeRommService extends RommService {
  List<RommPlatform> platforms = const [];
  RommFeatureSupport uploadSupport = RommFeatureSupport.unknown;
  final Map<RommScopeGroup, RommScopeState> scopes = {};

  /// `fileName@platformId` per upload call, in order.
  final List<String> uploads = [];
  final List<String> tasks = [];
  String? taskId = 'task-1';

  /// What [uploadRom] answers: true is confirmed, false is gated.
  bool uploadResult = true;

  /// Holds every upload open until released, for the mid-batch tests.
  Completer<void>? uploadGate;

  /// Run inside [uploadRom], before it answers, for scope changes that land
  /// while a file is going up.
  void Function()? duringUpload;

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommPlatform>> getPlatforms() async => platforms;

  @override
  RommFeatureSupport supports(RommFeature feature) =>
      feature == RommFeature.romUpload
      ? uploadSupport
      : RommFeatureSupport.unknown;

  @override
  RommScopeState hasScope(RommScopeGroup group) =>
      scopes[group] ?? RommScopeState.unknown;

  @override
  Future<String?> runTask(String name) async {
    tasks.add(name);
    return taskId;
  }

  @override
  Future<bool> uploadRom(
    RomUploadSource source, {
    required int platformId,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    uploads.add('$fileName@$platformId');
    duringUpload?.call();
    final gate = uploadGate;
    if (gate != null) await gate.future;
    if (shouldCancel?.call() ?? false) {
      throw RommException('cancelled', kind: RommErrorKind.uploadCancelled);
    }
    onProgress?.call(source.size, source.size);
    return uploadResult;
  }
}

class _FakeBrowse extends RommProvider {
  final _FakeRommService fake;
  bool connected = true;

  _FakeBrowse(this.fake);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fake;

  /// The real one flips the private status; the test's override of
  /// [isConnected] has to follow it for the engine's stop check to see it.
  @override
  Future<void> disconnect() {
    connected = false;
    return super.disconnect();
  }
}

const _snes = SystemModel(
  id: 'snes',
  folderName: 'snes',
  realName: 'Super Nintendo',
  iconImage: '',
  color: '#000000',
);

GameModel _game(String romname, String romPath, {String? folder = 'snes'}) =>
    GameModel(
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
      systemFolderName: folder,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late _FakeRommService svc;
  late _FakeBrowse provider;
  late Directory tempDir;

  String path(String fileName) => '${tempDir.path}/$fileName';

  /// A real, non-empty file: the batch opens its candidates for size before
  /// anything is sent.
  Future<String> rom(String fileName) async {
    final file = File(path(fileName));
    await file.writeAsBytes(List<int>.filled(16, 0x42));
    return file.path;
  }

  Future<void> seedRom(String fileName, {bool hidden = false}) => db.execute(
    'INSERT INTO user_roms (filename, rom_path, app_system_id, is_hidden) '
    "VALUES ('$fileName', '${path(fileName)}', 'snes', ${hidden ? 1 : 0})",
  );

  Future<void> link(String name, int romId) => RommSaveMapRepository.putMapping(
    source: RommLinkSource.download,
    romname: name,
    systemFolder: 'snes',
    rommRomId: romId,
  );

  setUp(() async {
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createUserRommConfigTableSql);
    await db.execute('INSERT INTO user_config (id) VALUES (1)');
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    tempDir = await Directory.systemTemp.createTemp('romm_upload_binding_');
    svc = _FakeRommService()
      ..platforms = [
        const RommPlatform(
          id: 1,
          name: 'SNES',
          slug: 'snes',
          fsSlug: 'snes',
          romCount: 1,
        ),
      ];
    provider = _FakeBrowse(svc);
  });

  tearDown(() async {
    provider.dispose();
    CredentialStore.debugReset();
    await helper.tearDown();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  // Governing: SPEC-0014 REQ "Upload Surfaces" — the server-side gate
  group('canUploadRoms', () {
    test('connected with everything unknown is offered', () {
      expect(provider.canUploadRoms, isTrue);
    });

    test('disconnected is not', () {
      provider.connected = false;
      expect(provider.canUploadRoms, isFalse);
    });

    test('an unreachable server is not', () {
      provider.installTransportHooks();
      svc.onTransportFailure!(const SocketException('no route to host'));

      expect(provider.reachability, RommReachability.offline);
      expect(provider.canUploadRoms, isFalse);
    });

    test('a server known to predate the upload session is not', () {
      svc.uploadSupport = RommFeatureSupport.unsupported;
      expect(provider.canUploadRoms, isFalse);

      svc.uploadSupport = RommFeatureSupport.supported;
      expect(provider.canUploadRoms, isTrue);
    });

    test('a login known to lack roms.write is not', () {
      svc.scopes[RommScopeGroup.romsWrite] = RommScopeState.denied;
      expect(provider.canUploadRoms, isFalse);

      svc.scopes[RommScopeGroup.romsWrite] = RommScopeState.granted;
      expect(provider.canUploadRoms, isTrue);
    });
  });

  group('uploadToRomm ends early, sending nothing,', () {
    test('when the gate is closed', () async {
      provider.connected = false;

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.end, RommUploadEnd.notOffered);
      expect(summary.neverStarted, isTrue);
      expect(svc.uploads, isEmpty);
    });

    // Governing: SPEC-0014 REQ "Platform Mapping" — scenario "No platform"
    test('when the server has no platform for the system', () async {
      svc.platforms = const [];

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.end, RommUploadEnd.noPlatform);
      expect(summary.endDetail, isEmpty);
      expect(svc.uploads, isEmpty);
    });

    // A different cause with a different remedy — the system is missing
    // here, not on the server — so it must not come back as `noPlatform`.
    // Issue #235.
    test('when the game names a system this library does not have', () async {
      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc'), folder: 'n64'),
      );

      expect(summary.end, RommUploadEnd.unknownSystem);
      expect(svc.uploads, isEmpty);
    });

    // Several RomM platforms folding onto one local system is its own cause
    // too, and the summary carries the slugs so the message can name what to
    // merge. Issue #235.
    test('when several platforms resolve to the system', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) "
        "VALUES ('ps1', 'PlayStation', 'ps1')",
      );
      svc.platforms = const [
        RommPlatform(id: 5, name: 'PlayStation', slug: 'ps', romCount: 1),
        RommPlatform(id: 6, name: 'PlayStation', slug: 'psx', romCount: 1),
      ];

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.bin'), folder: 'ps1'),
      );

      expect(summary.end, RommUploadEnd.ambiguousPlatform);
      expect(summary.endDetail, 'ps, psx');
      expect(svc.uploads, isEmpty);
    });

    test('when the game carries no path or no system', () async {
      expect(
        (await provider.uploadToRomm(_game('Game', ''))).end,
        RommUploadEnd.nothingToUpload,
      );
      expect(
        (await provider.uploadToRomm(
          _game('Game', await rom('Game.sfc'), folder: null),
        )).end,
        RommUploadEnd.nothingToUpload,
      );
      expect(svc.uploads, isEmpty);
    });

    test('when the game is linked under its file name', () async {
      await link('Game.sfc', 7);

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.end, RommUploadEnd.nothingToUpload);
      expect(svc.uploads, isEmpty);
    });

    test('when the game is linked under its stripped name', () async {
      await link('Game', 7);

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.end, RommUploadEnd.nothingToUpload);
      expect(svc.uploads, isEmpty);
    });

    test('a caller-supplied folder stands in for a row without one', () async {
      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc'), folder: null),
        systemFolder: 'snes',
      );

      expect(summary.end, RommUploadEnd.completed);
      expect(svc.uploads, ['Game.sfc@1']);
    });
  });

  group('uploadToRomm through the bound engine', () {
    test('sends the one file to the resolved platform', () async {
      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.end, RommUploadEnd.completed);
      expect(summary.uploaded.map((o) => o.fileName), ['Game.sfc']);
      expect(svc.uploads, ['Game.sfc@1']);
    });

    test('a gated answer fails the file and ends the batch', () async {
      svc.uploadResult = false;

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.uploaded, isEmpty);
      expect(summary.failed.single.failed, RommUploadFailure.gated);
      expect(summary.scan, RommUploadScanState.none);
      expect(svc.tasks, isEmpty);
    });

    test('a refused bulk confirmation ends as declined', () async {
      await seedRom('Game.sfc');
      await rom('Game.sfc');

      final summary = await provider.uploadMissingForSystem(
        _snes,
        confirm: (count, totalBytes) async {
          expect(count, 1);
          expect(totalBytes, 16);
          return false;
        },
      );

      expect(summary.end, RommUploadEnd.declined);
      expect(svc.uploads, isEmpty);
    });
  });

  // Governing: SPEC-0014 REQ "Upload Surfaces" — "unlinked single-file games"
  group('uploadMissingForSystem enumerates', () {
    test('the system\'s games minus the hidden and the linked', () async {
      for (final name in ['a.sfc', 'hidden.sfc', 'linked.sfc', 'byrom.sfc']) {
        await rom(name);
      }
      await seedRom('a.sfc');
      await seedRom('hidden.sfc', hidden: true);
      await seedRom('linked.sfc');
      await seedRom('byrom.sfc');
      await link('linked.sfc', 7);
      await link('byrom', 8);

      final summary = await provider.uploadMissingForSystem(
        _snes,
        confirm: (count, totalBytes) async => true,
      );

      expect(summary.end, RommUploadEnd.completed);
      expect(svc.uploads, ['a.sfc@1']);
      final named = [
        ...summary.uploaded,
        ...summary.skipped,
        ...summary.failed,
      ].map((o) => o.fileName);
      expect(named, ['a.sfc']);
    });

    test('nothing when every game is hidden or linked', () async {
      await rom('hidden.sfc');
      await rom('linked.sfc');
      await seedRom('hidden.sfc', hidden: true);
      await seedRom('linked.sfc');
      await link('linked.sfc', 7);

      final summary = await provider.uploadMissingForSystem(_snes);

      expect(summary.end, RommUploadEnd.nothingToUpload);
      expect(svc.uploads, isEmpty);
    });

    test('playlists stay in, to be listed as skipped', () async {
      await rom('a.sfc');
      await seedRom('a.sfc');
      await seedRom('disc.m3u');

      final summary = await provider.uploadMissingForSystem(
        _snes,
        confirm: (count, totalBytes) async {
          expect(count, 1, reason: 'the playlist is not in the count');
          return true;
        },
      );

      expect(svc.uploads, ['a.sfc@1']);
      expect(summary.skipped.single.fileName, 'disc.m3u');
      expect(summary.skipped.single.skipped, RommUploadSkipReason.multiFile);
    });
  });

  // Governing: SPEC-0014 REQ "Scan And Link After Upload"; SPEC-0018 REQ
  // "Maintenance Tasks"
  group('the scan request', () {
    test(
      'goes out when tasks.run is granted at the end of the batch',
      () async {
        svc.scopes[RommScopeGroup.tasksRun] = RommScopeState.granted;

        final summary = await provider.uploadToRomm(
          _game('Game', await rom('Game.sfc')),
        );

        expect(summary.scan, RommUploadScanState.requested);
        expect(svc.tasks, [RommRomUpload.scanTaskName]);
      },
    );

    test('is pending, and never sent, while tasks.run is unknown', () async {
      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.scan, RommUploadScanState.pending);
      expect(svc.tasks, isEmpty);
    });

    test('reads the scope at the end of the batch, not at its start', () async {
      // Unknown when the batch is bound; granted while the file goes up.
      svc.duringUpload = () =>
          svc.scopes[RommScopeGroup.tasksRun] = RommScopeState.granted;

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.scan, RommUploadScanState.requested);
      expect(svc.tasks, [RommRomUpload.scanTaskName]);
    });

    test('a scope lost mid-batch leaves the scan pending', () async {
      svc.scopes[RommScopeGroup.tasksRun] = RommScopeState.granted;
      svc.duringUpload = () =>
          svc.scopes[RommScopeGroup.tasksRun] = RommScopeState.denied;

      final summary = await provider.uploadToRomm(
        _game('Game', await rom('Game.sfc')),
      );

      expect(summary.scan, RommUploadScanState.pending);
      expect(svc.tasks, isEmpty);
    });
  });

  // Governing: SPEC-0014 REQ "Concurrency Safety" — "Disconnect mid-batch"
  group('disconnect()', () {
    test('cancels the running batch before the next file starts', () async {
      await rom('a.sfc');
      await rom('b.sfc');
      await seedRom('a.sfc');
      await seedRom('b.sfc');
      svc.uploadGate = Completer<void>();

      final run = provider.uploadMissingForSystem(_snes);
      // Let the batch open its files and start the first upload.
      while (svc.uploads.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(provider.romUpload.isRunning, isTrue);

      await provider.disconnect();
      expect(provider.romUpload.cancelRequested, isTrue);
      svc.uploadGate!.complete();

      final summary = await run;
      expect(provider.romUpload.isRunning, isFalse);
      expect(svc.uploads, ['a.sfc@1'], reason: 'b.sfc never started');
      expect(summary.uploaded, isEmpty);
      expect(summary.end, RommUploadEnd.disconnected);
      expect(summary.failed.map((o) => o.failed), [
        RommUploadFailure.cancelled,
      ]);
      expect(svc.tasks, isEmpty, reason: 'nothing landed, so no scan');
    });

    test('with no batch running is harmless', () async {
      await provider.disconnect();
      expect(provider.romUpload.isRunning, isFalse);
      expect(provider.canUploadRoms, isFalse);
    });
  });
}
