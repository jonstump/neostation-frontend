import '../models/game_model.dart';

/// What a per-game scrape may do for one entry, decided before any RomM or
/// ScreenScraper call is made.
///
/// Every place a single scrape starts — the details card's button, the
/// context menu, and the Select + A chord in the grid, carousel, and list —
/// asks this first, so a remote entry is answered the same way from all of
/// them. A remote entry has no file on this device: scraping it would
/// fingerprint an empty path, fall back to a name search, and write
/// `user_screenscraper_metadata` rows and media for a ROM that is not here,
/// spending ScreenScraper quota on the way.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entries In The Game Model"
enum ScrapeGate {
  /// The game is on this device: the scrape may run.
  allowed,

  /// A remote entry: answer with the "Not downloaded" notice instead.
  notDownloaded,
}

/// The gate for [game]. Pure: a local game (linked to RomM or not) is
/// [ScrapeGate.allowed]; a remote entry is [ScrapeGate.notDownloaded].
ScrapeGate scrapeGateFor(GameModel game) =>
    game.isRemote ? ScrapeGate.notDownloaded : ScrapeGate.allowed;
