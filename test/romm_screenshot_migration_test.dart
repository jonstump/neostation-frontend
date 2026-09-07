import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/repositories/config_repository.dart';
import 'package:neostation/repositories/romm_screenshot_map_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database_test_helper.dart';

/// Migration v163 — the screenshot ledger table, the upload toggle column and
/// the two RetroArch screenshot columns — and the ledger repository that reads
/// and writes it.
///
/// Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ
/// "Database Operation Standards"
void main() {
  group('migration v163', () {
    late Database db;

    /// The "old device" case: `user_retroarch_config` exactly as migration
    /// v35 created it, without either screenshot column.
    const v35RetroArchTable = '''
      CREATE TABLE user_retroarch_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        config_path TEXT NOT NULL,
        system_directory TEXT,
        savefile_directory TEXT,
        savestate_directory TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''';

    const v161UserConfig = '''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_scan TEXT,
        subfolder_view_all INTEGER DEFAULT 0
      )
    ''';

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() {
      db.close();
    });

    Future<void> runV163() => SqliteMigrations.migrateToVersion(db, 163);

    List<String> columnsOf(String table) => db
        .select('PRAGMA table_info($table)')
        .map((c) => c['name'].toString())
        .toList();

    bool tableExists(String name) => db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [name],
    ).isNotEmpty;

    test('creates the ledger with the composite primary key', () async {
      db.execute(v161UserConfig);
      await runV163();

      expect(tableExists('app_romm_screenshot_map'), isTrue);
      expect(columnsOf('app_romm_screenshot_map'), [
        'rom_path',
        'file_name',
        'file_size',
        'romm_screenshot_id',
        'uploaded_at',
      ]);

      final key = db
          .select('PRAGMA table_info(app_romm_screenshot_map)')
          .where((c) => (c['pk'] as int) > 0)
          .map((c) => c['name'].toString());
      expect(key, ['rom_path', 'file_name']);
    });

    test('adds the screenshot columns to a v35 RetroArch table', () async {
      db.execute(v35RetroArchTable);
      db.execute(v161UserConfig);
      expect(
        columnsOf('user_retroarch_config'),
        isNot(contains('screenshot_directory')),
      );

      await runV163();

      expect(
        columnsOf('user_retroarch_config'),
        containsAll(SqliteMigrations.retroArchScreenshotColumns.keys),
      );
    });

    test('adds romm_upload_screenshots defaulting to on', () async {
      db.execute(v161UserConfig);
      expect(
        columnsOf('user_config'),
        isNot(contains('romm_upload_screenshots')),
      );

      await runV163();

      expect(columnsOf('user_config'), contains('romm_upload_screenshots'));
      db.execute('INSERT INTO user_config (id) VALUES (1)');
      final row = db.select(
        'SELECT romm_upload_screenshots FROM user_config WHERE id = 1',
      );
      expect(row.first['romm_upload_screenshots'], 1);
    });

    test('running twice leaves the table and columns exactly once', () async {
      db.execute(v35RetroArchTable);
      db.execute(v161UserConfig);

      await runV163();
      await runV163();

      final ledgerTables = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='app_romm_screenshot_map'",
      );
      expect(ledgerTables, hasLength(1));
      expect(
        columnsOf('user_config').where((c) => c == 'romm_upload_screenshots'),
        hasLength(1),
      );
      expect(
        columnsOf(
          'user_retroarch_config',
        ).where((c) => c == 'screenshot_directory'),
        hasLength(1),
      );
    });

    test('a fresh database gets everything from the CREATE statements', () {
      db.execute(SqliteMigrations.createAppRommScreenshotMapTableSql);
      db.execute(SqliteMigrations.createUserRetroArchConfigTableSql);

      expect(tableExists('app_romm_screenshot_map'), isTrue);
      expect(
        columnsOf('user_retroarch_config'),
        containsAll(SqliteMigrations.retroArchScreenshotColumns.keys),
      );
    });

    test('a database without user_config is left alone, not failed', () async {
      await runV163();
      expect(tableExists('app_romm_screenshot_map'), isTrue);
      expect(tableExists('user_config'), isFalse);
    });
  });

  group('RommScreenshotMapRepository', () {
    final helper = DatabaseTestHelper();
    late DatabaseAdapter adapter;

    const romPath = '/roms/snes/Game.sfc';

    setUp(() async {
      adapter = await helper.setUp();
      await adapter.execute(
        SqliteMigrations.createAppRommScreenshotMapTableSql,
      );
    });

    tearDown(() async {
      await helper.tearDown();
    });

    test('records an upload and reads it back by size', () async {
      await RommScreenshotMapRepository.recordUploaded(
        romPath: romPath,
        fileName: 'Game-a.png',
        fileSize: 1234,
        rommScreenshotId: 9,
      );

      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-a.png': 1234,
      });

      final entries = await RommScreenshotMapRepository.entriesFor(romPath);
      expect(entries.single.rommScreenshotId, 9);
      expect(entries.single.fileSize, 1234);
    });

    test('records a 413 skip with a null size', () async {
      await RommScreenshotMapRepository.recordSkipped(
        romPath: romPath,
        fileName: 'Game-huge.png',
      );

      expect(await RommScreenshotMapRepository.recordedFor(romPath), {
        'Game-huge.png': null,
      });
    });

    test('a second write for the same file updates one row', () async {
      await RommScreenshotMapRepository.recordSkipped(
        romPath: romPath,
        fileName: 'Game-a.png',
      );
      await RommScreenshotMapRepository.recordUploaded(
        romPath: romPath,
        fileName: 'Game-a.png',
        fileSize: 42,
        rommScreenshotId: 3,
      );

      final entries = await RommScreenshotMapRepository.entriesFor(romPath);
      expect(entries, hasLength(1));
      expect(entries.single.fileSize, 42);
      expect(entries.single.rommScreenshotId, 3);
    });

    test('rows are scoped to their rom path', () async {
      await RommScreenshotMapRepository.recordUploaded(
        romPath: romPath,
        fileName: 'Game-a.png',
        fileSize: 1,
      );
      await RommScreenshotMapRepository.recordUploaded(
        romPath: '/roms/nes/Other.nes',
        fileName: 'Other-a.png',
        fileSize: 2,
      );

      expect(
        await RommScreenshotMapRepository.recordedFor(romPath),
        hasLength(1),
      );
      expect(await RommScreenshotMapRepository.removeFor(romPath), 1);
      expect(await RommScreenshotMapRepository.recordedFor(romPath), isEmpty);
      expect(
        await RommScreenshotMapRepository.recordedFor('/roms/nes/Other.nes'),
        hasLength(1),
      );
    });

    test('an empty rom path is refused rather than written', () async {
      expect(
        await RommScreenshotMapRepository.recordUploaded(
          romPath: '',
          fileName: 'Game-a.png',
          fileSize: 1,
        ),
        isFalse,
      );
      expect(await RommScreenshotMapRepository.recordedFor(''), isEmpty);
    });
  });

  group('ConfigRepository.getRommUploadScreenshots', () {
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
      expect(await ConfigRepository.getRommUploadScreenshots(), isTrue);
    });

    test('reads the stored 0/1', () async {
      await adapter.execute(
        'ALTER TABLE user_config ADD COLUMN '
        'romm_upload_screenshots INTEGER DEFAULT 1',
      );
      expect(await ConfigRepository.getRommUploadScreenshots(), isTrue);

      await adapter.execute(
        'UPDATE user_config SET romm_upload_screenshots = 0',
      );
      expect(await ConfigRepository.getRommUploadScreenshots(), isFalse);
    });
  });
}
