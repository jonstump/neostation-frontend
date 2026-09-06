/// A user-defined collection of games.
///
/// Backed by the `user_collections` table. Collections are deliberately *not*
/// `app_systems` rows: `syncSystems` prunes every system row missing from the
/// systems JSON, which would take the user's collections with it on the next
/// systems update.
///
/// [gameCount] and [imageVersion] are not columns. The count is computed by the
/// listing query's `GROUP BY`, and [imageVersion] is an in-memory counter the
/// provider bumps when the artwork file at [imagePath] is replaced — replacing
/// a file at the same path does not change any `ValueKey`, so Flutter's image
/// cache would otherwise keep painting the old picture (the same reason
/// `SystemInfo.imageVersion` exists).
class CollectionModel {
  /// Bare uuid v4. Carried by the `collection:<id>` synthesized system folder
  /// name and used to name the artwork file, so a rename never orphans it.
  final String id;

  /// User-supplied display name. Not unique — duplicates are allowed.
  final String name;

  /// Absolute path to the collection's artwork under
  /// `<userData>/media/collections/`, or null when it has none.
  final String? imagePath;

  /// Optional gradient start colour for the fallback card, as stored.
  final String? color1;

  /// Optional gradient end colour for the fallback card, as stored.
  final String? color2;

  /// Manual ordering position within the collections list.
  final int sortOrder;

  /// Number of ROMs in the collection. Computed by the query, never stored.
  final int gameCount;

  /// Bumped when the file at [imagePath] is replaced, to bust the image cache.
  final int imageVersion;

  /// When the collection was created, as stored in `created_at`.
  ///
  /// Read-only: the browser's "date added" ordering sorts on this rather than
  /// on [sortOrder], so the two stay independent if manual reordering ever
  /// lands. Null when the column is absent or unparseable.
  final DateTime? createdAt;

  // RomM mirror provenance (v161). All null on an ordinary collection; set
  // together by the mirror and cleared together by "Unlink from RomM".
  // Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Collection Provenance Columns"

  /// Normalised base URL of the RomM server this collection mirrors, or null.
  final String? rommServerUrl;

  /// Id of the RomM collection this one mirrors, or null. An integer-as-string
  /// for a user collection, an opaque string for a virtual one.
  final String? rommCollectionId;

  /// Whether [rommCollectionId] names a RomM virtual collection.
  final bool rommCollectionVirtual;

  /// When the mirror last set this collection's membership, or null.
  final DateTime? rommSyncedAt;

  const CollectionModel({
    required this.id,
    required this.name,
    this.imagePath,
    this.color1,
    this.color2,
    this.sortOrder = 0,
    this.gameCount = 0,
    this.imageVersion = 0,
    this.createdAt,
    this.rommServerUrl,
    this.rommCollectionId,
    this.rommCollectionVirtual = false,
    this.rommSyncedAt,
  });

  /// True when this collection mirrors a RomM collection: its membership is
  /// managed by the sync, and the browser marks it and offers to unlink it.
  bool get isRommMirror => rommCollectionId != null;

  /// Builds a model from a `user_collections` row, including the joined
  /// `game_count` produced by the listing query when present.
  factory CollectionModel.fromJson(Map<String, dynamic> json) {
    return CollectionModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      imagePath: _nullIfEmpty(json['image_path']),
      color1: _nullIfEmpty(json['color1']),
      color2: _nullIfEmpty(json['color2']),
      sortOrder: _toInt(json['sort_order']),
      gameCount: _toInt(json['game_count']),
      imageVersion: _toInt(json['image_version']),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      rommServerUrl: _nullIfEmpty(json['romm_server_url']),
      rommCollectionId: _nullIfEmpty(json['romm_collection_id']),
      rommCollectionVirtual: _toInt(json['romm_collection_virtual']) == 1,
      rommSyncedAt: DateTime.tryParse(json['romm_synced_at']?.toString() ?? ''),
    );
  }

  /// Serializes only the persisted columns — [gameCount] and [imageVersion]
  /// are derived and must never be written back to `user_collections`. The
  /// RomM provenance columns are left out too: they are written only through
  /// `CollectionRepository.setRommProvenance` / `clearRommProvenance`, never
  /// as part of a whole-row write.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'image_path': imagePath,
    'color1': color1,
    'color2': color2,
    'sort_order': sortOrder,
  };

  /// Returns a copy with the given fields replaced.
  ///
  /// [imagePath], [color1] and [color2] are nullable columns, so each has a
  /// matching `clear*` flag: passing null alone cannot distinguish "leave it"
  /// from "unset it".
  CollectionModel copyWith({
    String? id,
    String? name,
    String? imagePath,
    bool clearImagePath = false,
    String? color1,
    bool clearColor1 = false,
    String? color2,
    bool clearColor2 = false,
    int? sortOrder,
    int? gameCount,
    int? imageVersion,
    DateTime? createdAt,
    String? rommServerUrl,
    String? rommCollectionId,
    bool? rommCollectionVirtual,
    DateTime? rommSyncedAt,
    bool clearRommProvenance = false,
  }) {
    return CollectionModel(
      id: id ?? this.id,
      name: name ?? this.name,
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
      color1: clearColor1 ? null : (color1 ?? this.color1),
      color2: clearColor2 ? null : (color2 ?? this.color2),
      sortOrder: sortOrder ?? this.sortOrder,
      gameCount: gameCount ?? this.gameCount,
      imageVersion: imageVersion ?? this.imageVersion,
      createdAt: createdAt ?? this.createdAt,
      rommServerUrl: clearRommProvenance
          ? null
          : (rommServerUrl ?? this.rommServerUrl),
      rommCollectionId: clearRommProvenance
          ? null
          : (rommCollectionId ?? this.rommCollectionId),
      rommCollectionVirtual: clearRommProvenance
          ? false
          : (rommCollectionVirtual ?? this.rommCollectionVirtual),
      rommSyncedAt: clearRommProvenance
          ? null
          : (rommSyncedAt ?? this.rommSyncedAt),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CollectionModel &&
          other.id == id &&
          other.name == name &&
          other.imagePath == imagePath &&
          other.color1 == color1 &&
          other.color2 == color2 &&
          other.sortOrder == sortOrder &&
          other.gameCount == gameCount &&
          other.imageVersion == imageVersion &&
          other.rommServerUrl == rommServerUrl &&
          other.rommCollectionId == rommCollectionId &&
          other.rommCollectionVirtual == rommCollectionVirtual &&
          other.rommSyncedAt == rommSyncedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    imagePath,
    color1,
    color2,
    sortOrder,
    gameCount,
    imageVersion,
    rommServerUrl,
    rommCollectionId,
    rommCollectionVirtual,
    rommSyncedAt,
  );

  @override
  String toString() =>
      'CollectionModel(id: $id, name: $name, gameCount: $gameCount)';

  static String? _nullIfEmpty(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  static int _toInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
