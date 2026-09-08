import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/l10n/app_locale_resolver.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/game_repository.dart';
import 'package:neostation/repositories/romm_props_outbox_repository.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/services/game/favorites_service.dart';
import 'package:neostation/services/game/game_session_manager.dart';
import 'package:neostation/services/game/game_visibility_service.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';

/// The RomM play-state write-back end to end: the hooks that queue a row
/// (hide, unhide-all, favourite, session end), the toggle that silences them,
/// and the flush that drains the outbox through a scripted RomM.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props
/// Outbox", REQ "Flush", REQ "Push Toggle", REQ "Localized User-Facing Text"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;

  const zeldaPath = '/roms/snes/zelda.smc';
  const marioPath = '/roms/snes/mario.smc';
  const metroidPath = '/roms/nes/metroid.nes';

  const snes = SystemModel(
    id: 'snes',
    folderName: 'snes',
    realName: 'Super Nintendo',
    iconImage: '',
    color: '#7E57C2',
  );

  GameModel game(String romname, String romPath, {String folder = 'snes'}) =>
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

  Future<void> link(String romname, int romId, {String folder = 'snes'}) =>
      RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: folder,
        rommRomId: romId,
      );

  Future<RommPropsOutboxRow?> rowFor(String romPath) async {
    final rows = await RommPropsOutboxRepository.list();
    for (final row in rows) {
      if (row.romPath == romPath) return row;
    }
    return null;
  }

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
    await db.execute(SqliteMigrations.createAppRommPlaytimeStateTableSql);
    await db.execute('INSERT INTO user_config (id) VALUES (1)');
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('snes', 'Super Nintendo', 'snes')",
    );
    await db.execute(
      "INSERT INTO app_systems (id, real_name, folder_name) "
      "VALUES ('nes', 'Nintendo', 'nes')",
    );
    for (final (name, path, system) in const [
      ('zelda.smc', zeldaPath, 'snes'),
      ('mario.smc', marioPath, 'snes'),
      ('metroid.nes', metroidPath, 'nes'),
    ]) {
      await db.execute(
        'INSERT INTO user_roms (filename, rom_path, app_system_id) '
        "VALUES ('$name', '$path', '$system')",
      );
    }
  });

  tearDown(() async {
    await helper.tearDown();
  });

  group('the hide hook', () {
    test('hiding a linked game queues hidden = true', () async {
      await link('zelda.smc', 42);

      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: true,
        romPath: zeldaPath,
      );

      final local = await GameRepository.getSingleGame('snes', 'zelda.smc');
      expect(local!.isHidden, isTrue);
      final row = await rowFor(zeldaPath);
      expect(row, isNotNull);
      expect(row!.hidden, isTrue);
      expect(row.favourite, isNull);
      expect(row.touchLastPlayed, isFalse);
    });

    test('hide then unhide coalesces into hidden = false', () async {
      await link('zelda.smc', 42);

      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: true,
        romPath: zeldaPath,
      );
      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: false,
        romPath: zeldaPath,
      );

      expect(await RommPropsOutboxRepository.pendingCount(), 1);
      expect((await rowFor(zeldaPath))!.hidden, isFalse);
    });

    test('resolves the rom path when the caller has none', () async {
      await link('zelda.smc', 42);

      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: true,
      );

      expect((await rowFor(zeldaPath))!.hidden, isTrue);
    });

    test('an unlinked game is hidden locally but never queued', () async {
      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'mario.smc',
        hidden: true,
        romPath: marioPath,
      );

      final local = await GameRepository.getSingleGame('snes', 'mario.smc');
      expect(local!.isHidden, isTrue);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('the toggle being off queues nothing', () async {
      await link('zelda.smc', 42);
      await db.execute('UPDATE user_config SET romm_push_play_state = 0');

      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: true,
        romPath: zeldaPath,
      );

      final local = await GameRepository.getSingleGame('snes', 'zelda.smc');
      expect(local!.isHidden, isTrue);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });

  group('unhide all', () {
    setUp(() async {
      await link('zelda.smc', 42);
      await link('metroid.nes', 7, folder: 'nes');
      for (final (folder, name) in const [
        ('snes', 'zelda.smc'),
        ('snes', 'mario.smc'),
        ('nes', 'metroid.nes'),
      ]) {
        await GameRepository.setGameHidden(folder, name, true);
      }
    });

    test('for one system queues only its linked games', () async {
      final restored = await GameVisibilityService.unhideAll(systemId: 'snes');

      expect(restored, 2);
      expect(await GameRepository.getHiddenGames(systemId: 'snes'), isEmpty);
      expect(
        await GameRepository.getHiddenGames(systemId: 'nes'),
        hasLength(1),
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 1);
      expect((await rowFor(zeldaPath))!.hidden, isFalse);
    });

    test('for the whole library queues every linked game', () async {
      final restored = await GameVisibilityService.unhideAll();

      expect(restored, 3);
      expect(await GameRepository.getHiddenGames(), isEmpty);
      final rows = await RommPropsOutboxRepository.list();
      expect(
        rows.map((r) => r.romPath),
        unorderedEquals([zeldaPath, metroidPath]),
      );
      expect(rows.every((r) => r.hidden == false), isTrue);
    });

    test('queues nothing when the toggle is off', () async {
      await db.execute('UPDATE user_config SET romm_push_play_state = 0');

      await GameVisibilityService.unhideAll();

      expect(await GameRepository.getHiddenGames(), isEmpty);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });

  group('the favourite hook', () {
    test('toggling a linked game queues the new value each time', () async {
      await link('zelda.smc', 42);
      final zelda = game('zelda.smc', zeldaPath);

      await FavoritesService.toggleFavorite(zelda);
      expect((await rowFor(zeldaPath))!.favourite, isTrue);
      final local = await GameRepository.getSingleGame('snes', 'zelda.smc');
      expect(local!.isFavorite, isTrue);

      await FavoritesService.toggleFavorite(zelda);
      expect(await RommPropsOutboxRepository.pendingCount(), 1);
      expect((await rowFor(zeldaPath))!.favourite, isFalse);
    });

    test('an unlinked game is favourited locally but never queued', () async {
      await FavoritesService.toggleFavorite(game('mario.smc', marioPath));

      final local = await GameRepository.getSingleGame('snes', 'mario.smc');
      expect(local!.isFavorite, isTrue);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('a favourite never clears a pending hide', () async {
      await link('zelda.smc', 42);
      await GameVisibilityService.setHidden(
        systemFolder: 'snes',
        romname: 'zelda.smc',
        hidden: true,
        romPath: zeldaPath,
      );

      await FavoritesService.toggleFavorite(game('zelda.smc', zeldaPath));

      final row = (await rowFor(zeldaPath))!;
      expect(row.hidden, isTrue);
      expect(row.favourite, isTrue);
    });

    test('the toggle being off queues nothing', () async {
      await link('zelda.smc', 42);
      await db.execute('UPDATE user_config SET romm_push_play_state = 0');

      await FavoritesService.toggleFavorite(game('zelda.smc', zeldaPath));

      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });

  group('the session-end hook', () {
    Future<void> playAndExit(
      GameModel g, {
      Duration length = const Duration(minutes: 1),
    }) async {
      GameSessionManager.registerGameLaunch(snes, g);
      GameSessionManager.debugBackdateSession(length);
      await GameSessionManager.endGameSession();
    }

    test('a finished session queues touch_last_played', () async {
      await link('zelda.smc', 42);

      await playAndExit(game('zelda.smc', zeldaPath));

      final row = await rowFor(zeldaPath);
      expect(row, isNotNull);
      expect(row!.touchLastPlayed, isTrue);
      expect(row.hidden, isNull);
      expect(row.favourite, isNull);
    });

    test('a bounced launch (under the floor) queues nothing', () async {
      await link('zelda.smc', 42);

      await playAndExit(
        game('zelda.smc', zeldaPath),
        length: const Duration(seconds: 2),
      );

      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('an unlinked game queues nothing', () async {
      await playAndExit(game('mario.smc', marioPath));

      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('the toggle being off queues nothing', () async {
      await link('zelda.smc', 42);
      await db.execute('UPDATE user_config SET romm_push_play_state = 0');

      await playAndExit(game('zelda.smc', zeldaPath));

      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });

  group('the flush', () {
    final requests = <http.Request>[];
    late _FakeBrowse browse;

    /// The calls the flush itself made. An API-key connection verifies itself
    /// once (heartbeat plus `GET /api/users/me`) before its first
    /// authenticated call; those are not what these tests are about.
    List<http.Request> calls() => requests
        .where(
          (r) =>
              !const {'/api/heartbeat', '/api/users/me'}.contains(r.url.path),
        )
        .toList();

    http.Response json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json'},
    );

    /// A RomM that answers with [respond] for everything but the API-key
    /// verification, which always succeeds without a heartbeat (so every
    /// capability is `unknown` and every scope group is `unknown` — nothing
    /// gates).
    void serve(Future<http.Response> Function(http.Request) respond) {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/heartbeat':
              return http.Response('not found', 404);
            case '/api/users/me':
              return json(200, {'id': 1, 'username': 'jon'});
            default:
              return await respond(request);
          }
        }),
      );
    }

    /// A server that accepts everything: props writes, and a favourites
    /// collection that does not exist yet and gets created as id 9.
    Future<http.Response> happyServer(http.Request request) async {
      final path = request.url.path;
      if (path.startsWith('/api/roms/') && path.endsWith('/props')) {
        return json(200, {'hidden': true});
      }
      if (path == '/api/collections' && request.method == 'GET') {
        return json(200, <Object>[]);
      }
      if (path == '/api/collections' && request.method == 'POST') {
        return json(201, {'id': 9, 'name': 'Favorites', 'is_favorite': true});
      }
      if (path == '/api/collections/9/roms') {
        return json(200, {'id': 9});
      }
      return http.Response('not found', 404);
    }

    setUp(() {
      requests.clear();
      final service = RommService()
        ..configure(serverUrl: 'https://romm.local', apiKey: 'rmm_deadbeef');
      browse = _FakeBrowse(service);
    });

    tearDown(() {
      RommService.debugUseHttpClient(null);
      browse.dispose();
    });

    test(
      'a hide is sent as a bare {"hidden": true} and the row goes',
      () async {
        await link('zelda.smc', 42);
        await RommPropsOutboxRepository.upsert(
          romPath: zeldaPath,
          hidden: true,
        );
        serve(happyServer);

        final summary = await browse.flushPlayStateOutbox();

        expect(summary.pushed, 1);
        final put = calls().single;
        expect(put.method, 'PUT');
        expect(put.url.path, '/api/roms/42/props');
        expect(put.url.queryParameters, isEmpty);
        expect(jsonDecode(put.body), {'hidden': true});
        expect(await RommPropsOutboxRepository.pendingCount(), 0);
      },
    );

    test('a session end is sent as update_last_played=true', () async {
      await link('zelda.smc', 42);
      await RommPropsOutboxRepository.upsert(
        romPath: zeldaPath,
        touchLastPlayed: true,
      );
      serve(happyServer);

      await browse.flushPlayStateOutbox();

      final put = calls().single;
      expect(put.url.path, '/api/roms/42/props');
      expect(put.url.queryParameters, {'update_last_played': 'true'});
      expect(jsonDecode(put.body), isEmpty);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test(
      'a favourite creates the collection with the localized name and adds',
      () async {
        await link('zelda.smc', 42);
        await RommPropsOutboxRepository.upsert(
          romPath: zeldaPath,
          favourite: true,
        );
        serve(happyServer);

        final summary = await browse.flushPlayStateOutbox();

        expect(summary.pushed, 1);
        final made = calls();
        expect(made.map((r) => '${r.method} ${r.url.path}'), [
          'GET /api/collections',
          'POST /api/collections',
          'POST /api/collections/9/roms',
        ]);
        final create = made[1];
        expect(create.url.queryParameters, {'is_favorite': 'true'});
        expect(create.body, contains('name="name"'));
        expect(
          create.body,
          contains(appLocaleEn[AppLocale.rommFavoritesCollectionName]),
        );
        expect(jsonDecode(made[2].body), {
          'rom_ids': [42],
        });
        expect(await RommPropsOutboxRepository.pendingCount(), 0);
      },
    );

    test('an un-favourite removes through the existing collection', () async {
      await link('zelda.smc', 42);
      await RommPropsOutboxRepository.upsert(
        romPath: zeldaPath,
        favourite: false,
      );
      serve((request) async {
        if (request.url.path == '/api/collections' && request.method == 'GET') {
          return json(200, [
            {'id': 3, 'name': 'Mine', 'is_favorite': false},
            {'id': 5, 'name': 'Favs', 'is_favorite': true},
          ]);
        }
        if (request.url.path == '/api/collections/5/roms') {
          return json(200, {'id': 5});
        }
        return http.Response('not found', 404);
      });

      await browse.flushPlayStateOutbox();

      final made = calls();
      expect(made.map((r) => '${r.method} ${r.url.path}'), [
        'GET /api/collections',
        'DELETE /api/collections/5/roms',
      ]);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test(
      'a row with both intents makes one props call and one favourites call',
      () async {
        await link('zelda.smc', 42);
        await RommPropsOutboxRepository.upsert(
          romPath: zeldaPath,
          hidden: false,
          favourite: true,
          touchLastPlayed: true,
        );
        serve(happyServer);

        await browse.flushPlayStateOutbox();

        final made = calls();
        expect(made.first.method, 'PUT');
        expect(made.first.url.path, '/api/roms/42/props');
        expect(jsonDecode(made.first.body), {'hidden': false});
        expect(made.first.url.queryParameters, {'update_last_played': 'true'});
        expect(
          made.where((r) => r.url.path == '/api/collections/9/roms'),
          hasLength(1),
        );
        expect(await RommPropsOutboxRepository.pendingCount(), 0);
      },
    );

    test('rows go out oldest change first', () async {
      await link('zelda.smc', 42);
      await link('metroid.nes', 7, folder: 'nes');
      await RommPropsOutboxRepository.upsert(
        romPath: metroidPath,
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve(happyServer);

      await browse.flushPlayStateOutbox();

      expect(calls().map((r) => r.url.path), [
        '/api/roms/7/props',
        '/api/roms/42/props',
      ]);
    });

    test('a 404 for the ROM drops the row without retry', () async {
      await link('zelda.smc', 42);
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve((_) async => http.Response('gone', 404));

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.dropped, 1);
      expect(summary.kept, 0);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('a socket error keeps every row and stops the flush', () async {
      await link('zelda.smc', 42);
      await link('metroid.nes', 7, folder: 'nes');
      await RommPropsOutboxRepository.upsert(
        romPath: metroidPath,
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve((_) async => throw const SocketException('unreachable'));

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.pushed, 0);
      expect(summary.kept, 2);
      // Only the first row was attempted; the rest were left for next time.
      expect(calls(), hasLength(1));
      expect(await RommPropsOutboxRepository.pendingCount(), 2);

      // And the next flush, against a healthy server, delivers both.
      requests.clear();
      serve(happyServer);
      final retry = await browse.flushPlayStateOutbox();
      expect(retry.pushed, 2);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('a server error keeps that row and moves on to the next', () async {
      await link('zelda.smc', 42);
      await link('metroid.nes', 7, folder: 'nes');
      await RommPropsOutboxRepository.upsert(
        romPath: metroidPath,
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve((request) async {
        if (request.url.path == '/api/roms/7/props') {
          return http.Response('boom', 500);
        }
        return happyServer(request);
      });

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.pushed, 1);
      expect(summary.kept, 1);
      expect(calls(), hasLength(2));
      final left = await RommPropsOutboxRepository.list();
      expect(left.single.romPath, metroidPath);
    });

    test('a disconnect between rows stops the flush', () async {
      await link('zelda.smc', 42);
      await link('metroid.nes', 7, folder: 'nes');
      await RommPropsOutboxRepository.upsert(
        romPath: metroidPath,
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve((request) async {
        browse.connected = false;
        return happyServer(request);
      });

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.pushed, 1);
      expect(summary.kept, 1);
      expect(calls(), hasLength(1));
      final left = await RommPropsOutboxRepository.list();
      expect(left.single.romPath, zeldaPath);
    });

    test('nothing is sent while disconnected', () async {
      await link('zelda.smc', 42);
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      serve(happyServer);
      browse.connected = false;

      final summary = await browse.flushPlayStateOutbox();

      expect(summary, (pushed: 0, dropped: 0, kept: 0));
      expect(requests, isEmpty);
      expect(await RommPropsOutboxRepository.pendingCount(), 1);
    });

    test('a row whose game lost its link is dropped, not sent', () async {
      await RommPropsOutboxRepository.upsert(romPath: marioPath, hidden: true);
      await RommPropsOutboxRepository.upsert(
        romPath: '/gone/x.sfc',
        hidden: true,
      );
      serve(happyServer);

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.dropped, 2);
      expect(calls(), isEmpty);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('a server below 4.9.0 sends nothing and drops the row', () async {
      await link('zelda.smc', 42);
      await RommPropsOutboxRepository.upsert(romPath: zeldaPath, hidden: true);
      RommService.debugUseHttpClient(
        MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/heartbeat':
              return json(200, {
                'VERSION': '4.8.0',
                'SYSTEM': {'VERSION': '4.8.0'},
              });
            case '/api/users/me':
              return json(200, {'id': 1, 'username': 'jon'});
            default:
              return await happyServer(request);
          }
        }),
      );
      await browse.service.fetchHeartbeat(serverUrl: 'https://romm.local');
      expect(
        browse.service.supports(RommFeature.romPropsBareBody),
        RommFeatureSupport.unsupported,
      );

      final summary = await browse.flushPlayStateOutbox();

      expect(summary.pushed, 0);
      expect(summary.dropped, 1);
      expect(calls(), isEmpty);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });

  group('localized text', () {
    const locales = <String, Map<String, dynamic>>{
      'en': appLocaleEn,
      'es': appLocaleEs,
      'pt': appLocalePt,
      'ru': appLocaleRu,
      'zh': appLocaleZh,
      'zh_Hant': appLocaleZhHant,
      'fr': appLocaleFr,
      'de': appLocaleDe,
      'it': appLocaleIt,
      'id': appLocaleId,
      'ja': appLocaleJa,
      'ko': appLocaleKo,
    };

    const keys = <String>[
      AppLocale.rommPushPlayState,
      AppLocale.rommPushPlayStateHint,
      AppLocale.rommFavoritesCollectionName,
    ];

    final placeholder = RegExp(r'\{[a-zA-Z]+\}');
    Set<String> tokensOf(String value) =>
        placeholder.allMatches(value).map((m) => m.group(0)!).toSet();

    for (final entry in locales.entries) {
      test('${entry.key} translates every SPEC-0013 key', () {
        for (final key in keys) {
          final value = entry.value[key];
          expect(
            value,
            isA<String>(),
            reason: '$key is missing from app_locale_${entry.key}.dart',
          );
          expect(
            (value as String).trim(),
            isNotEmpty,
            reason: '$key is blank in app_locale_${entry.key}.dart',
          );
          expect(
            tokensOf(value),
            tokensOf(appLocaleEn[key] as String),
            reason: '$key has drifted placeholders in ${entry.key}',
          );
        }
      });

      if (entry.key != 'en') {
        test('${entry.key} is not a copy of the English sentences', () {
          final copied = [
            for (final key in keys)
              if ((appLocaleEn[key] as String).split(' ').length > 3 &&
                  entry.value[key] == appLocaleEn[key])
                key,
          ];
          expect(copied, isEmpty);
        });
      }
    }

    test('the favourites name resolves without a context', () {
      // No language has been chosen in a unit test, so English stands in.
      expect(
        resolveAppLocale(AppLocale.rommFavoritesCollectionName),
        appLocaleEn[AppLocale.rommFavoritesCollectionName],
      );
      expect(resolveAppLocale('no_such_key'), 'no_such_key');
    });
  });
}

/// A [RommProvider] whose connection state a test controls and whose service
/// is the one wired to the scripted HTTP client.
class _FakeBrowse extends RommProvider {
  final RommService fakeService;
  bool connected = true;
  _FakeBrowse(this.fakeService);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fakeService;
}
