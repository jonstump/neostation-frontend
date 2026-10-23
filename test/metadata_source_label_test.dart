import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/repositories/scraper_repository.dart';
import 'package:neostation/utils/metadata_source_label.dart';

/// Which `AppLocale` key names where a game's metadata came from, for the
/// per-game "Metadata source" line.
void main() {
  test('every recorded source has its own key', () {
    expect(
      metadataSourceKey(MetadataSource.romm.dbValue),
      AppLocale.metadataSourceRomm,
    );
    expect(
      metadataSourceKey(MetadataSource.screenscraper.dbValue),
      AppLocale.metadataSourceScreenscraper,
    );
    expect(
      metadataSourceKey(MetadataSource.esde.dbValue),
      AppLocale.metadataSourceEsde,
    );
    expect(
      metadataSourceKey(MetadataSource.steam.dbValue),
      AppLocale.metadataSourceSteam,
    );
    expect(
      metadataSourceKey(MetadataSource.manual.dbValue),
      AppLocale.metadataSourceManual,
    );
  });

  test('the keys are distinct, so no two sources read the same', () {
    final keys = {
      for (final source in MetadataSource.values)
        metadataSourceKey(source.dbValue),
    };
    expect(keys, hasLength(MetadataSource.values.length));
  });

  test('a row with no recorded source shows nothing instead of a guess', () {
    expect(metadataSourceKey(null), isNull);
    expect(metadataSourceKey(''), isNull);
  });

  test('a value this build does not know shows nothing', () {
    expect(metadataSourceKey('some-future-source'), isNull);
    expect(metadataSourceKey(42), isNull);
  });
}
