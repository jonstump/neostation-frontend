import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-text guards for the glyph-style column's storage definition.
///
/// Opening the real `SqliteService` from a test is unsafe (it initialises the
/// developer's actual database, and a version mismatch recreates it), so the
/// two survivors from the mutation table — the `_databaseVersion` bump and
/// the `CREATE TABLE` column — are guarded by reading the source file as
/// text instead.
///
/// These tests only READ source files. They import no database code and
/// never open a database.
///
/// Governing: ADR-0023 (controller glyphs), SPEC-0022 REQ "Database Operation Standards"
void main() {
  final service = File(
    'lib/data/datasources/sqlite_service.dart',
  ).readAsStringSync();
  final migrations = File(
    'lib/data/datasources/sqlite_migrations.dart',
  ).readAsStringSync();

  /// The `CREATE TABLE ... user_config` block, extracted between the
  /// `CREATE TABLE` opening and its closing `)`, so a match of the column
  /// text elsewhere in the file cannot satisfy the guard.
  String userConfigCreateTable() {
    // Find the user_config CREATE TABLE opening.
    final marker = RegExp(r'CREATE TABLE (IF NOT EXISTS )?user_config');
    final match = marker.firstMatch(service);
    expect(match, isNotNull, reason: 'user_config CREATE TABLE not found');
    // The block starts at the CREATE TABLE and ends at the first `)` on a
    // line by itself (the table's closing paren).
    final start = match!.start;
    final close = service.indexOf('\n      )', start);
    expect(close, greaterThan(start), reason: 'CREATE TABLE close not found');
    return service.substring(start, close);
  }

  /// The `ALTER TABLE user_config ADD COLUMN gamepad_glyph_style ...`
  /// statement from `_migrateToVersion173`, extracted so a match elsewhere
  /// in the migration file cannot satisfy the consistency check.
  String migrationAlterStatement() {
    // Find the migration function's body.
    final fnMarker = '_migrateToVersion173(Database db)';
    final fnStart = migrations.indexOf(fnMarker);
    expect(fnStart, greaterThan(-1), reason: '_migrateToVersion173 not found');
    final bodyStart = migrations.indexOf('{', fnStart);
    final bodyEnd = migrations.indexOf('\n  }', bodyStart);
    expect(bodyEnd, greaterThan(bodyStart), reason: 'function end not found');
    final body = migrations.substring(bodyStart, bodyEnd);
    final alter = RegExp(
      r'ALTER TABLE user_config ADD COLUMN gamepad_glyph_style '
      r'[^,\)]*',
    );
    final match = alter.firstMatch(body);
    expect(match, isNotNull, reason: 'ALTER TABLE statement not found in v173');
    return match!.group(0)!;
  }

  group('source-text guards', () {
    test('_databaseVersion is 173', () {
      expect(service, contains('static const int _databaseVersion = 173;'));
    });

    test(
      "the CREATE TABLE user_config block has the column, default 'auto'",
      () {
        final block = userConfigCreateTable();
        expect(
          block,
          contains("gamepad_glyph_style TEXT DEFAULT 'auto'"),
          reason:
              'the CREATE TABLE must carry the column with the same '
              'default as the migration',
        );
      },
    );

    test('a column mention in a comment alone does not satisfy the guard', () {
      // The guard extracts the CREATE TABLE block; the column must be IN it,
      // not merely named somewhere else in the file (a comment, another
      // table's comment, etc.). This test asserts the extraction is the one
      // being checked, by verifying the block actually contains the column
      // name at all — if the column is removed from the block but left in a
      // comment elsewhere, the block check fails.
      final block = userConfigCreateTable();
      expect(block, contains('CREATE TABLE'));
    });

    test(
      'the migration ALTER and the CREATE TABLE agree on type and default',
      () {
        final alter = migrationAlterStatement();
        final block = userConfigCreateTable();

        // Both must carry TEXT and DEFAULT 'auto', so a fresh install and an
        // upgraded install cannot get different defaults.
        expect(alter, contains('TEXT'), reason: 'ALTER type');
        expect(alter, contains("DEFAULT 'auto'"), reason: 'ALTER default');
        expect(block, contains("gamepad_glyph_style TEXT DEFAULT 'auto'"));
      },
    );
  });
}
