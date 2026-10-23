import '../l10n/app_locale.dart';
import '../repositories/scraper_repository.dart' show MetadataSource;

/// The `AppLocale` key that names where a metadata row came from, for the
/// per-game "Metadata source" line, or null when the row records no source
/// (rows written before the column existed, or by a path that never set it),
/// in which case the line is not shown rather than guessing.
///
/// [dbValue] is the row's `metadata_source` column as read from the database.
String? metadataSourceKey(Object? dbValue) {
  switch (MetadataSource.fromDb(dbValue)) {
    case MetadataSource.romm:
      return AppLocale.metadataSourceRomm;
    case MetadataSource.screenscraper:
      return AppLocale.metadataSourceScreenscraper;
    case MetadataSource.esde:
      return AppLocale.metadataSourceEsde;
    case MetadataSource.steam:
      return AppLocale.metadataSourceSteam;
    case MetadataSource.manual:
      return AppLocale.metadataSourceManual;
    case null:
      return null;
  }
}
