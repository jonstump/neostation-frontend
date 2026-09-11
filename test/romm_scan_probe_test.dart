import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/models/romm_scan_task_status.dart';
import 'package:neostation/models/romm_server_task.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/services/romm_service.dart';

/// Asking the server what it will run, instead of guessing.
///
/// NeoStation used to `POST /api/tasks/run/scan_library` after every upload
/// and report it as queued. Issue #170 carries the device log of what really
/// happens on RomM 5.1.0 — `status=400`, twice — and RomM's registry marks
/// that task as not manually runnable, so the request can never have queued
/// anything. These pin the replacement: read each task's `manual_run` from
/// `GET /api/tasks`, run only a scan the server says it will run, and say so
/// honestly when there is none.
///
/// The server shapes below are the documented ones; the parsers are
/// deliberately tolerant of the others, which is what the odd-shape cases
/// cover. Nothing here has been verified against a live server — that is the
/// point of the tolerance.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Maintenance Tasks"; ADR-0014, SPEC-0014 REQ "Scan And Link
/// After Upload"

class _FakeRommService extends RommService {
  RommScopeState scope = RommScopeState.granted;
  List<RommServerTask>? tasks;
  final List<String> ran = [];
  String? taskId = 'task-1';
  Object? runThrows;

  @override
  RommScopeState hasScope(RommScopeGroup group) => scope;

  @override
  Future<List<RommServerTask>?> listServerTasks() async => tasks;

  @override
  Future<String?> runTask(String name) async {
    ran.add(name);
    final error = runThrows;
    if (error != null) throw error;
    return taskId;
  }
}

class _FakeProvider extends RommProvider {
  final _FakeRommService fake;
  bool connected = true;

  _FakeProvider(this.fake);

  @override
  bool get isConnected => connected;

  @override
  RommService get service => fake;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading GET /api/tasks', () {
    test('takes manual_run from a bare list of tasks', () {
      final tasks = RommServerTask.listFrom(
        jsonDecode('''
        [
          {"name": "scan_library", "title": "Scan library", "manual_run": false},
          {"name": "sync_folder_scan", "title": "Sync folder scan", "manual_run": true},
          {"name": "cleanup_missing_roms", "title": "Cleanup", "manual_run": true}
        ]
        '''),
      );

      expect(tasks.map((t) => t.name), [
        'scan_library',
        'sync_folder_scan',
        'cleanup_missing_roms',
      ]);
      expect(tasks.first.manualRun, isFalse);
      expect(tasks.first.runnable, isFalse);
      expect(tasks[1].runnable, isTrue);
    });

    test('reads a registry keyed by task name', () {
      final tasks = RommServerTask.listFrom(
        jsonDecode('''
        {"tasks": {
          "scan_library": {"manual_run": false, "enabled": true},
          "sync_folder_scan": {"manual_run": true, "enabled": true}
        }}
        '''),
      );
      expect(tasks.map((t) => t.name).toSet(), {
        'scan_library',
        'sync_folder_scan',
      });
      expect(
        tasks.firstWhere((t) => t.name == 'sync_folder_scan').manualRun,
        isTrue,
      );
    });

    test('leaves manual_run unknown rather than guessing', () {
      final tasks = RommServerTask.listFrom(
        jsonDecode('[{"name": "scan_library", "title": "Scan library"}]'),
      );
      expect(tasks.single.manualRun, isNull);
      expect(
        tasks.single.runnable,
        isTrue,
        reason: 'unknown must not read as refused',
      );
    });

