import '../data/datasources/sqlite_service.dart';
import '../models/database_game_model.dart';

/// Repository for user-defined collections (`user_collections` /
/// `user_collection_items`).
///
/// Thin static delegation to [SqliteService], mirroring `SystemRepository` and
/// `GameRepository`: this is the only layer permitted to reach the datasource,
/// so `CollectionsService` and everything above it goes through here.
class CollectionRepository {
  const CollectionRepository._();

  /// Returns every collection row with its membership count.
  static Future<List<Map<String, Object?>>> getCollections() =>
      SqliteService.getCollections();

  /// Returns one collection row (with its game count), or null.
  static Future<Map<String, Object?>?> getCollectionById(String id) =>
      SqliteService.getCollectionById(id);

  /// Inserts a collection with a caller-supplied [id].
  static Future<void> insertCollection({
    required String id,
    required String name,
    String? imagePath,
    String? color1,
    String? color2,
    int? sortOrder,
  }) => SqliteService.insertCollection(
    id: id,
    name: name,
    imagePath: imagePath,
    color1: color1,
    color2: color2,
    sortOrder: sortOrder,
  );

  /// Updates a collection's mutable fields.
  static Future<void> updateCollection(
    String id, {
    String? name,
    String? imagePath,
    bool clearImagePath = false,
    String? color1,
    bool clearColor1 = false,
    String? color2,
    bool clearColor2 = false,
    int? sortOrder,
  }) => SqliteService.updateCollection(
    id,
    name: name,
    imagePath: imagePath,
    clearImagePath: clearImagePath,
    color1: color1,
    clearColor1: clearColor1,
    color2: color2,
    clearColor2: clearColor2,
    sortOrder: sortOrder,
  );

  /// Deletes a collection and its membership rows.
  static Future<void> deleteCollection(String id) =>
      SqliteService.deleteCollection(id);

  /// Adds a ROM to a collection. Re-adding is a no-op.
  static Future<void> addRomToCollection(String collectionId, String romPath) =>
      SqliteService.addRomToCollection(collectionId, romPath);

  /// Removes a ROM from a collection. Removing a non-member is a no-op.
  static Future<void> removeRomFromCollection(
    String collectionId,
    String romPath,
  ) => SqliteService.removeRomFromCollection(collectionId, romPath);

  /// Returns the ids of every collection containing [romPath].
  static Future<List<String>> getCollectionIdsForRom(String romPath) =>
      SqliteService.getCollectionIdsForRom(romPath);

  /// Returns every `rom_path` that belongs to at least one collection.
  static Future<Set<String>> getCollectionMemberRomPaths() =>
      SqliteService.getCollectionMemberRomPaths();

  /// Returns the games in a collection, in the same shape as the favourites
  /// query (systems joined, so `systemFolderName` is populated).
  static Future<List<DatabaseGameModel>> getGamesInCollection(
    String collectionId,
  ) => SqliteService.getGamesInCollection(collectionId);

  // ── RomM mirror provenance ─────────────────────────────────────────────────
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Collection Provenance Columns"

  /// The local collection row mirroring RomM collection [collectionId] on
  /// [serverUrl], or null when none does.
  static Future<Map<String, Object?>?> findRommMirror(
    String serverUrl,
    String collectionId,
  ) => SqliteService.findRommMirror(serverUrl, collectionId);

  /// Records (or refreshes) which RomM collection [id] mirrors. Only the
  /// provenance columns are written.
  static Future<void> setRommProvenance(
    String id, {
    required String serverUrl,
    required String collectionId,
    required bool virtual,
    required DateTime syncedAt,
  }) => SqliteService.setRommProvenance(
    id,
    serverUrl: serverUrl,
    collectionId: collectionId,
    virtual: virtual,
    syncedAt: syncedAt,
  );

  /// Forgets which RomM collection [id] mirrors; the collection and its
  /// members are untouched.
  static Future<void> clearRommProvenance(String id) =>
      SqliteService.clearRommProvenance(id);

  /// Creates a collection mirroring a RomM collection — row and provenance
  /// in one transaction.
  static Future<void> insertRommMirrorCollection({
    required String id,
    required String name,
    required String serverUrl,
    required String collectionId,
    required bool virtual,
    required DateTime syncedAt,
  }) => SqliteService.insertRommMirrorCollection(
    id: id,
    name: name,
    serverUrl: serverUrl,
    collectionId: collectionId,
    virtual: virtual,
    syncedAt: syncedAt,
  );

  /// Every `rom_path` in collection [collectionId].
  static Future<Set<String>> getMemberRomPaths(String collectionId) =>
      SqliteService.getMemberRomPaths(collectionId);

  /// Sets the membership of [collectionId] to exactly [romPaths] in one
  /// transaction; returns how many rows were added and removed.
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Database Operation Standards"
  static Future<({int added, int removed})> replaceMembers(
    String collectionId,
    Set<String> romPaths,
  ) => SqliteService.replaceMembers(collectionId, romPaths);
}
