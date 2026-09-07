import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_firmware.dart';
import 'package:neostation/models/romm_firmware_row.dart';

/// The firmware panel's pure layout rules: which state a row reads as, which
/// actions it offers, and what "Download all missing" would take.
///
/// The panel itself is a dialog, so this is where the enablement logic is
/// pinned down — in particular that a row RomM flagged `missing_from_fs` is
/// never downloadable, which is ADR-0012's "listed, but not downloadable".
///
/// Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ
/// "Firmware Panel"
void main() {
  RommFirmware fw({
    String name = 'scph5501.bin',
    int size = 524288,
    String? md5 = 'd10b6509b7b9c9b7ff8f0d1c9f9c2e4f',
    bool missingFromFs = false,
    bool isVerified = false,
  }) => RommFirmware(
    id: 1,
    platformId: 7,
    fileName: name,
    fileSizeBytes: size,
    md5: md5,
    missingFromFs: missingFromFs,
    isVerified: isVerified,
  );

  RommFirmwareRow row({
    RommFirmware? firmware,
    RommFirmwareLocalState state = RommFirmwareLocalState.missing,
    RommFirmwareVerifyState verify = RommFirmwareVerifyState.unchecked,
    bool downloading = false,
  }) => RommFirmwareRow(
    firmware: firmware ?? fw(),
    state: state,
    verify: verify,
    downloading: downloading,
  );

  group('per-row actions', () {
    test('a missing file can be downloaded and not verified', () {
      final r = row();
      expect(r.canDownload, isTrue);
      expect(r.canVerify, isFalse);
      expect(r.isDownloadableMissing, isTrue);
    });

    test('a present file with a server md5 can be verified', () {
      final r = row(state: RommFirmwareLocalState.present);
      expect(r.canVerify, isTrue);
      // Re-downloading a present file is how a mismatch is repaired.
      expect(r.canDownload, isTrue);
      expect(r.isDownloadableMissing, isFalse);
    });

    test('a present file with no server md5 offers no verify', () {
      final r = row(
        firmware: fw(md5: null),
        state: RommFirmwareLocalState.present,
      );
      expect(r.canVerify, isFalse);
    });

    test('a row missing on the server can never be downloaded', () {
      final r = row(
        firmware: fw(missingFromFs: true),
        state: RommFirmwareLocalState.serverMissing,
      );
      expect(r.canDownload, isFalse);
      expect(r.canVerify, isFalse);
      expect(r.isDownloadableMissing, isFalse);
    });

    test('no destination means nothing to download or verify', () {
      final r = row(state: RommFirmwareLocalState.unknownDestination);
      expect(r.canDownload, isFalse);
      expect(r.canVerify, isFalse);
      expect(r.isDownloadableMissing, isFalse);
    });

    test('a downloading row offers nothing while it transfers', () {
      final r = row(downloading: true);
      expect(r.canDownload, isFalse);
      expect(r.canVerify, isFalse);
    });

    test('a verify already in flight is not offered again', () {
      final r = row(
        state: RommFirmwareLocalState.present,
        verify: RommFirmwareVerifyState.checking,
      );
      expect(r.canVerify, isFalse);
    });
  });

  group('download all missing', () {
    final rows = <RommFirmwareRow>[
      row(firmware: fw(name: 'a.bin')),
      row(
        firmware: fw(name: 'b.bin'),
        state: RommFirmwareLocalState.present,
      ),
      row(
        firmware: fw(name: 'c.bin', missingFromFs: true),
        state: RommFirmwareLocalState.serverMissing,
      ),
      row(firmware: fw(name: 'd.bin')),
    ];

    test('takes only the rows the server can actually serve', () {
      expect(
        RommFirmwareRow.downloadableMissing(
          rows,
        ).map((r) => r.firmware.fileName),
        ['a.bin', 'd.bin'],
      );
    });

    test('is enabled with a destination and something to fetch', () {
      expect(
        RommFirmwareRow.canDownloadAll(rows, hasDestination: true, busy: false),
        isTrue,
      );
    });

    test('is disabled without a destination or while busy', () {
      expect(
        RommFirmwareRow.canDownloadAll(
          rows,
          hasDestination: false,
          busy: false,
        ),
        isFalse,
      );
      expect(
        RommFirmwareRow.canDownloadAll(rows, hasDestination: true, busy: true),
        isFalse,
      );
    });

    test('is disabled when only unservable rows are missing', () {
      expect(
        RommFirmwareRow.canDownloadAll(
          [rows[1], rows[2]],
          hasDestination: true,
          busy: false,
        ),
        isFalse,
      );
    });
  });

  test('copyWith can clear the progress fraction', () {
    final r = row(downloading: true).copyWith(progress: 0.5);
    expect(r.progress, 0.5);
    expect(
      r.copyWith(downloading: false, clearProgress: true).progress,
      isNull,
    );
  });
}
