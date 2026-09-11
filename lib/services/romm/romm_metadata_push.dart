import '../../models/metadata_field_sources.dart';
import '../../repositories/scraper_repository.dart';
import '../logger_service.dart';

/// The local metadata columns that have a RomM field to go to, and the field
/// each one maps to on `PUT /api/roms/{id}`.
///
/// Deliberately two entries. Everything else the `user_screenscraper_metadata`
/// row holds either has no RomM field at all (the five non-English
/// descriptions; `publisher`) or lives under the provider-owned `metadatum`
/// object, which this endpoint's form does not reach — `rating`,
/// `release_date`, `genre`, `players`, and `developer`, which could not
/// round-trip anyway because RomM keeps one flat `companies` list with no
/// developer/publisher split. Game modes, the other half of #237, has no
/// column here to map: nothing in NeoStation ever collects it.
///
/// `summary` is the unverified half of the pair. `name` is known to be
/// accepted — `RommService.applyRomMatch` has been sending it since ADR-0019
/// — while nothing in this repository establishes that the endpoint accepts
/// `summary`. It is sent as its own entry precisely so that it can be dropped
/// by deleting one line if a server rejects it.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source Provenance"
const Map<String, String> rommMetadataPushFields = <String, String>{
  'real_name': 'name',
  'description_en': 'summary',
};

/// The `metadata_source` values whose work is NeoStation's to push back.
///
/// [MetadataSource.romm] is the one that is missing, and that is the whole
/// point: a value RomM gave us is the server's own, and handing it back is at
/// best a no-op and at worst overwrites a newer server-side edit with a stale
/// copy of itself.
final Set<String> _pushableSources = <String>{
  for (final source in MetadataSource.values)
    if (source != MetadataSource.romm) source.dbValue,
};

/// One local game a push will try to send metadata for. [romname] is the
/// `user_screenscraper_metadata.filename` key (which is `GameModel.romname`,
/// the on-disk name *with* its extension) and [systemFolder] the NeoStation
/// system folder it lives under — the same pair the link map is keyed by.
typedef RommMetadataPushTarget = ({String romname, String systemFolder});

/// Resolves a system folder to its `app_systems.id`, or null.
typedef RommMetadataSystemIdReader = Future<String?> Function(String folder);

/// Reads the raw `user_screenscraper_metadata` row for a game, or null.
typedef RommMetadataRowReader =
    Future<Map<String, dynamic>?> Function(String appSystemId, String filename);

/// The RomM ROM id a local game is linked to, or null when it is not linked.
typedef RommMetadataRomIdReader =
    Future<int?> Function(String romname, String systemFolder);

/// Sends one built field map to one ROM. True when the server took it, false
/// when the call was gated (no `roms.write`, so no later target will fare
/// better either).
typedef RommMetadataSender =
    Future<bool> Function(int romId, Map<String, String> fields);

/// What one [RommMetadataPush.run] did.
typedef RommMetadataPushSummary = ({
  /// ROMs the server confirmed an update for.
  int pushed,

  /// Targets that sent nothing: not linked yet, no metadata row, or nothing
  /// in the row that was both non-blank and ours to send.
  int skipped,

  /// Targets whose request failed.
  int failed,
});

/// The push that did not exist before #237: NeoStation's scraped title and
/// description onto the RomM entries for games it just uploaded.
///
/// The build step is pure ([buildRommMetadataPush]) and the run step takes
/// every database and network touch as a callback, in the style of
/// `RommLibraryLinker` and `RommMetadataFetch`, so the rules that matter —
/// never send blank, never send RomM its own values back — are testable
/// against the request body without a server.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source Provenance",
// ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
class RommMetadataPush {
  const RommMetadataPush._();

  static final _log = LoggerService.instance;

