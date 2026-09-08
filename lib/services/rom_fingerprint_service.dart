import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:neostation/services/logger_service.dart';
import '../models/rom_fingerprint.dart';
import '../utils/optimized_md5_utils.dart';
import 'archive_service.dart';
import 'retroachievements_hash_service.dart';

/// Computes the dump identity of a ROM: the hashes external databases index it
/// under.
///
/// Separate from [RetroAchievementsHashService] on purpose. RA's hashes are
/// rcheevos transforms (header-stripped NES, per-console offsets, arcade by
/// filename) and match only RA; this produces the plain crc32/md5/size of the
/// ROM image, which is what ScreenScraper, No-Intro and Redump key on.
///
/// Verified against the live ScreenScraper API: `crc`, `md5`, `sha1` and
/// `romtaille` each resolve a lookup on their own, case-insensitively, so the
/// cheap crc-only path below is sufficient to identify a ROM.
class RomFingerprintService {
  RomFingerprintService._();

  static final _log = LoggerService.instance;

  /// Maximum file size permitted for fingerprinting (512 MB), matching what
  /// RetroAchievements hashing allows.
  static const int maxFileSizeBytes =
      RetroAchievementsHashService.maxFileSizeBytes;

  /// Why a ROM could not be fingerprinted. Mirrors the RetroAchievements skip
  /// vocabulary so the two parked-ROM columns read the same way.
  static const String skipMissing = 'missing';
  static const String skipOversize = 'oversize';
  static const String skipDisc = 'disc';
  static const String skipExtractFailed = 'extract_failed';
  static const String skipError = 'error';

  /// Skip reasons that are deterministic for a given file: retrying cannot
  /// succeed until the file itself changes, so a ROM parked with one of these
  /// is not re-attempted on later scrapes (a fresh fingerprint write clears the
  /// marker). The reasons outside this set — [skipMissing], [skipError] — cover
  /// transient conditions (an unmounted card, an I/O hiccup), so a
  /// user-initiated re-scrape is allowed to try those again.
  static const Set<String> permanentSkipReasons = {
    skipOversize,
    skipDisc,
    skipExtractFailed,
  };

  /// Not a failure: the caller asked for [FingerprintEffort.cheapOnly] and this
  /// ROM's fingerprint would have cost a full read.
  ///
  /// **Must never be persisted** as a skip. Parking a ROM for this would stop
  /// the full pass ever looking at it, and nothing is actually wrong with it.
  static const String deferredCostly = 'deferred_costly';

  /// Fingerprints [romPath] on a background isolate.
  ///
  /// Prefer this from UI-driven code: a scrape walks the whole library and the
  /// slow path reads every byte of every ROM. [effort] is passed through to
  /// [fingerprint]: the RomM link pass asks for [FingerprintEffort.cheapOnly]
  /// so a zip's stored crc32 is read off the main isolate (over SAF that is
  /// still two method-channel reads) and nothing else is read at all.
  // Governing: ADR-0011 (link by content hash), SPEC-0011 REQ "Concurrency Safety"
  static Future<({RomFingerprint? fingerprint, String? skipReason})>
  computeInBackground(
    String romPath,
    String? systemFolderName, {
    bool keepsArchivesPacked = false,
    FingerprintEffort effort = FingerprintEffort.full,
  }) async {
    // Under cheapOnly only a zip costs any I/O (two short reads of its tail);
    // every other path is answered from its extension alone — a disc image
    // is parked, the rest deferred — and an isolate hop would cost more than
    // the answer. Those go straight to [fingerprint].
    if (effort == FingerprintEffort.cheapOnly &&
        !romPath.toLowerCase().endsWith('.zip')) {
      return fingerprint(
        romPath,
        systemFolderName,
        keepsArchivesPacked: keepsArchivesPacked,
        effort: effort,
      );
    }
    return await compute(_computeIsolate, {
      'romPath': romPath,
      'systemFolderName': systemFolderName,
      'keepsArchivesPacked': keepsArchivesPacked,
      'effort': effort.name,
      // SAF reads go through a method channel, which a bare isolate cannot
      // reach; the token is what makes content:// URIs work off the main
      // isolate.
      'token': RootIsolateToken.instance,
    });
  }

