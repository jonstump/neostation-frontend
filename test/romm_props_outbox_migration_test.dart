import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/romm_props_outbox_repository.dart';
import 'package:neostation/services/romm/romm_props_outbox_service.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Migration v164 — the play-state push outbox table — and the repository that
/// coalesces writes into it.
///
/// Governing: ADR-0013 (push play state to RomM), SPEC-0013 REQ "Props
/// Outbox", REQ "Database Operation Standards"
void main() {
  group('migration v164', () {
    late Database db;

    setUp(() => db = sqlite3.openInMemory());
    tearDown(() => db.close());

    Future<void> runV164() => SqliteMigrations.migrateToVersion(db, 164);

    List<String> columnsOf(String table) => db
        .select('PRAGMA table_info($table)')
        .map((c) => c['name'].toString())
        .toList();

    bool tableExists(String name) => db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [name],
    ).isNotEmpty;

    test('creates the outbox keyed by rom_path', () async {
      await runV164();

      expect(tableExists('app_romm_props_outbox'), isTrue);
      expect(columnsOf('app_romm_props_outbox'), [
        'rom_path',
        'hidden',
        'favourite',
        'touch_last_played',
        'updated_at',
      ]);

      final key = db
          .select('PRAGMA table_info(app_romm_props_outbox)')
          .where((c) => (c['pk'] as int) > 0)
          .map((c) => c['name'].toString());
      expect(key, ['rom_path']);
    });

    test('the intent columns are nullable and the flag is not', () async {
      await runV164();

      final info = {
        for (final c in db.select('PRAGMA table_info(app_romm_props_outbox)'))
          c['name'].toString(): c,
      };
      expect(info['hidden']!['notnull'], 0);
      expect(info['favourite']!['notnull'], 0);
      expect(info['touch_last_played']!['notnull'], 1);

      db.execute(
        "INSERT INTO app_romm_props_outbox (rom_path) VALUES ('/roms/a.nes')",
      );
      final row = db.select('SELECT * FROM app_romm_props_outbox').single;
      expect(row['hidden'], isNull);
      expect(row['favourite'], isNull);
      expect(row['touch_last_played'], 0);
    });

    test('running twice leaves the table exactly once', () async {
      await runV164();
      await runV164();

      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='app_romm_props_outbox'",
        ),
        hasLength(1),
      );
    });

    test('a fresh database gets it from the CREATE statement', () {
      db.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
      expect(tableExists('app_romm_props_outbox'), isTrue);
    });
  });

  group('RommPropsOutboxRepository', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    const romPath = '/roms/snes/Game.sfc';

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('queues a hide and reads it back', () async {
      expect(
        await RommPropsOutboxRepository.upsert(romPath: romPath, hidden: true),
        isTrue,
      );

      final rows = await RommPropsOutboxRepository.list();
      expect(rows, hasLength(1));
      expect(rows.single.romPath, romPath);
      expect(rows.single.hidden, isTrue);
      expect(rows.single.favourite, isNull);
      expect(rows.single.touchLastPlayed, isFalse);
      expect(rows.single.updatedAt, isNotNull);
    });

    test('hide then unhide coalesces into one row saying hidden = 0', () async {
      await RommPropsOutboxRepository.upsert(romPath: romPath, hidden: true);
      await RommPropsOutboxRepository.upsert(romPath: romPath, hidden: false);

      final rows = await RommPropsOutboxRepository.list();
      expect(rows, hasLength(1));
      expect(rows.single.hidden, isFalse);
    });

    test('a favourite toggle never clears a pending hide', () async {
      await RommPropsOutboxRepository.upsert(romPath: romPath, hidden: true);
      await RommPropsOutboxRepository.upsert(romPath: romPath, favourite: true);

      final row = (await RommPropsOutboxRepository.list()).single;
      expect(row.hidden, isTrue);
      expect(row.favourite, isTrue);
    });

    test('touch_last_played is sticky once set', () async {
      await RommPropsOutboxRepository.upsert(
        romPath: romPath,
        touchLastPlayed: true,
      );
      await RommPropsOutboxRepository.upsert(romPath: romPath, hidden: true);

      final row = (await RommPropsOutboxRepository.list()).single;
      expect(row.touchLastPlayed, isTrue);
      expect(row.hidden, isTrue);
    });

    test('an empty path or an empty change writes nothing', () async {
      expect(
        await RommPropsOutboxRepository.upsert(romPath: '', hidden: true),
        isFalse,
      );
      expect(await RommPropsOutboxRepository.upsert(romPath: romPath), isFalse);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('rows come back oldest change first', () async {
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/a.nes',
        hidden: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/b.nes',
        hidden: true,
      );

      final rows = await RommPropsOutboxRepository.list();
      expect(rows.map((r) => r.romPath), ['/roms/a.nes', '/roms/b.nes']);
    });

    test('delete removes one row and clear removes them all', () async {
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/a.nes',
        hidden: true,
      );
      await RommPropsOutboxRepository.upsert(
        romPath: '/roms/b.nes',
        favourite: true,
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 2);

      expect(await RommPropsOutboxRepository.delete('/roms/a.nes'), 1);
      expect(await RommPropsOutboxRepository.delete('/roms/a.nes'), 0);
      expect(await RommPropsOutboxRepository.pendingCount(), 1);

      expect(await RommPropsOutboxRepository.clear(), 1);
      expect(await RommPropsOutboxRepository.list(), isEmpty);
    });
  });

  group('RommPropsOutboxService', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    const romPath = '/roms/snes/Game.sfc';

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute(SqliteMigrations.createAppRommPropsOutboxTableSql);
      await adapter.execute(SqliteMigrations.createAppRommRomMapTableSql);
    });

    tearDown(() async {
      await helper.tearDown();
    });

    Future<void> link(String romname, String folder, int romId) =>
        adapter.execute(
          'INSERT INTO app_romm_rom_map '
          '(romname, system_folder, romm_rom_id) VALUES (?, ?, ?)',
          [romname, folder, romId],
        );

    test('queues a linked game', () async {
      await link('Game.sfc', 'snes', 5);

      expect(
        await RommPropsOutboxService.queue(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          romPath: romPath,
          pushEnabled: true,
          favourite: true,
        ),
        isTrue,
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 1);
    });

    test('an unlinked game is never queued', () async {
      expect(
        await RommPropsOutboxService.queue(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          romPath: romPath,
          pushEnabled: true,
          favourite: true,
        ),
        isFalse,
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('the push toggle being off queues nothing', () async {
      await link('Game.sfc', 'snes', 5);

      expect(
        await RommPropsOutboxService.queue(
          romname: 'Game.sfc',
          systemFolder: 'snes',
          romPath: romPath,
          pushEnabled: false,
          hidden: true,
        ),
        isFalse,
      );
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });

    test('queueMany skips the unlinked games and counts the rest', () async {
      await link('A.sfc', 'snes', 1);
      await link('B.sfc', 'snes', 2);

      final queued = await RommPropsOutboxService.queueMany(
        [
          (romname: 'A.sfc', systemFolder: 'snes', romPath: '/roms/A.sfc'),
          (romname: 'B.sfc', systemFolder: 'snes', romPath: '/roms/B.sfc'),
          (romname: 'C.sfc', systemFolder: 'snes', romPath: '/roms/C.sfc'),
        ],
        pushEnabled: true,
        hidden: false,
      );

      expect(queued, 2);
      expect(await RommPropsOutboxRepository.pendingCount(), 2);

      expect(await RommPropsOutboxService.discardAll(), 2);
      expect(await RommPropsOutboxRepository.pendingCount(), 0);
    });
  });
}