  /// Runs the push for [targets], oldest-first, and reports what it did.
  ///
  /// Per target: resolve the RomM ROM id (a target that is not linked yet is
  /// skipped — see the ordering note on the caller: an uploaded ROM has no id
  /// until the server has scanned it and the link pass has run), read the
  /// metadata row, build the field map, and send it when it is non-empty.
  ///
  /// Stops early — the rest counted as skipped — the first time [send]
  /// answers false, which is the gated answer: the scope is a property of the
  /// connection, not of the ROM, so every later target would be refused the
  /// same way. Never throws; a failed target is logged once and counted.
  static Future<RommMetadataPushSummary> run({
    required Iterable<RommMetadataPushTarget> targets,
    required RommMetadataSystemIdReader resolveSystemId,
    required RommMetadataRowReader readRow,
    required RommMetadataRomIdReader readRomId,
    required RommMetadataSender send,
  }) async {
    var pushed = 0;
    var skipped = 0;
    var failed = 0;
    var gated = false;

    for (final target in targets) {
      if (gated) {
        skipped++;
        continue;
      }
      try {
        final romId = await readRomId(target.romname, target.systemFolder);
        if (romId == null) {
          _log.i(
            'RomM metadata push skipped: file="${target.romname}" '
            'system=${target.systemFolder} reason=unlinked',
          );
          skipped++;
          continue;
        }
        final systemId = await resolveSystemId(target.systemFolder);
        if (systemId == null || systemId.isEmpty) {
          _log.i(
            'RomM metadata push skipped: rom=$romId '
            'system=${target.systemFolder} reason=no_local_system',
          );
          skipped++;
          continue;
        }
        final row = await readRow(systemId, target.romname);
        final fields = buildRommMetadataPush(row);
        if (fields.isEmpty) {
          _log.i(
            'RomM metadata push skipped: rom=$romId '
            'file="${target.romname}" reason=nothing_to_send',
          );
          skipped++;
          continue;
        }
        final ok = await send(romId, fields);
        if (ok) {
          _log.i(
            'RomM metadata pushed: rom=$romId file="${target.romname}" '
            'fields=${fields.keys.join(",")}',
          );
          pushed++;
        } else {
          // The service already logged the gate, once per connection.
          _log.i('RomM metadata push skipped: rom=$romId reason=gated');
          skipped++;
          gated = true;
        }
      } catch (e) {
        _log.w(
          'RomM metadata push failed: file="${target.romname}" '
          'system=${target.systemFolder} error=$e',
        );
        failed++;
      }
    }

    return (pushed: pushed, skipped: skipped, failed: failed);
  }
}

/// The request body for one ROM, built from its raw
/// `user_screenscraper_metadata` [row] — keyed by RomM field name, ready to
/// hand to `RommService.applyRomMetadata`.
///
/// Three rules decide whether a column travels, and all three are here rather
/// than at the call site so the body itself can be asserted:
///
/// * **Never blank.** A column that is null, empty or whitespace is left out
///   entirely. RomM's update endpoint reads an absent field as "leave it
///   alone" and a present-but-empty one as a value, so sending a blank `name`
///   would erase the entry's title for every client of that server.
/// * **Never RomM's own value.** `field_sources` (#248) says who last wrote
///   each column; a column it attributes to `romm` is skipped. Per-field, so
///   a row RomM created and a ScreenScraper pass then filled the gaps of
///   pushes the ScreenScraper half and keeps quiet about the rest.
/// * **Fall back to the row.** `field_sources` is empty for rows written
///   before it existed and for rows a replace-mode pass rebuilt, so a column
///   with no entry of its own falls back to the row-level `metadata_source`:
///   it travels only when the row names a source in [_pushableSources]. A row
///   whose source is `romm` sends nothing, and so does a row with no source
///   at all — "we do not know who wrote this" is not a licence to write it to
///   somebody else's library.
///
/// A null [row] (the game was never scraped) yields an empty map.
// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Metadata Source Provenance"
Map<String, String> buildRommMetadataPush(Map<String, Object?>? row) {
  if (row == null) return const <String, String>{};
  final sources = MetadataFieldSources.fromDb(row[MetadataFieldSources.column]);
  final rowSource = row['metadata_source']?.toString();
  final out = <String, String>{};
  for (final entry in rommMetadataPushFields.entries) {
    final value = row[entry.key]?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    // Per-field provenance first, the row's own source as the fallback; a
    // null from both means nothing recorded, and null is not in the set.
    if (!_pushableSources.contains(sources.sourceOf(entry.key) ?? rowSource)) {
      continue;
    }
    out[entry.value] = value;
  }
  return out;
}
