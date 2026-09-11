import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_rom_upload.dart';
import 'package:neostation/screens/romm_screen/romm_rom_upload_runner.dart';

/// The line an upload that sent nothing is reported with.
///
/// Issue #235: a system the server has no platform for, a system this
/// install does not know, and a system several RomM platforms fold onto were
/// one enum value and one message — "RomM has no platform matching X" — with
/// no remedy attached to any of them. They are three causes with three
/// different remedies (add it on the server, fix it here, merge them on the
/// server), so each has to reach its own line.
///
/// [RommUploadStrings.earlyEnd] is the seam: the runner resolves every
/// string from the context before the batch starts and this is the pure
/// mapping from an end to one of them.
///
/// Placeholder copy — this cares which template is chosen and what is
/// substituted into it, not the English wording.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Localized
/// User-Facing Text", REQ "Platform Mapping"
const _strings = RommUploadStrings(
  title: 'upload-title',
  preparing: 'preparing',
  progressTemplate: '{name} {current}/{total}',
  summaryTemplate: '{uploaded}/{skipped}/{failed}',
  cancelledTemplate: 'cancelled {summary}',
  disconnectedTemplate: 'disconnected {summary}',
  scanRequested: 'scan-requested',
  scanPending: 'scan-pending',
  linkNow: 'link-now',
  linkNowResultTemplate: 'linked {count}',
  linkNowNothing: 'linked-nothing',
  metadataPushedTemplate: 'metadata-pushed {count}',
  linkFailed: 'link-failed',
  skippedLineTemplate: '{name}: {reason}',
  failedLineTemplate: '{name}: {reason}',
  moreTemplate: '+{count} more',
  cancel: 'cancel',
  confirmBodyTemplate: '{count} {size}',
  confirmAction: 'confirm',
  noPlatformTemplate: 'server-lacks {system}',
  unknownSystemTemplate: 'unknown-here {system}',
  ambiguousPlatformTemplate: 'ambiguous {system} {platforms}',
  nothingToUploadTemplate: 'nothing-to-upload {system}',
  alreadyLinked: 'already-linked',
  busy: 'busy',
  notOffered: 'not-offered',
  skipReasons: <RommUploadSkipReason, String>{},
  failReasons: <RommUploadFailure, String>{},
);

String? _message(
  RommUploadEnd end, {
  String detail = '',
  bool singleGame = false,
}) => _strings.earlyEnd(
  RommUploadSummary.ended(end, endDetail: detail),
  'Atari Lynx',
  singleGame: singleGame,
);

void main() {
  group('the three platform causes each get their own line,', () {
    test('the server has no platform for the system', () {
      expect(_message(RommUploadEnd.noPlatform), 'server-lacks Atari Lynx');
    });

    test('this install does not know the system', () {
      expect(_message(RommUploadEnd.unknownSystem), 'unknown-here Atari Lynx');
    });

    test('several platforms fold onto the system, named', () {
      expect(
        _message(RommUploadEnd.ambiguousPlatform, detail: 'ps, psx'),
        'ambiguous Atari Lynx ps, psx',
      );
    });

    test('and no two of them read the same', () {
      final lines = <String?>{
        _message(RommUploadEnd.noPlatform),
        _message(RommUploadEnd.unknownSystem),
        _message(RommUploadEnd.ambiguousPlatform, detail: 'ps, psx'),
      };

      expect(lines.length, 3);
    });
  });

  group('the ends that are not about platforms are untouched,', () {
    test('a bulk run with nothing left to send names the system', () {
      expect(
        _message(RommUploadEnd.nothingToUpload),
        'nothing-to-upload Atari Lynx',
      );
    });

    test('one game that is already linked says so instead', () {
      expect(
        _message(RommUploadEnd.nothingToUpload, singleGame: true),
        'already-linked',
      );
    });

    test('a closed gate', () {
      expect(_message(RommUploadEnd.notOffered), 'not-offered');
    });

    // The user declined the confirmation: they know what happened, and a
    // toast telling them would be telling them their own answer.
    test('a declined confirmation reports nothing', () {
      expect(_message(RommUploadEnd.declined), isNull);
    });

    test('an end that did start the batch reports nothing here', () {
      expect(_message(RommUploadEnd.completed), isNull);
      expect(_message(RommUploadEnd.cancelled), isNull);
      expect(_message(RommUploadEnd.disconnected), isNull);
    });
  });

  // `neverStarted` is what sends the runner down the early-end path at all:
  // a new end that forgets it would be reported as a summary of zero files.
  test('every cause that sends nothing counts as never started', () {
    for (final end in const [
      RommUploadEnd.noPlatform,
      RommUploadEnd.unknownSystem,
      RommUploadEnd.ambiguousPlatform,
      RommUploadEnd.nothingToUpload,
      RommUploadEnd.notOffered,
      RommUploadEnd.declined,
    ]) {
      expect(RommUploadSummary.ended(end).neverStarted, isTrue, reason: '$end');
    }
  });
}
