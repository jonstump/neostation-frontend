import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/repositories/game_repository.dart';

import 'database_test_helper.dart';

void main() {
  final dbHelper = DatabaseTestHelper();
  late dynamic db;

  setUp(() async {
    db = await dbHelper.setUp();
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('switch', 'Nintendo Switch', 'switch')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('snes', 'Super Nintendo', 'snes')",
    );
  });

  tearDown(() async {
    await dbHelper.tearDown();
  });

  group('GameRepository', () {
    test('getSystemFolderForGame returns folder name for matching ROM', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', 'switch')",
      );

      final folder = await GameRepository.getSystemFolderForGame('game.nsp');
      expect(folder, 'switch');
    });

    test('getSystemFolderForGame returns null when ROM not found', () async {
      final folder = await GameRepository.getSystemFolderForGame('missing.nsp');
      expect(folder, isNull);
    });

    test('getSystemIdForGame returns app_system_id for matching ROM', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', 'switch')",
      );

      final systemId = await GameRepository.getSystemIdForGame('game.nsp');
      expect(systemId, 'switch');
    });

    test('findSwitchGameByName finds by title_name', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, title_name, title_id, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', 'Super Mario', '0100000000010000', 'switch')",
      );

      final result = await GameRepository.findSwitchGameByName('Mario');
      expect(result, isNotNull);
      expect(result!['title_name'], 'Super Mario');
    });

    test('findRomByFilenamePrefix returns ROM with folder', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, title_name, app_system_id) VALUES ('zelda.smc', '/roms/snes/zelda.smc', 'Zelda', 'snes')",
      );

      final result = await GameRepository.findRomByFilenamePrefix('zelda');
      expect(result, isNotNull);
      expect(result!['filename'], 'zelda.smc');
      expect(result['folder_name'], 'snes');
    });

    test('findRomByFilenamePrefix returns the ROM emulator unique id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, title_name, app_system_id, app_emulator_unique_id) VALUES ('super-mario-all-stars-usa.smc', '/roms/snes/super-mario-all-stars-usa.smc', 'Super Mario All Stars', 'snes', 'snes.ra64.snes9x')",
      );

      final result = await GameRepository.findRomByFilenamePrefix(
        'super-mario-all-stars-usa',
      );
      expect(result, isNotNull);
      expect(result!['emulator_name'], 'snes.ra64.snes9x');
    });

    test('findSwitchGameByTitleId returns match by title_id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, title_name, title_id, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', 'Super Mario', '0100000000010000', 'switch')",
      );

      final result = await GameRepository.findSwitchGameByTitleId(
        '0100000000010000',
      );
      expect(result, isNotNull);
      expect(result!['filename'], 'game.nsp');
    });

    test('getTitleIdForGame returns title_id by filename', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, title_id, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', '0100000000010000', 'switch')",
      );

      final titleId = await GameRepository.getTitleIdForGame(
        'game.nsp',
        'Super Mario',
      );
      expect(titleId, '0100000000010000');
    });

    test('updateGameTitleId persists title_id', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.nsp', '/roms/switch/game.nsp', 'switch')",
      );

      await GameRepository.updateGameTitleId('game.nsp', '0100000000010000');

      final result = await db.rawQuery(
        "SELECT title_id FROM user_roms WHERE filename = 'game.nsp'",
      );
      expect(result.first['title_id'], '0100000000010000');
    });

    test('deleteRomsByFolderPath removes ROMs by prefix', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('game.smc', '/roms/snes/game.smc', 'snes')",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id) VALUES ('other.smc', '/roms/snes/sub/other.smc', 'snes')",
      );

      final deleted = await GameRepository.deleteRomsByFolderPath('/roms/snes');
      expect(deleted, 2);

      final remaining = await db.rawQuery(
        'SELECT COUNT(*) as c FROM user_roms',
      );
      expect(remaining.first['c'], 0);
    });

    test('getFavoriteGames returns only favorites excluding android and music', () async {
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('music', 'Music', 'music')",
      );
      await db.execute(
        "INSERT INTO app_systems (id, real_name, folder_name) VALUES ('android', 'Android', 'android')",
      );

      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-switch.nsp', '/roms/switch/fav-switch.nsp', 'switch', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-snes.smc', '/roms/snes/fav-snes.smc', 'snes', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('not-fav.smc', '/roms/snes/not-fav.smc', 'snes', 0)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-android.apk', 'com.example.app', 'android', 1)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, is_favorite) VALUES ('fav-music.mp3', '/roms/music/fav-music.mp3', 'music', 1)",
      );

      final results = await GameRepository.getFavoriteGames();
      final filenames = results.map((g) => g.filename).toSet();

      expect(filenames, contains('fav-switch.nsp'));
      expect(filenames, contains('fav-snes.smc'));
      expect(filenames, isNot(contains('not-fav.smc')));
      expect(filenames, isNot(contains('fav-android.apk')));
      expect(filenames, isNot(contains('fav-music.mp3')));
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Database Operation Standards"
  group('saveFingerprints', () {
    Future<void> insertRom(String filename, {String? md5}) => db.execute(
      "INSERT INTO user_roms (filename, rom_path, app_system_id, ss_hash) "
      "VALUES ('$filename', '/roms/snes/$filename', 'snes', "
      "${md5 == null ? 'NULL' : "'$md5'"})",
    );

    Future<Map<String, Object?>> rowFor(String filename) async =>
        (await db.query(
          'user_roms',
          columns: [
            'rom_crc32',
            'rom_size',
            'ss_hash',
            'rom_fingerprint_skipped',
          ],
          where: 'filename = ?',
          whereArgs: [filename],
        )).single;

    test('writes results and skip reasons in one call', () async {
      await insertRom('a.zip');
      await insertRom('b.zip');
      await insertRom('c.chd');

      final touched = await GameRepository.saveFingerprints([
        (
          romPath: '/roms/snes/a.zip',
          crc32: 'DEADBEEF',
          md5: null,
          size: 4096,
          skipReason: null,
        ),
        (
          romPath: '/roms/snes/b.zip',
          crc32: 'CAFEBABE',
          md5: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          size: 8192,
          skipReason: null,
        ),
        (
          romPath: '/roms/snes/c.chd',
          crc32: null,
          md5: null,
          size: null,
          skipReason: 'disc',
        ),
      ]);

      expect(touched, 3);
      final a = await rowFor('a.zip');
      expect(a['rom_crc32'], 'DEADBEEF');
      expect(a['rom_size'], 4096);
      expect(a['ss_hash'], isNull);
      expect(a['rom_fingerprint_skipped'], isNull);
      final b = await rowFor('b.zip');
      expect(b['rom_crc32'], 'CAFEBABE');
      expect(b['ss_hash'], 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      final c = await rowFor('c.chd');
      expect(c['rom_crc32'], isNull);
      expect(c['rom_size'], isNull);
      expect(c['rom_fingerprint_skipped'], 'disc');
    });

    test('a cheap result keeps an md5 the full path wrote earlier', () async {
      await insertRom('a.zip', md5: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');

      await GameRepository.saveFingerprints([
        (
          romPath: '/roms/snes/a.zip',
          crc32: 'DEADBEEF',
          md5: null,
          size: 4096,
          skipReason: null,
        ),
      ]);

      expect(
        (await rowFor('a.zip'))['ss_hash'],
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
    });

    test('a result clears an earlier skip marker', () async {
      await insertRom('a.zip');
      await db.execute(
        "UPDATE user_roms SET rom_fingerprint_skipped = 'error' "
        "WHERE filename = 'a.zip'",
      );

      await GameRepository.saveFingerprints([
        (
          romPath: '/roms/snes/a.zip',
          crc32: 'DEADBEEF',
          md5: null,
          size: 1,
          skipReason: null,
        ),
      ]);

      expect((await rowFor('a.zip'))['rom_fingerprint_skipped'], isNull);
    });

    test('nothing to write touches nothing', () async {
      expect(await GameRepository.saveFingerprints(const []), 0);
    });

    test('a batch larger than one chunk is written whole', () async {
      const count = GameRepository.fingerprintBatchSize * 2 + 7;
      for (var i = 0; i < count; i++) {
        await insertRom('g$i.zip');
      }

      final touched = await GameRepository.saveFingerprints([
        for (var i = 0; i < count; i++)
          (
            romPath: '/roms/snes/g$i.zip',
            crc32: i.toRadixString(16).padLeft(8, '0'),
            md5: null,
            size: i,
            skipReason: null,
          ),
      ]);

      expect(touched, count);
      final written = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM user_roms WHERE rom_crc32 IS NOT NULL',
      );
      expect(written.single['n'], count);
      expect((await rowFor('g${count - 1}.zip'))['rom_size'], count - 1);
    });

    test('an unknown path touches no row and is not an error', () async {
      await insertRom('a.zip');

      final touched = await GameRepository.saveFingerprints([
        (
          romPath: '/roms/snes/missing.zip',
          crc32: 'DEADBEEF',
          md5: null,
          size: 1,
          skipReason: null,
        ),
      ]);

      expect(touched, 0);
      expect((await rowFor('a.zip'))['rom_crc32'], isNull);
    });
  });

  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Local Fingerprints In The Link Index"
  group('getAllGames fingerprint columns', () {
    test('exposes crc32, md5, size and the skip marker', () async {
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, ss_hash, "
        "rom_crc32, rom_size, rom_fingerprint_skipped) VALUES "
        "('a.zip', '/roms/snes/a.zip', 'snes', 'abc', 'DEADBEEF', 4096, NULL)",
      );
      await db.execute(
        "INSERT INTO user_roms (filename, rom_path, app_system_id, "
        "rom_fingerprint_skipped) VALUES "
        "('b.chd', '/roms/snes/b.chd', 'snes', 'disc')",
      );

      final games = await GameRepository.getAllGames();
      final a = games.singleWhere((g) => g.filename == 'a.zip');
      expect(a.romCrc32, 'DEADBEEF');
      expect(a.romMd5, 'abc');
      expect(a.romSize, 4096);
      expect(a.fingerprintSkipped, isNull);
      final b = games.singleWhere((g) => g.filename == 'b.chd');
      expect(b.romCrc32, isNull);
      expect(b.romMd5, isNull);
      expect(b.romSize, isNull);
      expect(b.fingerprintSkipped, 'disc');
    });
  });
}
