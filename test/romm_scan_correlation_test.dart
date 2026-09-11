import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_server_task.dart';

/// The two post-review corrections on #254, both about not stating more than
/// the server did.
///
/// `RommService.runTask` answers `id ?? name` so a caller can tell "accepted"
/// from "gated". That makes [RommScanRequest.taskId] a task *name* whenever a
/// 2xx carried no parseable id — and correlating a scan watch against that
/// stand-in rejects the very row it was meant to match, reporting "no scan is
/// running" over the counts the watch just saw accumulate. The same class of
/// false terminal the three-way poll exists to stop.
///
/// The refusal allowlist is the other half: it decides whether the user is
/// told to go and start a scan in RomM's web UI, which is advice about a
/// permanent policy. A status that means "busy, try later" must never earn it.
void main() {
  group('correlationId', () {
    test('a real id is correlated', () {
      const request = RommScanRequest(
        RommScanRequestOutcome.queued,
        taskName: 'scan_library',
        taskId: 'job-7',
      );
      expect(request.correlationId, 'job-7');
    });

    test('the task name standing in for an id is not correlated', () {
      // The regression: `runTask` returned `name` because the 2xx carried no
      // id. Correlating on it rejects the finished row, whose id is the
      // server's real one.
      const request = RommScanRequest(
        RommScanRequestOutcome.queued,
        taskName: 'scan_library',
        taskId: 'scan_library',
      );
      expect(
        request.correlationId,
        isNull,
        reason: 'the stand-in name must fall back to the uncorrelated path',
      );
    });

    test('an absent or empty id is not correlated', () {
      expect(
        const RommScanRequest(
          RommScanRequestOutcome.queued,
          taskName: 'scan_library',
        ).correlationId,
        isNull,
      );
      expect(
        const RommScanRequest(
          RommScanRequestOutcome.queued,
          taskName: 'scan_library',
          taskId: '',
        ).correlationId,
        isNull,
      );
    });
  });

  group('isRefusalStatus', () {
    test('RomM\'s own refusals are refusals', () {
      for (final status in [400, 404, 405, 422]) {
        expect(
          RommScanRequest.isRefusalStatus(status),
          isTrue,
          reason: '$status is RomM refusing to run the task',
        );
      }
    });

    test('a transient status never sends the user to the web UI', () {
      // A proxy answering while RomM restarts, a rate limit, a timeout, an
      // expired session: none of them say anything about scan policy.
      for (final status in [408, 429, 500, 502, 503, 504, 401]) {
        expect(
          RommScanRequest.isRefusalStatus(status),
          isFalse,
          reason: '$status is transient, not a policy',
        );
      }
    });

    test('409 is transient, not a refusal', () {
      // `runTask` maps an already-running body to taskBusy before any status
      // is read, so a 409 only lands here when its wording escaped that — and
      // calling that a permanent policy is a guess.
      expect(RommScanRequest.isRefusalStatus(409), isFalse);
    });

    test('a status-less throw is not a refusal', () {
      expect(RommScanRequest.isRefusalStatus(null), isFalse);
    });
  });
}