  static Future<({RomFingerprint? fingerprint, String? skipReason})>
  _computeIsolate(Map<String, dynamic> params) async {
    final token = params['token'] as RootIsolateToken?;
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }
    return fingerprint(
      params['romPath'].toString(),
      params['systemFolderName']?.toString(),
      keepsArchivesPacked: params['keepsArchivesPacked'] as bool? ?? false,
      effort: FingerprintEffort.values.firstWhere(
        (e) => e.name == params['effort'],
        orElse: () => FingerprintEffort.full,
      ),
    );
  }

  /// Fingerprints [romPath], or explains why it could not be done.
  ///
  /// Returns the reason rather than a bare null so a bulk pass can park the ROM
  /// instead of re-walking it on every run — the same contract
  /// [RetroAchievementsHashService] uses for its hash candidates.
  ///
  /// [keepsArchivesPacked] says the archive *is* the ROM (arcade sets), so it
  /// gets hashed rather than opened. It is passed in rather than looked up:
  /// which systems those are is declared per system in
  /// `assets/systems/<sys>.json` and reached through
  /// [RetroAchievementsHashService.policyForSystem] (#375). Re-deriving it here
  /// would grow a second list that drifts from that one, and would put a
  /// database read on a path that runs once per ROM.
  static Future<({RomFingerprint? fingerprint, String? skipReason})>
  fingerprint(
    String romPath,
    String? systemFolderName, {
    bool keepsArchivesPacked = false,
    FingerprintEffort effort = FingerprintEffort.full,
  }) async {
    if (RetroAchievementsHashService.isDiscContainer(romPath)) {
      // A disc image's identity is per-track; hashing the container says
      // nothing. Parked until disc support is written.
      return (fingerprint: null, skipReason: skipDisc);
    }

    // Arcade sets are identified by the archive itself, so it is the archive
    // that gets hashed. Every other system is indexed by the inner image, which
    // is why hashing the .zip has been unreliable.
    final lower = romPath.toLowerCase();
    final isArchive =
        (lower.endsWith('.zip') || lower.endsWith('.7z')) &&
        !keepsArchivesPacked;

    // The one fingerprint obtainable without reading the ROM: a zip already
    // stores the crc32 of its uncompressed content, and crc alone resolves a
    // ScreenScraper lookup.
    if (isArchive && lower.endsWith('.zip')) {
      final entry = await _largestZipEntry(romPath);
      if (entry != null) {
        return (
          fingerprint: RomFingerprint(
            crc32: _hex32(entry.crc32),
            sizeBytes: entry.sizeBytes,
          ),
          skipReason: null,
        );
      }
    }

    // Everything past here reads the whole ROM. A cheap-only caller stops now
    // and matches by name instead, paying for this only if that misses.
    if (effort == FingerprintEffort.cheapOnly) {
      return (fingerprint: null, skipReason: deferredCostly);
    }

    if (!await OptimizedMd5Utils.fileExists(romPath)) {
      return (fingerprint: null, skipReason: skipMissing);
    }

    if (await OptimizedMd5Utils.getFileSize(romPath) > maxFileSizeBytes) {
      return (fingerprint: null, skipReason: skipOversize);
    }

    var pathToHash = romPath;
    final mustExtract = isArchive;
    if (mustExtract) {
      final extracted = await ArchiveService.extractRom(
        romPath,
        systemFolderName ?? 'unknown',
      );
      if (extracted == null) {
        _log.w('Fingerprint: extraction failed for $romPath');
        return (fingerprint: null, skipReason: skipExtractFailed);
      }
      pathToHash = extracted;
    }

    try {
      return (fingerprint: await _digest(pathToHash), skipReason: null);
    } catch (e) {
      _log.e('Fingerprint failed for $romPath: $e');
      return (fingerprint: null, skipReason: skipError);
    } finally {
      if (mustExtract) {
        await ArchiveService.cleanupTempFolder(
          systemFolderName ?? 'unknown',
          romPath,
        );
      }
    }
  }

  /// Reads the largest member of a zip — its crc32, uncompressed size and
  /// name — straight out of the central directory.
  ///
  /// A zip stores the crc32, uncompressed size and name of every member in a
  /// directory at the end of the file, so all three are readable without
  /// touching the compressed data. The stored checksum is of the *uncompressed*
  /// content — exactly the No-Intro value ScreenScraper indexes — and crc alone
  /// resolves a lookup, so a zipped ROM can be identified without decompressing
  /// or hashing anything.
  ///
  /// Parsed by hand rather than through [ZipDecoder] because the decoder wants
  /// the whole archive: on desktop it can seek, but a SAF `content://` URI has
  /// no seekable stream, so the only way to hand it one is to pull the entire
  /// zip through the method channel — for a 40 MB archive that is ~20 IPC round
  /// trips to read a few hundred bytes of directory. This reads the tail, then
  /// the directory, and nothing else.
  ///
  /// Returns null for anything unexpected — zip64, a spanned archive, an empty
  /// or unreadable directory — leaving the caller to extract and hash instead.
  static Future<({int crc32, int sizeBytes, String name})?> _largestZipEntry(
    String zipPath,
  ) async {
    try {
      final fileSize = await OptimizedMd5Utils.getFileSize(zipPath);
      if (fileSize < _eocdLength) return null;

      // The end-of-central-directory record sits at the very end, followed only
      // by an optional comment of at most 64 KB.
      final tailLength = fileSize < _maxEocdSearch ? fileSize : _maxEocdSearch;
      final tail = await OptimizedMd5Utils.readRange(
        zipPath,
        fileSize - tailLength,
        tailLength,
      );
      if (tail.length < _eocdLength) return null;

      // Scan back for the signature: the comment can contain anything, so the
      // last match is the real record.
      int eocd = -1;
      for (var i = tail.length - _eocdLength; i >= 0; i--) {
        if (_readUint32(tail, i) == _eocdSignature) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) return null;

      final directorySize = _readUint32(tail, eocd + 12);
      final directoryOffset = _readUint32(tail, eocd + 16);
      // 0xFFFFFFFF means the real values live in a zip64 record. Rare below the
      // 512 MB gate, and mis-parsing one would produce a confidently wrong
      // hash, so decline instead.
      if (directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF) {
        return null;
      }
      if (directorySize <= 0 || directoryOffset + directorySize > fileSize) {
        return null;
      }

      final directory = await OptimizedMd5Utils.readRange(
        zipPath,
        directoryOffset,
        directorySize,
      );
      if (directory.length < directorySize) return null;

      // Largest entry wins, matching ArchiveService.extractRom's own rule, so
      // the cheap path and the extract path always agree on which member is
      // the ROM.
      int? bestCrc;
      int bestSize = 0;
      var bestName = '';
      var offset = 0;
      while (offset + _centralHeaderLength <= directory.length) {
        if (_readUint32(directory, offset) != _centralHeaderSignature) break;

        final crc = _readUint32(directory, offset + 16);
        final uncompressedSize = _readUint32(directory, offset + 24);
        final nameLength = _readUint16(directory, offset + 28);
        final extraLength = _readUint16(directory, offset + 30);
        final commentLength = _readUint16(directory, offset + 32);

        // A zip64 entry hides its real size in the extra field; skip it rather
        // than record 0xFFFFFFFF as a size.
        if (uncompressedSize != 0xFFFFFFFF && uncompressedSize > bestSize) {
          bestSize = uncompressedSize;
          bestCrc = crc;
          final nameStart = offset + _centralHeaderLength;
          final nameEnd = nameStart + nameLength;
          // Zip stores names as bytes with no declared encoding unless the
          // UTF-8 flag is set; decoding leniently keeps a name with an odd
          // byte usable rather than throwing away the whole directory read.
          bestName = nameEnd <= directory.length
              ? utf8.decode(
                  directory.sublist(nameStart, nameEnd),
                  allowMalformed: true,
                )
              : '';
        }

        offset +=
            _centralHeaderLength + nameLength + extraLength + commentLength;
      }

      if (bestCrc == null || bestSize <= 0) return null;
      return (crc32: bestCrc, sizeBytes: bestSize, name: bestName);
    } catch (e) {
      _log.w('Zip directory read failed for $zipPath, will extract: $e');
      return null;
    }
  }

  /// The file name of the largest member of the zip at [zipPath], or null when
  /// the directory cannot be read.
  ///
  /// The name RetroArch will show the core, and therefore the name it stamps
  /// on the captures it writes: loading `Set.zip` whose member is
  /// `Game (USA).nes` gives a content path of `…/Set.zip#Game (USA).nes`, and
  /// RetroArch takes the capture's base name from the part after the `#`.
  ///
  /// Any directory components are stripped — a zip may store `roms/Game.nes`,
  /// and only the leaf is the content name. Costs the two short reads
  /// [_largestZipEntry] already does; nothing is decompressed.
  // Governing: ADR-0016 (sync in-game screenshots with RomM), SPEC-0016 REQ "Collector"
  static Future<String?> largestZipEntryName(String zipPath) async {
    final entry = await _largestZipEntry(zipPath);
    final raw = entry?.name.trim() ?? '';
    if (raw.isEmpty) return null;
    final leaf = raw.replaceAll('\\', '/').split('/').last.trim();
    return leaf.isEmpty ? null : leaf;
  }

  /// `PK\x05\x06` — end of central directory.
  static const int _eocdSignature = 0x06054b50;

  /// `PK\x01\x02` — a central directory file header.
  static const int _centralHeaderSignature = 0x02014b50;

  /// Fixed part of the end-of-central-directory record.
  static const int _eocdLength = 22;

  /// Fixed part of a central directory file header, before the variable-length
  /// name, extra and comment fields.
  static const int _centralHeaderLength = 46;

  /// The record plus the largest comment a zip may carry.
  static const int _maxEocdSearch = _eocdLength + 0xFFFF;

  static int _readUint16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _readUint32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  /// Single streamed pass: crc32 and md5 are fed the same chunks, so the second
  /// digest costs no extra I/O.
  static Future<RomFingerprint> _digest(String path) async {
    final digestSink = _DigestSink();
    final md5Input = crypto.md5.startChunkedConversion(digestSink);
    int crc = 0;
    int size = 0;

    await OptimizedMd5Utils.readChunked(path, (chunk) {
      md5Input.add(chunk);
      // getCrc32 resumes from a previous final value, so this is the same
      // checksum a single whole-buffer call would produce.
      crc = getCrc32(chunk, crc);
      size += chunk.length;
    });
    md5Input.close();

    return RomFingerprint(
      crc32: _hex32(crc),
      md5: digestSink.digest.toString(),
      sizeBytes: size,
    );
  }

  static String _hex32(int crc) =>
      crc.toRadixString(16).toUpperCase().padLeft(8, '0');
}

/// Captures the single [crypto.Digest] a chunked conversion emits on close.
///
/// Avoids depending on package:convert's AccumulatorSink for one value.
class _DigestSink implements Sink<crypto.Digest> {
  late final crypto.Digest digest;

  @override
  void add(crypto.Digest value) => digest = value;

  @override
  void close() {}
}

/// How much I/O a caller is willing to pay for a fingerprint.
enum FingerprintEffort {
  /// Only a fingerprint that costs no meaningful I/O — a zip's stored crc32.
  ///
  /// Anything that would read the whole ROM returns
  /// [RomFingerprintService.deferredCostly] instead, so a scrape can try the
  /// filename first and pay for a hash only when that misses.
  cheapOnly,

  /// Read the ROM if that is what identifying it takes.
  full,
}