    test('a body it cannot read yields nothing at all', () {
      expect(
        RommServerTask.listFrom(jsonDecode('{"detail": "nope"}')),
        isEmpty,
      );
      expect(RommServerTask.listFrom(jsonDecode('[]')), isEmpty);
    });
  });

  group('picking the scan to run', () {
    test('skips the scan the server will not run manually', () {
      final pick = RommServerTask.pickScan(const [
        RommServerTask(name: 'scan_library', manualRun: false),
        RommServerTask(name: 'sync_folder_scan', manualRun: true),
      ]);
      expect(pick?.name, 'sync_folder_scan');
    });

    test('is null when every scan task is refused — the stock server', () {
      final pick = RommServerTask.pickScan(const [
        RommServerTask(name: 'scan_library', manualRun: false),
        RommServerTask(name: 'sync_folder_scan', manualRun: false),
        RommServerTask(name: 'cleanup_missing_roms', manualRun: true),
      ]);
      expect(
        pick,
        isNull,
        reason: 'cleanup prunes rows; it is not a stand-in for a scan',
      );
    });

    test('never picks a disabled task', () {
      final pick = RommServerTask.pickScan(const [
        RommServerTask(
          name: 'sync_folder_scan',
          manualRun: true,
          enabled: false,
        ),
      ]);
      expect(pick, isNull);
    });

    test('prefers a declared manual_run over an unknown one', () {
      final pick = RommServerTask.pickScan(const [
        RommServerTask(name: 'quick_scan'),
        RommServerTask(name: 'sync_folder_scan', manualRun: true),
      ]);
      expect(pick?.name, 'sync_folder_scan');
    });
  });

  group('RommProvider.requestLibraryScan', () {
    late _FakeRommService svc;
    late _FakeProvider provider;

    setUp(() {
      svc = _FakeRommService();
      provider = _FakeProvider(svc);
    });

    test('runs the task the server says it will run', () async {
      svc.tasks = const [
        RommServerTask(name: 'scan_library', manualRun: false),
        RommServerTask(name: 'sync_folder_scan', manualRun: true),
      ];

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.queued);
      expect(request.taskName, 'sync_folder_scan');
      expect(svc.ran, ['sync_folder_scan']);
    });

    test('sends nothing when the server names no runnable scan', () async {
      svc.tasks = const [
        RommServerTask(name: 'scan_library', manualRun: false),
        RommServerTask(name: 'cleanup_missing_roms', manualRun: true),
      ];

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.refused);
      expect(request.scanExpected, isFalse);
      expect(
        svc.ran,
        isEmpty,
        reason: 'a task the server refuses must not be asked for anyway',
      );
    });

    test('falls back to asking when the registry cannot be read', () async {
      svc.tasks = null;

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.queued);
      expect(svc.ran, ['scan_library']);
    });

    test('a 400 refusal is refused, not pending', () async {
      svc.tasks = null;
      svc.runThrows = RommException('nope', statusCode: 400);

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.refused);
    });

    test('a scan already running stays pending', () async {
      svc.tasks = null;
      svc.runThrows = RommException(
        'busy',
        statusCode: 400,
        kind: RommErrorKind.taskBusy,
      );

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.alreadyRunning);
      expect(request.scanExpected, isTrue);
    });

    test('a request that never reached the server is not a refusal', () async {
      svc.tasks = null;
      svc.runThrows = RommException('Request timed out');

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.unavailable);
    });

    // A refusal sends the user to RomM's web interface to start a scan by
    // hand — advice about a permanent policy. A proxy answering 502 while
    // RomM restarts is not that, and `runTask`'s own doc records that a proxy
    // may answer for RomM.
    // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
    test('a transient status is not the server refusing to scan', () async {
      // 409 sits here rather than with the refusals: a conflict is
      // usually transient, and `runTask` maps an already-running body to
      // taskBusy before any status is read, so a 409 only arrives when its
      // wording escaped that check. Calling that a permanent policy is a
      // guess, and the cost of guessing wrong is telling the user to go and
      // fix a server that was merely busy.
      for (final status in const [408, 409, 429, 500, 502, 503, 504]) {
        svc
          ..tasks = null
          ..ran.clear()
          ..runThrows = RommException('transient', statusCode: status);

        final request = await provider.requestLibraryScan();

        expect(
          request.outcome,
          RommScanRequestOutcome.unavailable,
          reason: '$status is a server that was briefly unreachable',
        );
      }
    });

    test('an expired session is not the server refusing to scan', () async {
      svc.tasks = null;
      svc.runThrows = RommException('unauthorized', statusCode: 401);

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.unavailable);
    });

    test('RomM\'s own refusal statuses stay refusals', () async {
      for (final status in const [400, 404, 405, 422]) {
        svc
          ..tasks = null
          ..ran.clear()
          ..runThrows = RommException('no', statusCode: status);

        final request = await provider.requestLibraryScan();

        expect(
          request.outcome,
          RommScanRequestOutcome.refused,
          reason: '$status is RomM declining to run the task',
        );
      }
    });

    test('a login without tasks.run asks nothing at all', () async {
      svc.scope = RommScopeState.denied;
      svc.tasks = const [RommServerTask(name: 'scan_library', manualRun: true)];

      final request = await provider.requestLibraryScan();

      expect(request.outcome, RommScanRequestOutcome.notGranted);
      expect(svc.ran, isEmpty);
    });
  });

  group('RommProvider.serverTaskRunnable', () {
    test(
      'is false for a task the registry refuses, null when unread',
      () async {
        final svc = _FakeRommService()
          ..tasks = const [
            RommServerTask(name: 'scan_library', manualRun: false),
            RommServerTask(name: 'cleanup_missing_roms', manualRun: true),
          ];
        final provider = _FakeProvider(svc);

        expect(await provider.serverTaskRunnable('scan_library'), isFalse);
        expect(
          await provider.serverTaskRunnable('cleanup_missing_roms'),
          isTrue,
        );
        expect(
          await provider.serverTaskRunnable('made_up'),
          isFalse,
          reason: 'a name the registry does not list will not run either',
        );

        final unknown = _FakeProvider(_FakeRommService()..tasks = null);
        expect(await unknown.serverTaskRunnable('scan_library'), isNull);
      },
    );
  });

  group('reading GET /api/tasks/status', () {
    RommScanTaskStatus? parse(String body) =>
        RommScanTaskStatus.newestScanFrom(jsonDecode(body));

    test('a running scan is determinate when the server gives a total', () {
      final status = parse('''
      {"running": [
        {"id": "a", "task_type": "scan", "status": "running",
         "meta": {"scan_stats": {"total_roms": 200, "scanned_roms": 50,
                                  "new_roms": 3, "identified_roms": 1}}}
      ]}
      ''');
      expect(status!.state, RommScanState.running);
      expect(status.fraction, 0.25);
      expect(status.scannedRoms, 50);
      expect(status.totalRoms, 200);
    });

    test('a running scan with no total has no fraction to show', () {
      final status = parse('''
      {"running": [{"id": "a", "task_type": "scan", "status": "running"}]}
      ''');
      expect(status!.state, RommScanState.running);
      expect(status.fraction, isNull);
    });

    test('a finished scan that found something reports its counts', () {
      final status = parse('''
      {"finished": [
        {"id": "a", "task_type": "scan", "status": "finished",
         "meta": {"scan_stats": {"total_roms": 10, "scanned_roms": 10,
                                  "new_roms": 4, "identified_roms": 2}}}
      ]}
      ''');
      expect(status!.state, RommScanState.doneWithResults);
      expect(status.newRoms, 4);
      expect(status.identifiedRoms, 2);
    });

    test('a finished scan that found nothing is its own state', () {
      final status = parse('''
      {"finished": [
        {"id": "a", "task_type": "scan", "status": "finished",
         "meta": {"scan_stats": {"total_roms": 10, "scanned_roms": 10,
                                  "new_roms": 0, "identified_roms": 0}}}
      ]}
      ''');
      expect(status!.state, RommScanState.doneWithNothing);
    });

    test('a failed scan is failed even with counts on it', () {
      final status = parse('''
      {"failed": [
        {"id": "a", "task_type": "scan", "status": "failed",
         "meta": {"scan_stats": {"new_roms": 2, "identified_roms": 1}}}
      ]}
      ''');
      expect(status!.state, RommScanState.failed);
    });

    test('the queue name carries the state when the entry omits it', () {
      final status = parse('''
      {"failed": [{"id": "a", "task_type": "scan"}]}
      ''');
      expect(status!.state, RommScanState.failed);
    });

    test('a running scan wins over a finished one', () {
      final status = parse('''
      {"finished": [{"id": "old", "task_type": "scan", "status": "finished",
                     "ended_at": "2026-09-01T10:00:00Z",
                     "meta": {"scan_stats": {"new_roms": 9}}}],
       "running": [{"id": "now", "task_type": "scan", "status": "running"}]}
      ''');
      expect(status!.id, 'now');
      expect(status.state, RommScanState.running);
    });

    test('the newest finished scan wins over an older one', () {
      final status = parse('''
      {"finished": [
        {"id": "old", "task_type": "scan", "status": "finished",
         "ended_at": "2026-09-01T10:00:00Z"},
        {"id": "new", "task_type": "scan", "status": "finished",
         "ended_at": "2026-09-05T10:00:00Z",
         "meta": {"scan_stats": {"new_roms": 1}}}
      ]}
      ''');
      expect(status!.id, 'new');
      expect(status.state, RommScanState.doneWithResults);
    });

    test('an unrelated top-level total is not a ROM count', () {
      // `total` at the top of an entry can be anything — a queue length, a
      // page size. Read as scan stats it would draw a progress bar out of it.
      final status = parse('''
      {"running": [{"id": "a", "task_type": "scan", "status": "running",
                    "total": 9000}]}
      ''');
      expect(status!.totalRoms, 0);
      expect(status.fraction, isNull, reason: 'no total means no bar (#232)');
    });

    test('stats the server put at the top level are still read', () {
      final status = parse('''
      {"finished": [{"id": "a", "task_type": "scan", "status": "finished",
                     "total_roms": 10, "scanned_roms": 10, "new_roms": 2}]}
      ''');
      expect(status!.totalRoms, 10);
      expect(status.newRoms, 2);
      expect(status.state, RommScanState.doneWithResults);
    });

    test('a body with no scan in it reports none', () {
      expect(
        parse('{"finished": [{"id": "a", "task_type": "cleanup"}]}'),
        isNull,
      );
      expect(parse('{}'), isNull);
    });
  });

  // ── Answered-with-none is not could-not-ask ──────────────────────────────
  // The service used to answer null for six different things: the scope gate,
  // a 403, any non-2xx, a timeout, a socket error, and a 200 naming no scan.
  // The watcher read every one of them as "no scan is running on the server",
  // which is a claim the server never made — and a RomM too old to have this
  // route 404s, so it made that claim permanently and confidently.
  // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
  group('GET /api/tasks/status answers three ways', () {
    void serve(http.Response Function() status) {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/token') {
            return http.Response(
              '{"access_token": "tok", "expires": 3600}',
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          if (request.url.path == '/api/tasks/status') return status();
          return http.Response('not found', 404);
        }),
      );
    }

    RommService configured() => RommService()
      ..configure(
        serverUrl: 'https://romm.local',
        username: 'jon',
        password: 's3cret',
      );

    tearDown(() => RommService.debugUseHttpClient(null));

    test('a scan the server named comes back answered', () async {
      serve(
        () => http.Response(
          '{"running": [{"id": "a", "task_type": "scan", '
          '"status": "running"}]}',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );

      final poll = await configured().getScanTaskStatus();

      expect(poll.answered, isTrue);
      expect(poll.status?.id, 'a');
    });

    test('a 200 naming no scan is the answer "there is none"', () async {
      serve(
        () => http.Response(
          '{}',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );

      final poll = await configured().getScanTaskStatus();

      expect(poll.answered, isTrue, reason: 'the server did answer');
      expect(poll.status, isNull);
    });

    test(
      'a status the server could not answer with is not an answer',
      () async {
        for (final code in const [404, 429, 500, 502, 503]) {
          serve(() => http.Response('nope', code));

          final poll = await configured().getScanTaskStatus();

          expect(
            poll.answered,
            isFalse,
            reason: '$code must not read as "no scan is running"',
          );
          expect(poll.status, isNull);
        }
      },
    );

    test('a request that threw is not an answer either', () async {
      RommService.debugUseHttpClient(
        MockClient((request) async {
          if (request.url.path == '/api/token') {
            return http.Response(
              '{"access_token": "tok", "expires": 3600}',
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          throw const SocketException('connection reset by peer');
        }),
      );

      final poll = await configured().getScanTaskStatus();

      expect(poll.answered, isFalse);
    });
  });
}
