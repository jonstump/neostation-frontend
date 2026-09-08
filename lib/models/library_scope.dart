import 'game_model.dart';

/// What a game view shows of the unified library: everything the RomM server
/// has for the system, or only what is on the device.
///
/// A view holds one of these and applies it as a predicate over the merged
/// list `GameListService` built — the scope never reaches the database, so a
/// toggle is a rebuild, not a reload.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope"
enum LibraryScope {
  /// Local games plus the catalog's remote entries, and the remote-only
  /// systems in the carousel.
  all,

  /// Local games only; remote entries and remote-only systems are hidden.
  downloaded;

  /// The value `user_config.romm_library_default_scope` stores.
  String get configValue => name;

  /// The other scope — what a toggle switches to.
  LibraryScope get toggled =>
      this == LibraryScope.all ? LibraryScope.downloaded : LibraryScope.all;

  /// Parses a stored config value. Anything that is not `downloaded` reads as
  /// [all], which is the column's default.
  static LibraryScope fromConfig(String? value) =>
      value == LibraryScope.downloaded.name
      ? LibraryScope.downloaded
      : LibraryScope.all;

  /// The scope a view opens in: the configured default, except that an
  /// unreachable server forces [downloaded] — a list that opens on entries
  /// nothing can download is worse than one that opens on what is here.
  /// Switching to [all] afterwards is still allowed; it shows the cached
  /// catalog with an offline line.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Library Scope"
  static LibraryScope initial({
    required String? configured,
    required bool offline,
  }) => offline ? LibraryScope.downloaded : fromConfig(configured);

  /// [games] under this scope: the same list for [all], the local entries
  /// only for [downloaded]. Pure and synchronous — the predicate a view
  /// applies to the merged list it already holds, which is what keeps a
  /// scope toggle from touching the database.
  // Governing: ADR-0020 (unified library), SPEC-0019 REQ "Concurrency Safety"
  List<GameModel> filter(List<GameModel> games) => this == LibraryScope.all
      ? games
      : games.where((g) => !g.isRemote).toList(growable: false);
}
