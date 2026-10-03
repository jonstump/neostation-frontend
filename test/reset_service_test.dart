import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/reset_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';

/// The media cache's folder name under the user-data directory. Hardcoded in
/// `ConfigService.getMediaPath`, so the tests mirror it.
const String mediaFolderName = 'media';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CredentialStore.debugUseBackends(secure: MemoryBackend(), file: null);
  });

  tearDown(() {
    CredentialStore.debugReset();
  });

  /// A fake custom user-data folder, registered in preferences the way the
  /// setup wizard does, so every path resolver in the service lands in it.
  Future<Directory> fakeUserDataFolder() async {
    final dir = await Directory.systemTemp.createTemp('reset_test_');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(UserDataLocationService.customPathKey, dir.path);
    return dir;
  }

  Future<void> writeCredential(String key) async {
    await CredentialStore.write(key, 'secret-value-for-$key');
  }

  group('clearCredentials', () {
    test('clears every key the app stores from every backend', () async {
      final secure = MemoryBackend();
      final file = MemoryBackend();
      CredentialStore.debugUseBackends(secure: secure, file: file);
      for (final key in const [
        'romm_password',
        'romm_api_key',
        'screenscraper_password',
        'ra_api_key',
        'auth_token',
      ]) {
        await writeCredential(key);
      }

      await ResetService.clearCredentials();

      for (final key in const [
        'romm_password',
        'romm_api_key',
        'screenscraper_password',
        'ra_api_key',
        'auth_token',
      ]) {
        expect(await CredentialStore.read(key), isNull, reason: key);
        expect(secure.values, isNot(contains(key)));
        expect(file.values, isNot(contains(key)));
      }
    });
  });

  group('clearPreferences', () {
    test('removes every SharedPreferences key the app wrote', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        UserDataLocationService.customPathKey,
        '/unused/after/reset',
      );
      await prefs.setInt('startup_theme_background', 0xFF15191e);
      await prefs.setInt('startup_theme_foreground', 0xFFecf9ff);
      await prefs.setInt('startup_theme_primary', 0xFF605dff);
      await prefs.setBool('game_session_active', true);
      await prefs.setString('game_session_system_folder', 'nes');
      await prefs.setString('game_session_filename', 'game.nes');
      await prefs.setInt('game_session_start_timestamp', 1234);
      await prefs.setInt('game_session_played_seconds', 5678);
      await prefs.setBool('game_session_skip_startup_scan', true);
      await prefs.setBool('setup_completed_prefs', true);

      await ResetService.clearPreferences();

      final keys = prefs.getKeys();
      expect(keys, isNot(contains(UserDataLocationService.customPathKey)));
      expect(keys, isNot(contains('startup_theme_background')));
      expect(keys, isNot(contains('startup_theme_foreground')));
      expect(keys, isNot(contains('startup_theme_primary')));
      expect(keys, isNot(contains('game_session_active')));
      expect(keys, isNot(contains('game_session_system_folder')));
      expect(keys, isNot(contains('game_session_filename')));
      expect(keys, isNot(contains('game_session_start_timestamp')));
      expect(keys, isNot(contains('game_session_played_seconds')));
      expect(keys, isNot(contains('game_session_skip_startup_scan')));
      expect(keys, isNot(contains('setup_completed_prefs')));
    });
  });

  group('clearDatabase', () {
    test('deletes the database and its sidecars, not the folder', () async {
      final dir = await fakeUserDataFolder();
      for (final name in const [
        'data.sqlite',
        'data.sqlite-journal',
        'data.sqlite-wal',
        'data.sqlite-shm',
      ]) {
        await File(p.join(dir.path, name)).writeAsString('x');
      }

      await ResetService.clearDatabase();

      for (final name in const [
        'data.sqlite',
        'data.sqlite-journal',
        'data.sqlite-wal',
        'data.sqlite-shm',
      ]) {
        expect(
          File(p.join(dir.path, name)).existsSync(),
          isFalse,
          reason: name,
        );
      }
      expect(dir.existsSync(), isTrue);
    });
  });

  group('clearMediaCache', () {
    test(
      'deletes the media directory including the RomM cover cache',
      () async {
        final dir = await fakeUserDataFolder();
        final covers = p.join(
          dir.path,
          mediaFolderName,
          RommCoverPath.directoryName,
        );
        Directory(covers).createSync(recursive: true);
        await File(p.join(covers, '1.jpg')).writeAsString('cover');
        final rom = p.join(dir.path, 'roms', 'game.nes');
        Directory(p.dirname(rom)).createSync(recursive: true);
        await File(rom).writeAsBytes([1, 2, 3]);

        await ResetService.clearMediaCache();

        expect(
          Directory(p.join(dir.path, mediaFolderName)).existsSync(),
          isFalse,
        );
        expect(File(rom).existsSync(), isTrue);
      },
    );
  });

  group('clearLog', () {
    test('deletes the log file and its rotated copy', () async {
      final dir = await fakeUserDataFolder();
      await File(p.join(dir.path, 'app.log')).writeAsString('log lines');
      await File(p.join(dir.path, 'app.log.old')).writeAsString('old log');

      await ResetService.clearLog();

      expect(File(p.join(dir.path, 'app.log')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'app.log.old')).existsSync(), isFalse);
    });
  });

  group('steps', () {
    test('run in the order the spec requires', () async {
      final steps = await ResetService.steps();
      expect(steps.map((s) => s.store), [
        ResetService.storeCredentials,
        ResetService.storePreferences,
        ResetService.storeDatabase,
        ResetService.storeMediaCache,
        ResetService.storeLog,
        ResetService.storeSafGrants,
      ]);
    });
  });

  group('runSteps', () {
    test(
      'continues past a throwing clearer and names it in the summary',
      () async {
        final dir = await fakeUserDataFolder();
        final logFile = File(p.join(dir.path, 'app.log'));
        await logFile.writeAsString('log lines');

        var logCleared = false;
        final summary = await ResetService.runSteps([
          const ResetStep(ResetService.storeMediaCache, _throwingClearer),
          ResetStep(ResetService.storeLog, () async {
            await ResetService.clearLog();
            logCleared = true;
          }),
        ]);

        expect(summary.failed.keys, [ResetService.storeMediaCache]);
        expect(summary.failed[ResetService.storeMediaCache], contains('boom'));
        expect(summary.cleared, [ResetService.storeLog]);
        expect(logCleared, isTrue);
        expect(logFile.existsSync(), isFalse);
      },
    );
  });

  group('resetAll', () {
    test(
      'clears every store and leaves a custom folder\'s roms untouched',
      () async {
        final dir = await fakeUserDataFolder();
        await File(p.join(dir.path, 'data.sqlite')).writeAsString('db');
        await File(p.join(dir.path, 'data.sqlite-journal')).writeAsString('j');
        final mediaFile = File(
          p.join(dir.path, mediaFolderName, 'box2D', 'art.png'),
        );
        await mediaFile.create(recursive: true);
        await mediaFile.writeAsBytes([1]);
        await File(p.join(dir.path, 'app.log')).writeAsString('log');
        final rom = File(p.join(dir.path, 'roms', 'snes', 'game.sfc'));
        await rom.create(recursive: true);
        await rom.writeAsBytes([2]);
        final bios = File(p.join(dir.path, 'bios', 'scph.bin'));
        await bios.create(recursive: true);
        await bios.writeAsBytes([3]);

        final summary = await ResetService.resetAll();

        expect(summary.isFullyCleared, isTrue, reason: '${summary.failed}');
        expect(
          summary.cleared,
          containsAllInOrder([
            ResetService.storeCredentials,
            ResetService.storePreferences,
            ResetService.storeDatabase,
            ResetService.storeMediaCache,
            ResetService.storeLog,
            ResetService.storeSafGrants,
          ]),
        );
        expect(File(p.join(dir.path, 'data.sqlite')).existsSync(), isFalse);
        expect(
          File(p.join(dir.path, 'data.sqlite-journal')).existsSync(),
          isFalse,
        );
        expect(
          Directory(p.join(dir.path, mediaFolderName)).existsSync(),
          isFalse,
        );
        expect(File(p.join(dir.path, 'app.log')).existsSync(), isFalse);
        expect(rom.existsSync(), isTrue);
        expect(bios.existsSync(), isTrue);
        expect(dir.existsSync(), isTrue);
        // The custom path was forgotten, so the wizard asks for it again.
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(UserDataLocationService.customPathKey), isNull);
      },
    );

    test('a locked media file does not stop the other clearers', () async {
      final dir = await fakeUserDataFolder();
      final mediaDir = Directory(p.join(dir.path, mediaFolderName));
      await mediaDir.create(recursive: true);
      await File(p.join(mediaDir.path, 'art.png')).writeAsBytes([1]);
      final logFile = File(p.join(dir.path, 'app.log'));
      await logFile.writeAsString('log lines');

      // A directory without write permission refuses every deletion inside
      // it, standing in for the locked-file scenario on a POSIX host.
      await Process.run('chmod', ['555', mediaDir.path]);
      try {
        final summary = await ResetService.resetAll();

        expect(summary.failed.keys, [ResetService.storeMediaCache]);
        // The log and the grants after it were still cleared.
        expect(summary.cleared, contains(ResetService.storeLog));
        expect(summary.cleared, contains(ResetService.storeSafGrants));
        expect(logFile.existsSync(), isFalse);
        expect(dir.existsSync(), isTrue);
      } finally {
        await Process.run('chmod', ['755', mediaDir.path]);
      }
    });
  });
}

Future<void> _throwingClearer() async {
  throw StateError('boom');
}

/// The RomM cover cache's directory name, kept here because the real constant
/// lives under `lib/services/romm/`, which a unit test about paths need not
/// drag in.
class RommCoverPath {
  static const String directoryName = 'romm_covers';
}
