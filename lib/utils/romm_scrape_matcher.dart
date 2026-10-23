import 'package:path/path.dart' as p;

import '../models/romm_rom.dart';
import 'romm_local_matcher.dart';

/// How a local game lined up against a RomM catalog.
enum RommScrapeMatchKind {
  /// Exactly one RomM ROM corresponds to the game.
  matched,

  /// Nothing on the system corresponds to the game.
  none,

  /// Two or more RomM ROMs correspond equally well. Never guessed between: a
  /// wrong pick puts another game's description and artwork on this ROM.
  ambiguous,
}

/// Which rule produced a match, for logs and tests.
enum RommScrapeMatchTier { fileName, title }

/// The outcome of one lookup in a [RommScrapeIndex].
class RommScrapeMatch {
  final RommScrapeMatchKind kind;

  /// The matched RomM rom id; set only when [kind] is
  /// [RommScrapeMatchKind.matched].
  final int? romId;
  final RommScrapeMatchTier? tier;

  const RommScrapeMatch._(this.kind, this.romId, this.tier);

  const RommScrapeMatch.matched(int romId, RommScrapeMatchTier tier)
    : this._(RommScrapeMatchKind.matched, romId, tier);

  const RommScrapeMatch.none() : this._(RommScrapeMatchKind.none, null, null);

  const RommScrapeMatch.ambiguous(RommScrapeMatchTier tier)
    : this._(RommScrapeMatchKind.ambiguous, null, tier);

  bool get isMatch => kind == RommScrapeMatchKind.matched;

  @override
  String toString() => 'RommScrapeMatch($kind, romId=$romId, tier=$tier)';
}

/// Finds the RomM ROM a local game corresponds to when there is no link, for
/// scraping from RomM as a lookup source.
///
/// Built from the RomM ROMs of **one local system** (the catalog the caller
/// loaded for it), so the platform half of "the same game" is the caller's
/// scoping, exactly as [RommLocalMatcher] documents. Two tiers, strictest
/// first, and each answers only when it is unambiguous:
///
/// 1. **File name.** The local file name equals one of a ROM's
///    [RommLocalMatcher.candidateNames] under [RommLocalMatcher.normalizeName],
///    the same rule the link pass uses, so a scrape and a link can never
///    disagree about a name.
/// 2. **Title.** Only when no file name matched: the local title equals the
///    title of exactly one RomM ROM, where [titleKey] ignores the extension,
///    region and revision tags, case, diacritics, punctuation, `&` against
///    "and", and a trailing ", The".
///
/// Two or more candidates at a tier is [RommScrapeMatchKind.ambiguous], not a
/// pick: regional variants of one game are a legitimate reason for it, and
/// falling through to another source is the safe direction.
class RommScrapeIndex {
  final Map<String, Set<int>> _byFileName = {};
  final Map<String, Set<int>> _byTitle = {};

  /// The number of RomM ROMs indexed.
  final int size;

  RommScrapeIndex.build(Iterable<RommRom> roms) : size = roms.length {
    for (final rom in roms) {
      for (final name in RommLocalMatcher.candidateNames(rom)) {
        final key = RommLocalMatcher.normalizeName(name);
        if (key.isNotEmpty) (_byFileName[key] ??= <int>{}).add(rom.id);
      }
      // The display name and the on-disk stem both name the game; either may
      // carry the form a local file was named after.
      for (final raw in [rom.name, p.basenameWithoutExtension(rom.fsName)]) {
        final key = titleKey(raw);
        if (key.isNotEmpty) (_byTitle[key] ??= <int>{}).add(rom.id);
      }
    }
  }

  /// An index with nothing in it: every lookup is [RommScrapeMatch.none].
  RommScrapeIndex.empty() : size = 0;

  /// Looks [localFileName] (with its extension, as on disk) up.
  RommScrapeMatch lookup(String localFileName) {
    final byName = _byFileName[RommLocalMatcher.normalizeName(localFileName)];
    if (byName != null) {
      return byName.length == 1
          ? RommScrapeMatch.matched(byName.single, RommScrapeMatchTier.fileName)
          : const RommScrapeMatch.ambiguous(RommScrapeMatchTier.fileName);
    }
    final key = titleKey(p.basenameWithoutExtension(localFileName));
    if (key.isEmpty) return const RommScrapeMatch.none();
    final byTitle = _byTitle[key];
    if (byTitle == null) return const RommScrapeMatch.none();
    return byTitle.length == 1
        ? RommScrapeMatch.matched(byTitle.single, RommScrapeMatchTier.title)
        : const RommScrapeMatch.ambiguous(RommScrapeMatchTier.title);
  }

  /// The comparison form of a game title; see the class doc for what it
  /// ignores. Empty when nothing alphanumeric is left.
  static String titleKey(String input) {
    var s = input.replaceAll(_tagGroups, ' ').toLowerCase();
    s = _foldDiacritics(s).replaceAll('&', ' and ');
    // "Legend of Zelda, The - A Link to the Past" -> "the legend of zelda - a
    // link to the past": No-Intro style moves the article to the end of the
    // main title, a local file or RomM may use either form.
    final trailingThe = _trailingThe.firstMatch(s);
    if (trailingThe != null) {
      s = 'the ${trailingThe.group(1)}${trailingThe.group(2)}';
    }
    return s.replaceAll(_nonAlphanumeric, ' ').trim().replaceAll(_spaces, ' ');
  }

  /// The words to send RomM as a `search_term` for [localFileName]: its title
  /// without the extension or tags, in the file's own case. Empty when there is
  /// nothing to search for.
  static String searchTerm(String localFileName) {
    final base = p.basenameWithoutExtension(localFileName);
    return base.replaceAll(_tagGroups, ' ').replaceAll(_spaces, ' ').trim();
  }

  static final RegExp _tagGroups = RegExp(r'\([^)]*\)|\[[^\]]*\]');
  static final RegExp _trailingThe = RegExp(
    r'^(.+?),\s*the((?:\s*[-:].*)?\s*)$',
  );
  static final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]+');
  static final RegExp _spaces = RegExp(r'\s+');

  static const Map<String, String> _folds = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'æ': 'ae',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ø': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
    'ß': 'ss',
    'œ': 'oe',
  };

  static String _foldDiacritics(String s) {
    final out = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      out.write(_folds[ch] ?? ch);
    }
    return out.toString();
  }
}
