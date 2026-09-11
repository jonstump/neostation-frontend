import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/metadata_field_sources.dart';
import 'package:neostation/repositories/scraper_repository.dart';

/// Per-field metadata provenance: the map itself, and the fill-gaps write that
/// maintains it.
///
/// `metadata_source` records who wrote the row, which cannot describe a row a
/// RomM fetch created and a ScreenScraper pass later filled the gaps of. That
/// second question is what a RomM upload needs so it pushes what NeoStation
/// learned rather than handing RomM its own values back. Issue #233.
void main() {
  group('decoding', () {
    test('a stored map round-trips', () {
      final encoded = MetadataFieldSources.empty().withWrites([
        'genre',
        'players',
      ], 'romm').toDb();

      final back = MetadataFieldSources.fromDb(encoded);

      expect(back.sourceOf('genre'), 'romm');
      expect(back.sourceOf('players'), 'romm');
    });

    test('null, blank and malformed all read as empty, never throw', () {
      // Provenance must never fail a metadata write, so every bad input has to
      // degrade rather than raise.
      for (final bad in [null, '', '   ', 'not json', '[1,2,3]', '{']) {
        expect(
          MetadataFieldSources.fromDb(bad).isEmpty,
          isTrue,
          reason: '$bad',
        );
      }
    });

    test('a partially valid object keeps the usable entries', () {
      final v = MetadataFieldSources.fromDb('{"genre":"romm","rating":7}');

      expect(v.sourceOf('genre'), 'romm');
      expect(
        v.sourceOf('rating'),
        isNull,
        reason: 'a non-string value is dropped, not coerced',
      );
    });

    test('empty serialises to null, not an empty object', () {
      // Null is what a row written before v168 holds, so "nothing known" must
      // be indistinguishable from it.
      expect(MetadataFieldSources.empty().toDb(), isNull);
    });
  });

  group('merging', () {
    test('last writer wins per field, others keep their source', () {
      final v = MetadataFieldSources.empty()
          .withWrites(['genre', 'players', 'developer'], 'romm')
          .withWrites(['genre'], 'screenscraper');

      expect(v.sourceOf('genre'), 'screenscraper');
      expect(v.sourceOf('players'), 'romm');
      expect(v.sourceOf('developer'), 'romm');
    });

    test('fieldsFrom answers the question the RomM upload asks', () {
      final v = MetadataFieldSources.empty()
          .withWrites(['genre', 'players'], 'romm')
          .withWrites(['description_en'], 'screenscraper');

      expect(v.fieldsFrom('screenscraper'), {'description_en'});
      expect(v.fieldsFrom('romm'), {'genre', 'players'});
    });

    test('an empty write changes nothing', () {
      final before = MetadataFieldSources.empty().withWrites(['genre'], 'romm');

      expect(before.withWrites(const [], 'screenscraper').asMap, before.asMap);
    });
  });

  group('the fill-gaps write records what it filled', () {
    test('an insert attributes exactly the columns it wrote', () {
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'zelda.sfc',
        row: null,
        incoming: {'genre': 'Action', 'players': '1'},
        source: MetadataSource.romm,
      );

      final sources = MetadataFieldSources.fromDb(
        write![MetadataFieldSources.column],
      );
      expect(sources.sourceOf('genre'), 'romm');
      expect(sources.sourceOf('players'), 'romm');
      expect(
        sources.sourceOf('developer'),
        isNull,
        reason: 'a column the write did not fill has no source',
      );
    });

    test('filling a RomM row\'s gaps leaves RomM\'s own fields attributed', () {
      // The case the whole column exists for: two writers, one row.
      final existing = {
        'genre': 'Action',
        'developer': null,
        MetadataFieldSources.column: MetadataFieldSources.empty().withWrites([
          'genre',
        ], 'romm').toDb(),
      };

      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'zelda.sfc',
        row: existing,
        incoming: {'genre': 'Adventure', 'developer': 'Nintendo'},
        source: MetadataSource.screenscraper,
      );

      expect(
        write!.containsKey('genre'),
        isFalse,
        reason: 'fill-gaps never overwrites a value that is already there',
      );

      final sources = MetadataFieldSources.fromDb(
        write[MetadataFieldSources.column],
      );
      expect(sources.sourceOf('developer'), 'screenscraper');
      expect(
        sources.sourceOf('genre'),
        'romm',
        reason: 'the value was not rewritten, so neither was its provenance',
      );
    });

    test('provenance is not written as content', () {
      // `field_sources` arriving in `incoming` must not be treated as a value.
      final write = ScraperRepository.buildFillGapsMetadataWrite(
        appSystemId: 'snes',
        filename: 'zelda.sfc',
        row: null,
        incoming: {
          'genre': 'Action',
          MetadataFieldSources.column: '{"genre":"tampered"}',
        },
        source: MetadataSource.romm,
      );

      final sources = MetadataFieldSources.fromDb(
        write![MetadataFieldSources.column],
      );
      expect(sources.sourceOf('genre'), 'romm');
    });

    test('a write with nothing to fill stays null', () {
      expect(
        ScraperRepository.buildFillGapsMetadataWrite(
          appSystemId: 'snes',
          filename: 'zelda.sfc',
          row: {'genre': 'Action'},
          incoming: {'genre': 'Adventure'},
          source: MetadataSource.screenscraper,
        ),
        isNull,
        reason: 'no provenance-only write for a row that needed nothing',
      );
    });
  });
}
