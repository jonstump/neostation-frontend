import 'romm_firmware.dart';

/// Whether the destination already holds the firmware file RomM lists.
///
/// Deliberately coarse: the panel decides what a row may do from this alone,
/// and the presence check behind it never reads a byte of the file (see
/// `RommFirmwareService.localStateOf`).
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
enum RommFirmwareLocalState {
  /// A file with the same name and the same size is in the destination.
  present,

  /// No such file, or one whose size differs from the server's.
  missing,

  /// The server lists the record but no longer has the bytes
  /// (`missing_from_fs`), so it can be shown but never downloaded.
  serverMissing,

  /// No BIOS destination is known yet, so presence is not a question that can
  /// be answered. Distinct from [missing] so the panel offers "choose a
  /// folder" rather than a download that has nowhere to land.
  unknownDestination,
}

/// What the optional md5 check has said about a present file so far.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
enum RommFirmwareVerifyState {
  /// Not asked yet.
  unchecked,

  /// The digest is being streamed off the UI isolate.
  checking,

  /// The local md5 equals the server's.
  match,

  /// The local md5 differs from the server's — the file is present but is not
  /// the file RomM holds.
  mismatch,

  /// The local file could not be read, so nothing was compared.
  unreadable,
}

/// One row of the firmware panel: what the server lists, what the destination
/// holds, and what a verify pass has concluded.
///
/// Immutable and free of Flutter, so the panel's row states and the enablement
/// of every action are decided by pure code a unit test can drive.
// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
class RommFirmwareRow {
  final RommFirmware firmware;
  final RommFirmwareLocalState state;
  final RommFirmwareVerifyState verify;

  /// True while this row's bytes are being downloaded; `progress` is the
  /// fraction received, or null when the server sent no content length.
  final bool downloading;
  final double? progress;

  const RommFirmwareRow({
    required this.firmware,
    required this.state,
    this.verify = RommFirmwareVerifyState.unchecked,
    this.downloading = false,
    this.progress,
  });

  /// Whether this row's file can be downloaded right now.
  ///
  /// A row the server flagged `missing_from_fs` is never downloadable — the
  /// bytes are gone from RomM's own storage, so the request could only 404.
  /// This is where ADR-0012's "listed, but not downloadable" is enforced, so
  /// the action must be gated on this getter and not on the state alone.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  bool get canDownload =>
      !downloading &&
      !firmware.missingFromFs &&
      (state == RommFirmwareLocalState.missing ||
          state == RommFirmwareLocalState.present);

  /// Whether "Verify" applies: the file is here and the server published an
  /// md5 to compare it against.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Local Presence And Verification"
  bool get canVerify =>
      !downloading &&
      state == RommFirmwareLocalState.present &&
      (firmware.md5?.isNotEmpty ?? false) &&
      verify != RommFirmwareVerifyState.checking;

  /// Whether "Download all missing" would include this row.
  bool get isDownloadableMissing =>
      !firmware.missingFromFs && state == RommFirmwareLocalState.missing;

  RommFirmwareRow copyWith({
    RommFirmwareLocalState? state,
    RommFirmwareVerifyState? verify,
    bool? downloading,
    double? progress,
    bool clearProgress = false,
  }) {
    return RommFirmwareRow(
      firmware: firmware,
      state: state ?? this.state,
      verify: verify ?? this.verify,
      downloading: downloading ?? this.downloading,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }

  /// The rows "Download all missing" would fetch, in listing order.
  static List<RommFirmwareRow> downloadableMissing(
    Iterable<RommFirmwareRow> rows,
  ) => rows.where((r) => r.isDownloadableMissing).toList();

  /// Whether the "Download all missing" action is enabled: a destination is
  /// known, nothing is downloading, and at least one row can actually be
  /// fetched.
  // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Panel"
  static bool canDownloadAll(
    Iterable<RommFirmwareRow> rows, {
    required bool hasDestination,
    required bool busy,
  }) {
    if (!hasDestination || busy) return false;
    return rows.any((r) => r.isDownloadableMissing);
  }

  @override
  String toString() =>
      'RommFirmwareRow(${firmware.fileName}, ${state.name}, ${verify.name})';
}
