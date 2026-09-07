import 'dart:io';

import 'package:path/path.dart' as p;

/// Serial number for [dirIfWritable]'s probe file.
///
/// A bulk sync resolves destinations for several ROMs of the same system at
/// once, so the probe filename MUST be unique per call: with a shared name
/// the concurrent probes clobber each other — one call deletes the file
/// another is about to delete, that delete throws, and the folder is reported
/// unwritable even though it is perfectly fine. That surfaced as ROMs failing
/// with "no writable folder" on a bulk sync and then succeeding on a retry.
int _writeProbeSerial = 0;

/// Ensures [path] exists and is writable via a probe-file round-trip,
/// returning it on success or null when the folder can't be written to.
///
/// This is the app's one definition of "a folder a RomM download may write
/// into". `RommProvider` resolves ROM destinations through it and
/// `BiosDestinationService` resolves the BIOS destination through it, so an
/// existing-but-unwritable folder (Android without All Files Access) is
/// rejected before a transfer starts rather than at the first byte written.
///
/// It lives in `lib/utils/` rather than on either caller because both of them
/// need it and the dependency direction only runs one way: a service must not
/// import a provider to borrow a filesystem helper.
///
/// Note it *creates* [path]. A caller that must not conjure a folder — the
/// BIOS resolver, whose candidates have to fall through when they have been
/// deleted or live on an unmounted card — checks existence first.
///
/// Safe to call concurrently for the same directory — see [_writeProbeSerial].
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "BIOS Destination"
Future<String?> dirIfWritable(String path) async {
  final dir = Directory(path);
  final probe = File(
    p.join(dir.path, '.romm_write_test_${_writeProbeSerial++}'),
  );
  try {
    await dir.create(recursive: true);
    await probe.writeAsString('');
    return dir.path;
  } catch (_) {
    return null;
  } finally {
    // Always clean up, including on the failure path where the write landed
    // but something later threw — a stray probe file would otherwise be
    // indexed by the library scan.
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // Best-effort: a probe we can't remove is cosmetic, not a failure.
    }
  }
}
