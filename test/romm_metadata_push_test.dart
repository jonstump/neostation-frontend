import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/romm/romm_metadata_push.dart';

/// The metadata push behind "Upload to RomM" (#237).
///
/// Everything here asserts **the request body the app builds**, never a
/// server response: whether `PUT /api/roms/{id}` actually accepts `summary`
/// is unverified, and these tests have to keep meaning something either way.
/// The rules they pin are the ones a wrong answer makes expensive — a blank
/// field erases a title for every client of the server, and a value RomM gave
/// us handed back overwrites the server's own work with a stale copy.
///
/// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source
/// Provenance"; ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link
/// After Upload"
void main() {
  Map<String, Object?> row({
    Object? realName = 'Sonic The Hedgehog',
    Object? description = 'A blue hedgehog runs fast.',
    String? source,
    Map<String, String>? fieldSources,
  }) => <String, Object?>{
    'filename': 'Sonic.md',
    'real_name': realName,
    'description_en': description,
    'metadata_source': source,
    'field_sources': fieldSources == null ? null : jsonEncode(fieldSources),
  };

  group('buildRommMetadataPush — mapping', () {
    test('maps real_name to name and description_en to summary', () {
      expect(buildRommMetadataPush(row(source: 'screenscraper')), {
        'name': 'Sonic The Hedgehog',
        'summary': 'A blue hedgehog runs fast.',
      });
    });

    test('sends the columns a manual, ES-DE or Steam row holds', () {
      for (final source in ['manual', 'esde', 'steam']) {
        expect(buildRommMetadataPush(row(source: source)).keys, {
          'name',
          'summary',
        }, reason: 'source $source is NeoStation\'s own work');
      }
    });
  });

  group('buildRommMetadataPush — never blank', () {
    test('omits a blank or whitespace column rather than sending it empty', () {
      // A present-but-empty `name` is how RomM is told to erase the title.
      expect(
        buildRommMetadataPush(
          row(realName: '   ', description: '', source: 'screenscraper'),
        ),
        isEmpty,
      );
    });

    test('a blank title does not hold back the summary beside it', () {
      expect(
        buildRommMetadataPush(row(realName: null, source: 'screenscraper')),
        {'summary': 'A blue hedgehog runs fast.'},
      );
    });
  });

  group('buildRommMetadataPush — never RomM its own values', () {
    test('skips only the fields field_sources attributes to romm', () {
      expect(
        buildRommMetadataPush(
          row(
            source: 'romm',
            fieldSources: {
              'real_name': 'romm',
              'description_en': 'screenscraper',
            },
          ),
        ),
        {'summary': 'A blue hedgehog runs fast.'},
      );
    });

    test('per-field provenance outranks the row source', () {
      // The row says romm, the fields say otherwise: the fields win, which is
      // the whole point of #248's merge-on-write.
      expect(
        buildRommMetadataPush(
          row(
            source: 'romm',
            fieldSources: {
              'real_name': 'screenscraper',
              'description_en': 'manual',
            },
          ),
        ),
        {'name': 'Sonic The Hedgehog', 'summary': 'A blue hedgehog runs fast.'},
      );
    });

    test('falls back to metadata_source when field_sources is empty', () {
      // Legacy rows and rows a replace-mode pass rebuilt carry no per-field
      // provenance; the row-level source is all there is to go on.
      expect(buildRommMetadataPush(row(source: 'romm')), isEmpty);
      expect(buildRommMetadataPush(row(source: 'screenscraper')).keys, {
        'name',
        'summary',
      });
    });

    test('sends nothing when no source is recorded at all', () {
      expect(buildRommMetadataPush(row()), isEmpty);
    });
  });

  group('RommMetadataPush.run', () {
    late List<(int, Map<String, String>)> sent;

    setUp(() => sent = []);

    Future<RommMetadataPushSummary> run(
      List<RommMetadataPushTarget> targets, {
      required Map<String, int?> romIds,
      Map<String, Map<String, Object?>?> rows = const {},
      bool sendAnswer = true,
      bool throwOnRomId = false,
    }) => RommMetadataPush.run(
      targets: targets,
      readRomId: (romname, folder) async {
        if (throwOnRomId) throw StateError('link lookup exploded');
        return romIds[romname];
      },
      resolveSystemId: (folder) async => 'sys-$folder',
      readRow: (systemId, filename) async => rows[filename],
      send: (romId, fields) async {
        sent.add((romId, fields));
        return sendAnswer;
      },
    );

    test(
      'sends nothing for a target the link pass has not linked yet',
      () async {
        // The ordering the upload flow lives with: an uploaded ROM has no id
        // until the server has scanned it.
        final summary = await run(
          [(romname: 'Sonic.md', systemFolder: 'megadrive')],
          romIds: {'Sonic.md': null},
          rows: {'Sonic.md': row(source: 'screenscraper')},
        );
        expect(sent, isEmpty);
        expect(summary, (pushed: 0, skipped: 1, failed: 0));
      },
    );

    test('sends the built body to the linked rom id', () async {
      final summary = await run(
        [(romname: 'Sonic.md', systemFolder: 'megadrive')],
        romIds: {'Sonic.md': 42},
        rows: {'Sonic.md': row(source: 'screenscraper')},
      );
      // Asserted piecewise: a record holding a Map compares by identity, so
      // `expect(sent, [(42, {...})])` would pass on any two equal-looking
      // bodies and fail on the right one.
      expect(sent.length, 1);
      expect(sent.single.$1, 42);
      expect(sent.single.$2, {
        'name': 'Sonic The Hedgehog',
        'summary': 'A blue hedgehog runs fast.',
      });
      expect(summary, (pushed: 1, skipped: 0, failed: 0));
    });

    test('sends no request at all for a game that was never scraped', () async {
      final summary = await run(
        [(romname: 'Sonic.md', systemFolder: 'megadrive')],
        romIds: {'Sonic.md': 42},
      );
      expect(
        sent,
        isEmpty,
        reason: 'an empty form asks the server for nothing',
      );
      expect(summary, (pushed: 0, skipped: 1, failed: 0));
    });

    test('stops after a gated send instead of retrying every target', () async {
      final summary = await run(
        [
          (romname: 'Sonic.md', systemFolder: 'megadrive'),
          (romname: 'Streets.md', systemFolder: 'megadrive'),
        ],
        romIds: {'Sonic.md': 42, 'Streets.md': 43},
        rows: {
          'Sonic.md': row(source: 'screenscraper'),
          'Streets.md': row(source: 'screenscraper'),
        },
        sendAnswer: false,
      );
      expect(sent.map((s) => s.$1), [42], reason: 'the scope is the same');
      expect(summary, (pushed: 0, skipped: 2, failed: 0));
    });

    test('counts a failing target and keeps going', () async {
      final summary = await run(
        [(romname: 'Sonic.md', systemFolder: 'megadrive')],
        romIds: {'Sonic.md': 42},
        rows: {'Sonic.md': row(source: 'screenscraper')},
        throwOnRomId: true,
      );
      expect(summary, (pushed: 0, skipped: 0, failed: 1));
    });
  });
}
