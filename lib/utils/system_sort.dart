import '../constants/system_folder_names.dart';
import '../models/system_model.dart';

/// The order the systems carousel shows systems in, as one comparator.
///
/// Extracted from `SqliteConfigProvider._sortDetectedSystems` so the systems
/// list builder can slot the RomM-only systems in among the detected ones
/// under exactly the same rule — a second copy of the rule would be a second
/// place for the order to drift.
///
/// The virtual entries (`all`, favourites, collections, music, android) float
/// to the top in a fixed order regardless of [sortBy] and [ascending]; real
/// systems sort by [sortBy] — `year`, `manufacturer`, `manufacturer_type`, or
/// anything else for the alphabetical default — reversed when [ascending] is
/// false. Ties resolve to 0, so a stable sort keeps the input order for them.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote-Only Systems"
int compareSystemsForCarousel(
  SystemModel a,
  SystemModel b, {
  required String sortBy,
  required bool ascending,
}) {
  const priority = <String, int>{
    'all': 1,
    'favorites': 2,
    SystemFolderNames.collections: 3,
    'music': 4,
    'android': 5,
  };
  final pA = priority[a.folderName] ?? 999;
  final pB = priority[b.folderName] ?? 999;
  if (pA != pB) return pA.compareTo(pB);
  // Both special, same priority: nothing to sort by.
  if (pA != 999) return 0;

  int comparison;
  if (sortBy == 'year') {
    // Systems without a launch date sort after every dated one.
    comparison = (a.launchDate ?? '9999').compareTo(b.launchDate ?? '9999');
  } else if (sortBy == 'manufacturer') {
    comparison = (a.manufacturer ?? '').toLowerCase().compareTo(
      (b.manufacturer ?? '').toLowerCase(),
    );
    if (comparison == 0) {
      comparison = (a.launchDate ?? '9999').compareTo(b.launchDate ?? '9999');
    }
  } else if (sortBy == 'manufacturer_type') {
    comparison = (a.manufacturer ?? '').toLowerCase().compareTo(
      (b.manufacturer ?? '').toLowerCase(),
    );
    if (comparison == 0) {
      comparison = (a.type ?? '').toLowerCase().compareTo(
        (b.type ?? '').toLowerCase(),
      );
    }
    if (comparison == 0) {
      comparison = (a.launchDate ?? '9999').compareTo(b.launchDate ?? '9999');
    }
  } else {
    comparison = a.realName.toLowerCase().compareTo(b.realName.toLowerCase());
  }
  return ascending ? comparison : -comparison;
}
