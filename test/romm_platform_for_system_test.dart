import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/romm_platform.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';

/// [RommProvider.platformForSystem]: the inverse of the platform-to-system
/// resolution the link pass uses, over the loaded platform list.
///
/// Exactly one platform resolving to the system is the answer; none is
/// null; more than one — the alias table folds several RomM slugs onto one
/// local folder — is null too, because uploading into the wrong platform
/// folder is worse than refusing.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Platform
/// Mapping"

class _FakeRommService extends RommService {
  List<RommPlatform> platforms = [];

  @override
  Future<List<RommPlatform>> getPlatforms() async => platforms;
}

class _TestProvider extends RommProvider {
  final RommService fakeService;
  _TestProvider(this.fakeService);

  @override
  RommService get service => fakeService;
}

RommPlatform _platform(int id, String slug, {String? fsSlug}) => RommPlatform(
  id: id,
  name: slug.toUpperCase(),
  slug: slug,
  fsSlug: fsSlug,
  romCount: 1,
);

SystemModel _system(String folder) => SystemModel(
  id: 'sys_$folder',
  folderName: folder,
  realName: folder.toUpperCase(),
  iconImage: '/images/icons/$folder.png',
  color: '#000000',
);

void main() {
  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late _FakeRommService svc;
  late _TestProvider provider;

  Future<void> localSystem(String folder) => db.execute(
    "INSERT OR IGNORE INTO app_systems (id, folder_name) VALUES ('sys_$folder', '$folder')",
  );

  setUp(() async {
    db = await helper.setUp();
    svc = _FakeRommService();
    provider = _TestProvider(svc);
  });

  tearDown(() async {
    provider.dispose();
    await helper.tearDown();
  });

  test('the one platform whose slug is the system folder', () async {
    await localSystem('snes');
    await localSystem('nes');
    svc.platforms = [_platform(1, 'snes'), _platform(2, 'nes')];

    final platform = await provider.platformForSystem(_system('snes'));

    expect(platform?.id, 1);
  });

  test(
    'resolves through fs_slug and the alias table, like the link pass',
    () async {
      await localSystem('genesis');
      await localSystem('gba');
      svc.platforms = [
        _platform(3, 'genesis-slash-megadrive'),
        _platform(4, 'gameboy-advance', fsSlug: 'gba'),
      ];

      expect((await provider.platformForSystem(_system('genesis')))?.id, 3);
      expect((await provider.platformForSystem(_system('gba')))?.id, 4);
    },
  );

  // Governing: SPEC-0014 REQ "Platform Mapping" — scenario "No platform"
  test('null when no platform resolves to the system', () async {
    await localSystem('snes');
    await localSystem('n64');
    svc.platforms = [_platform(1, 'snes')];

    expect(await provider.platformForSystem(_system('n64')), isNull);
  });

  test('null when more than one platform resolves to it', () async {
    await localSystem('ps1');
    // `ps` and `psx` are both aliases of the ps1 folder.
    svc.platforms = [_platform(5, 'ps'), _platform(6, 'psx')];

    expect(await provider.platformForSystem(_system('ps1')), isNull);
  });

  test('a platform list that is empty resolves nothing', () async {
    await localSystem('snes');
    svc.platforms = [];

    expect(await provider.platformForSystem(_system('snes')), isNull);
  });
}
