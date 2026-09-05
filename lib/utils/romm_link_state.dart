import 'package:path/path.dart' as p;

import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/utils/rom_tree.dart';

/// How a local game is linked to RomM, as the Manage tab reports it.
enum RommLinkState {
  /// No `app_romm_rom_map` row exists for the game.
  notLinked,

  /// A row exists that the download path or an automatic pass wrote — or a
  /// legacy row with a null `link_source`, which reads the same way.
  auto,

  /// A row the user picked by hand in the link picker.
  manual,
}

/// Derives the link state the Manage tab shows from the mapping row (or its
/// absence). Pure so the null-source rule is unit-testable on its own:
/// [RommLinkSource.fromDb] already maps a null column to [RommLinkSource.auto],
/// and only [RommLinkSource.manual] is reported as manual.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link State Display"
RommLinkState rommLinkStateOf(RommSaveMapping? mapping) {
  if (mapping == null) return RommLinkState.notLinked;
  return mapping.source == RommLinkSource.manual
      ? RommLinkState.manual
      : RommLinkState.auto;
}

/// The on-disk filename a manual link must be keyed by.
///
/// `app_romm_rom_map.romname` is written with the file's basename *with* its
/// extension (`Game.sfc`, or the `.m3u` of a multi-disc game) by both the
/// download path and `RommProvider.linkLocalCopy`, while `GameModel.romname`
/// carries it stripped. `putManualMapping` replaces only the row with the same
/// key, so the picker derives the basename from [romPath] — decoding the SAF
/// `content://` form Android stores — and falls back to [romname] when there
/// is no path to read it from.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
String rommLinkKeyFor({required String? romPath, required String romname}) {
  if (romPath == null || romPath.isEmpty) return romname;
  final base = p.basename(normalizeRomPath(romPath));
  return base.isEmpty ? romname : base;
}

final RegExp _innermostParens = RegExp(r'\([^()]*\)');
final RegExp _innermostBrackets = RegExp(r'\[[^\[\]]*\]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// A trailing `Rev 1` / `Rev A` / `v1.2` token that sits outside any
/// brackets. The digit requirement keeps roman numerals (`Final Fantasy VII`)
/// and a bare trailing `3` (`Super Mario Bros. 3`) intact.
final RegExp _trailingRevision = RegExp(
  r'\s+(?:rev\s*[a-z0-9]+|v\d+(?:\.\d+)*)$',
  caseSensitive: false,
);

/// A ` - ` separator left dangling at the end once its tags are gone
/// (`Game - (USA)` → `Game - `).
final RegExp _trailingSeparator = RegExp(r'\s*[-–—]+$');

/// Strips the release tags a ROM filename carries so what is left is the
/// title RomM's name search can match.
///
/// Every `(...)` and `[...]` group goes (nested and repeated ones included),
/// then trailing `Rev N` / `vN.N` tokens that stood outside brackets, then a
/// separator left dangling by the removal, and whitespace is collapsed. Title
/// words are never touched: `Super Mario Bros. 3` and `Final Fantasy VII`
/// come back as they went in. A name that was nothing but tags returns the
/// trimmed original rather than an empty query.
// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"
String cleanRomTitle(String name) {
  final original = name.trim();
  var title = original;

  // Innermost groups first so nesting unwinds one layer per pass.
  String stripped;
  do {
    stripped = title;
    title = title
        .replaceAll(_innermostParens, ' ')
        .replaceAll(_innermostBrackets, ' ');
  } while (title != stripped);

  title = title.replaceAll(_whitespaceRun, ' ').trim();

  String trimmed;
  do {
    trimmed = title;
    title = title
        .replaceFirst(_trailingRevision, '')
        .replaceFirst(_trailingSeparator, '')
        .trim();
  } while (title != trimmed);

  return title.isEmpty ? original : title;
}
