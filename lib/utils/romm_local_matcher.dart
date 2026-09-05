import 'package:path/path.dart' as p;

import '../models/romm_rom.dart';

/// The one rule that decides whether a local library entry *is* a RomM ROM.
///
/// Every consumer of "does this RomM ROM correspond to a file we already
/// have" — the browse grid's "downloaded" badge, bulk sync's skip decision, and
/// the link paths that write `app_romm_rom_map` for pre-existing ROMs — goes
/// through here, so the badge and the link can never disagree about a game.
///
/// Pure by design: it compares names and never touches the filesystem, the
/// database, or the network. Callers that need to know whether a candidate
/// name actually exists on disk (or in the scan index) do that probing
/// themselves and feed the names in.
///
/// Platform-to-system resolution is deliberately *not* part of this class: the
/// callers already scope their lookups to the local system a RomM platform
/// resolves to (`RommProvider.resolveSystem`), so the rule only has to answer
/// the filename half of the equivalence.
// Governing: ADR-0001 (filename linking), SPEC-0001 REQ "Filename Equivalence Rule"
class RommLocalMatcher {
  const RommLocalMatcher._();

  /// On-disk names under which [rom] may exist locally, in match priority.
  ///
  /// A single-file ROM lands as its [RommRom.fsName]. A multi-disc ROM is
  /// served as a zip that `extractMultiDiscZip` unpacks into disc files plus a
  /// `.m3u` playlist and then deletes — so the fsName itself never exists on
  /// disk; only the playlist does. We match the playlist names that extraction
  /// would produce: the synthesised fallback (`<fsName>.m3u`) and, defensively,
  /// the extension-replaced variant (`<stem>.m3u`). A bundled playlist keeps
  /// its own basename, which can't be predicted here; the save map records
  /// that name at download time and `RommProvider` adds it on top of these.
  ///
  /// Returns a fresh, growable list so callers may append to it.
  static List<String> candidateNames(RommRom rom) {
    final names = <String>[rom.fsName];
    if (rom.isMultiFile) {
      names.add('${rom.fsName}.m3u');
      final stem = p.basenameWithoutExtension(rom.fsName);
      if (stem.isNotEmpty && stem != rom.fsName) names.add('$stem.m3u');
    }
    return names;
  }

  /// Whether a local file named [localFilename] is [rom].
  ///
  /// The comparison is case-insensitive: a library copied from the server over
  /// USB may pass through a case-folding filesystem, and the sync layer looks
  /// games up by the library's own canonical spelling, so case must never be
  /// the reason a game stays unlinked. The rule compares *names* only — the
  /// caller has already scoped the question to one local system.
  static bool matches(String localFilename, RommRom rom) {
    final wanted = normalizeName(localFilename);
    if (wanted.isEmpty) return false;
    for (final candidate in candidateNames(rom)) {
      if (normalizeName(candidate) == wanted) return true;
    }
    return false;
  }

  /// Canonical form of a filename for equivalence comparison.
  ///
  /// The single definition of "equal" used by [matches], exposed so an index
  /// keyed by filename (the connect-time link pass builds one from the scan
  /// index) folds its keys exactly the way the rule compares them.
  static String normalizeName(String name) => name.trim().toLowerCase();
}
