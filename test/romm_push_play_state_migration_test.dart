import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/config_model.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/repositories/romm_props_outbox_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Migration v166 — the "Push play state to RomM" column — the repository
/// that reads and writes it, and the provider mutator that empties the outbox
/// when the toggle is turned off.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Push
/// Toggle", REQ "Database Operation Standards"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('migration v166', () {
    late Database db;

    /// The "old device" case: `user_config` as v165 left it, without the
    /// push toggle column.
    const v165UserConfig = '''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_scan TEXT,
        romm_upload_screenshots INTEGER DEFAULT 1,
        romm_show_library INTEGER DEFAULT 0
      )
    ''';

    setUp(() => db = sqlite3.openInMemory());
    tearDown(() => db.close());

    Future<void> runV166() => SqliteMigrations.migrateToVersion(db, 166);

    List<String> columns() => db
        .select('PRAGMA table_info(user_config)')
        .map((c) => c['name'].toString())
        .toList();

    test('adds romm_push_play_state defaulting to on', () async {
      db.execute(v165UserConfig);
      expect(columns(), isNot(contains('romm_push_play_state')));

      await runV166();

      expect(columns(), contains('romm_push_play_state'));
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      final row = db.select(
        'SELECT romm_push_play_state FROM user_config WHERE id = 1',
      );
      expect(row.first['romm_push_play_state'], 1);
    });

    test('running twice leaves the column exactly once', () async {
      db.execute(v165UserConfig);

      await runV166();
      await runV166();

      expect(columns().where((c) => c == 'romm_push_play_state'), hasLength(1));
    });

    test('a database without user_config is left alone, not failed', () async {
      await runV166();
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='user_config'",
      );
      expect(tables, isEmpty);
    });

    test('the column constant matches what the migration writes', () async {
      db.execute(v165UserConfig);
      await runV166();
      final info = db
          .select('PRAGMA table_info(user_config)')
          .firstWhere(
            (c) => c['name'] == SqliteMigrations.rommPushPlayStateColumn,
          );
      expect(info['dflt_value'], '1');
      expect(
        SqliteMigrations.rommPushPlayStateColumnType,
        contains('DEFAULT 1'),
      );
    });
  });

  group('ConfigRepository.getRommPushPlayState', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute('INSERT INTO user_config (id) VALUES (1)');
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('defaults to on when the column has not been migrated in', () async {
      await adapter.execute('DROP TABLE user_config');
      await adapter.execute(
        'CREATE TABLE user_config ('
        'id INTEGER PRIMARY KEY CHECK (id = 1), last_scan TEXT)',
      );
      await adapter.execute('INSERT INTO user_config (id) VALUES (1)');

      expect(await ConfigRepository.getRommPushPlayState(), isTrue);
    });

    test('reads the stored 0/1 and writes it back', () async {
      expect(await ConfigRepository.getRommPushPlayState(), isTrue);

      await ConfigRepository.setRommPushPlayState(false);
      expect(await ConfigRepository.getRommPushPlayState(), isFalse);

      await ConfigRepository.setRommPushPlayState(true);
      expect(await ConfigRepository.getRommPushPlayState(), isTrue);
    });

    test('the model round-trips the column under both spellings', () {
      expect(
        ConfigModel.fromJson(const {
          'romm_push_play_state': 0,
        }).rommPushPlayState,
        isFalse,
      );
      expect(
        ConfigModel.fromJson(const {
          'rommPushPlayState': true,
        }).rommPushPlayState,
        isTrue,
      );
      expect(const ConfigModel().rommPushPlayState, isTrue);
      expect(const ConfigModel().toJson()['rommPushPlayState'], isTrue);
      expect(
        const ConfigModel()
            .copyWith(rommPushPlayState: false)
            .rommPushPlayState,
        isFalse,
      );
    });
  });

  group('SqliteConfigProvider.updateRommPushPlayState', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
      await adapter.execute('INSERT INTO user_config (id) VALUES (1)');
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('turning the toggle off persists it and empties the outbox', () async {
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/snes/A.sfc',
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/snes/B.sfc',
        favourite: true,
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 2);

      final provider = SqliteConfigProvider();
      await provider.updateRommPushPlayState(false);

      expect(provider.config.rommPushPlayState, isFalse);
      expect(await ConfigRepository.getRommPushPlayState(), isFalse);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('turning it back on leaves the (empty) outbox alone', () async {
      final provider = SqliteConfigProvider();
      await provider.updateRommPushPlayState(false);
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/snes/A.sfc',
        hidden: true,
      );

      await provider.updateRommPushPlayState(true);

      expect(provider.config.rommPushPlayState, isTrue);
      expect(await ConfigRepository.getRommPushPlayState(), isTrue);
      expect(await RommPropsOutboxRepository.pendingCount(), 1);
    });
  });
}
