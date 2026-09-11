import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_server_task.dart';
import 'package:neostation/providers/romm_rom_upload.dart';
import 'package:neostation/services/romm/rom_upload_source.dart';
import 'package:neostation/services/romm_service.dart';

/// The upload batch engine on its own: refusals collected as skips with
/// their reasons, `alreadyExists` listed apart, files sent one at a time,
/// exactly one scan per batch and only when the caller can ask, a refused
/// scan reported as pending, the confirmation seeing the real count and
/// size, a disconnect ending the batch with the rest unreported, and a
/// cancel ending it after the file in flight.
///
/// [RommRomUpload.run] takes the source opener, the session client and the
/// scan request as callbacks precisely so this runs without a server or a
/// file: the fakes below stand in for `RomUploadSource.open`,
/// `RommService.uploadRom` and `RommProvider.runServerTask`.
///
/// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload
/// Surfaces", REQ "Scan And Link After Upload", REQ "Concurrency Safety",
/// REQ "Error Handling Standards"

RommUploadCandidate _candidate(String name, {String folder = 'snes'}) =>
    RommUploadCandidate(
      fileName: name,
      romPath: '/roms/$folder/$name',
      systemFolder: folder,
    );

/// Files by path: a size, or a directory, or nothing (missing).
class _Disk {
  final Map<String, int> sizes;
  final Set<String> directories;
  _Disk({this.sizes = const {}, this.directories = const {}});

  RomUploadReaders get readers => RomUploadReaders(
    sizeOf: (path) async {
      final size = sizes[path];
      if (size == null) throw FileSystemException('missing', path);
      return size;
    },
    readRange: (path, offset, length) async => Uint8List(length),
    isDirectory: (path) async => directories.contains(path),
  );

  RommUploadSourceOpener get open =>
      (romPath, {systemFolder}) => RomUploadSource.open(
        romPath,
        systemFolder: systemFolder,
        readers: readers,
      );
}

/// A session client that records what it was asked to send and answers
/// per file name: true, false (gated), or a thrown exception.
class _Server {
  final List<String> sent = [];
  final Map<String, Object> answers;

  /// Set by a test to make the fake poll `shouldCancel` mid-file.
  bool pollCancelMidFile = false;

  _Server({this.answers = const {}});

  RommUploadSender get upload =>
      (
        source, {
        required platformId,
        required fileName,
        onProgress,
        shouldCancel,
      }) async {
        sent.add(fileName);
        onProgress?.call(0, source.size);
        // The real client polls before every chunk: a cancel that lands
        // while this file is going up ends this file too.
        if (pollCancelMidFile && (shouldCancel?.call() ?? false)) {
          throw RommException(
            'cancelled file=$fileName',
            kind: RommErrorKind.uploadCancelled,
          );
        }
        // Let the batch's own cancel land between files, like a real
        // upload that takes a while.
        await Future<void>.delayed(Duration.zero);
        final answer = answers[fileName];
        if (answer is Exception) throw answer;
        if (answer is bool) return answer;
        onProgress?.call(source.size, source.size);
        return true;
      };
}

void main() {
  late RommRomUpload batch;

  setUp(() {
    batch = RommRomUpload();
  });

  group('refusals and the confirmation', () {
    // Governing: SPEC-0014 REQ "Upload Surfaces" — scenario "Bulk with a skip"
    test(
      'a multi-file game is skipped with its reason and the rest upload',
      () async {
        final disk = _Disk(
          sizes: {
            '/roms/snes/a.sfc': 100,
            '/roms/snes/b.sfc': 200,
            '/roms/snes/c.m3u': 10,
          },
        );
        final server = _Server();

        final summary = await batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('c.m3u'),
            _candidate('b.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
          requestScan: () async => const RommScanRequest(
            RommScanRequestOutcome.queued,
            taskName: 'scan_library',
            taskId: 'task-1',
          ),
        );

        expect(server.sent, ['a.sfc', 'b.sfc']);
        expect(summary.uploaded.map((o) => o.fileName), ['a.sfc', 'b.sfc']);
        expect(summary.skipped.single.fileName, 'c.m3u');
        expect(summary.skipped.single.skipped, RommUploadSkipReason.multiFile);
        expect(summary.failed, isEmpty);
        expect(summary.end, RommUploadEnd.completed);
      },
    );

    // The metadata push that follows the link pass needs each uploaded
    // game's system folder, and [RommUploadFileOutcome] carries only the
    // file name — so the summary carries the candidates too. Issue #237.
    // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
    test(
      'the summary names the candidates behind the uploaded files',
      () async {
        final disk = _Disk(
          sizes: {
            '/roms/snes/a.sfc': 100,
            '/roms/gb/b.gb': 200,
            '/roms/snes/c.m3u': 10,
          },
        );

        final summary = await batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('c.m3u'),
            _candidate('b.gb', folder: 'gb'),
          ],
          platformId: 7,
          open: disk.open,
          upload: _Server().upload,
          requestScan: () async => const RommScanRequest(
            RommScanRequestOutcome.queued,
            taskName: 'scan_library',
            taskId: 'task-1',
          ),
        );

        expect(summary.uploaded.map((o) => o.fileName), ['a.sfc', 'b.gb']);
        expect(
          summary.uploadedCandidates.map(
            (c) => '${c.systemFolder}/${c.fileName}',
          ),
          ['snes/a.sfc', 'gb/b.gb'],
          reason: 'the skipped playlist is not a target of the push',
        );
      },
    );

    test(
      'every refusal reason is kept, and an unsendable name is one',
      () async {
        final disk = _Disk(
          sizes: {'/roms/snes/empty.sfc': 0, '/roms/snes/Pokémon.sfc': 5},
          directories: {'/roms/snes/folder'},
        );
        final server = _Server();

        final summary = await batch.run(
          candidates: [
            _candidate('folder'),
            _candidate('disc.chd'),
            _candidate('gone.sfc'),
            _candidate('empty.sfc'),
            _candidate('Pokémon.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
        );

        expect(server.sent, isEmpty);
        expect(
          {for (final o in summary.skipped) o.fileName: o.skipped},
          {
            'folder': RommUploadSkipReason.multiFile,
            'disc.chd': RommUploadSkipReason.discContainer,
            'gone.sfc': RommUploadSkipReason.missing,
            'empty.sfc': RommUploadSkipReason.empty,
            'Pokémon.sfc': RommUploadSkipReason.unsendableName,
          },
        );
        expect(
          summary.scan,
          RommUploadScanState.none,
          reason: 'nothing landed',
        );
      },
    );

    test(
      'the confirmation sees the count and bytes of what will be sent',
      () async {
        final disk = _Disk(
          sizes: {'/roms/snes/a.sfc': 100, '/roms/snes/b.sfc': 250},
        );
        final server = _Server();
        final asked = <(int, int)>[];

        final summary = await batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('x.m3u'),
            _candidate('b.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
          confirm: (count, bytes) async {
            asked.add((count, bytes));
            return false;
          },
        );

        expect(asked, [(2, 350)]);
        expect(server.sent, isEmpty);
        expect(summary.end, RommUploadEnd.declined);
        expect(summary.neverStarted, isTrue);
        expect(summary.skipped.single.fileName, 'x.m3u');
      },
    );
  });

  group('outcomes', () {
    test(
      'already exists is listed as a skip apart from the failures',
      () async {
        final disk = _Disk(
          sizes: {
            '/roms/snes/a.sfc': 1,
            '/roms/snes/dup.sfc': 1,
            '/roms/snes/bad.sfc': 1,
          },
        );
        final server = _Server(
          answers: {
            'dup.sfc': RommException(
              'File dup.sfc already exists',
              statusCode: 400,
              kind: RommErrorKind.alreadyExists,
            ),
            'bad.sfc': RommException(
              'chunk 2 failed',
              statusCode: 500,
              kind: RommErrorKind.uploadFailed,
            ),
          },
        );

        final summary = await batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('dup.sfc'),
            _candidate('bad.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
          requestScan: () async => const RommScanRequest(
            RommScanRequestOutcome.queued,
            taskName: 'scan_library',
            taskId: 'task-1',
          ),
        );

        expect(server.sent, [
          'a.sfc',
          'dup.sfc',
          'bad.sfc',
        ], reason: 'sequential, nothing stops the batch');
        expect(summary.uploaded.single.fileName, 'a.sfc');
        expect(summary.skipped.single.fileName, 'dup.sfc');
        expect(
          summary.skipped.single.skipped,
          RommUploadSkipReason.alreadyExists,
        );
        expect(summary.failed.single.fileName, 'bad.sfc');
        expect(summary.failed.single.failed, RommUploadFailure.other);
        expect(summary.failed.single.detail, 'chunk 2 failed');
        expect(summary.end, RommUploadEnd.completed);
      },
    );

    test('a scope denial fails the file and ends the batch', () async {
      final disk = _Disk(sizes: {'/roms/snes/a.sfc': 1, '/roms/snes/b.sfc': 1});
      final server = _Server(
        answers: {
          'a.sfc': RommException(
            'forbidden',
            statusCode: 403,
            kind: RommErrorKind.scopeDenied,
          ),
        },
      );

      final summary = await batch.run(
        candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
        platformId: 7,
        open: disk.open,
        upload: server.upload,
      );

      expect(server.sent, ['a.sfc']);
      expect(summary.failed.single.failed, RommUploadFailure.scopeDenied);
      expect(summary.uploaded, isEmpty);
    });

    test('a gated client (false) fails the file and ends the batch', () async {
      final disk = _Disk(sizes: {'/roms/snes/a.sfc': 1, '/roms/snes/b.sfc': 1});
      final server = _Server(answers: {'a.sfc': false});

      final summary = await batch.run(
        candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
        platformId: 7,
        open: disk.open,
        upload: server.upload,
      );

      expect(server.sent, ['a.sfc']);
      expect(summary.failed.single.failed, RommUploadFailure.gated);
    });
  });

  group('the scan after the batch', () {
    final disk = _Disk(sizes: {'/roms/snes/a.sfc': 1, '/roms/snes/b.sfc': 1});

    // Governing: SPEC-0014 REQ "Scan And Link After Upload" — scenario "Scan
    // allowed"
    test('is requested exactly once, after the last file', () async {
      final server = _Server();
      final order = <String>[];

      final summary = await batch.run(
        candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
        platformId: 7,
        open: disk.open,
        upload:
            (
              source, {
              required platformId,
              required fileName,
              onProgress,
              shouldCancel,
            }) {
              order.add('upload:$fileName');
              return server.upload(
                source,
                platformId: platformId,
                fileName: fileName,
                onProgress: onProgress,
                shouldCancel: shouldCancel,
              );
            },
        requestScan: () async {
          order.add('scan');
          return const RommScanRequest(
            RommScanRequestOutcome.queued,
            taskName: 'scan_library',
            taskId: 'task-9',
          );
        },
      );

      expect(order, ['upload:a.sfc', 'upload:b.sfc', 'scan']);
      expect(summary.scan, RommUploadScanState.requested);
    });

    test('is pending when the caller cannot ask (no tasks.run)', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: null,
      );
      expect(summary.scan, RommUploadScanState.pending);
      expect(summary.end, RommUploadEnd.completed);
    });

    test(
      'is pending, not failed, when the server is already scanning',
      () async {
        var scans = 0;
        final summary = await batch.run(
          candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
          platformId: 7,
          open: disk.open,
          upload: _Server().upload,
          requestScan: () async {
            scans++;
            throw RommException(
              'busy',
              statusCode: 400,
              kind: RommErrorKind.taskBusy,
            );
          },
        );
        expect(scans, 1);
        expect(summary.scan, RommUploadScanState.pending);
        expect(summary.failed, isEmpty);
        expect(summary.uploaded.length, 2);
      },
    );

    test('is pending when the request came back gated', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: () async =>
            const RommScanRequest(RommScanRequestOutcome.notGranted),
      );
      expect(summary.scan, RommUploadScanState.pending);
    });

    // Governing: SPEC-0014 REQ "Scan And Link After Upload" — the refusal
    // split out of pending for issue #236.
    test('is refused when the server will not start a scan', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: () async =>
            const RommScanRequest(RommScanRequestOutcome.refused),
      );
      expect(
        summary.scan,
        RommUploadScanState.refused,
        reason: 'a scan that will never start must not read as pending',
      );
      expect(summary.uploaded.length, 1, reason: 'the file still landed');
    });

    // The same rule as `RommProvider.requestLibraryScan`, at the second site
    // that classifies a thrown status: a proxy's 5xx or a 429 is not RomM
    // declining to scan, and must not send the user off to start one by hand.
    // Governing: ADR-0014, SPEC-0014 REQ "Scan And Link After Upload"
    test('a transient status from the requester stays pending', () async {
      for (final status in const [408, 429, 500, 502, 503, 504]) {
        final summary = await batch.run(
          candidates: [_candidate('a.sfc')],
          platformId: 7,
          open: disk.open,
          upload: _Server().upload,
          requestScan: () async =>
              throw RommException('transient', statusCode: status),
        );
        expect(
          summary.scan,
          RommUploadScanState.pending,
          reason: '$status is a server that was briefly unreachable',
        );
      }
    });

    test('a thrown refusal status is still refused', () async {
      for (final status in const [400, 404, 405, 409, 422]) {
        final summary = await batch.run(
          candidates: [_candidate('a.sfc')],
          platformId: 7,
          open: disk.open,
          upload: _Server().upload,
          requestScan: () async =>
              throw RommException('no', statusCode: status),
        );
        expect(
          summary.scan,
          RommUploadScanState.refused,
          reason: '$status is RomM declining to run the task',
        );
      }
    });

    // The id the watch correlates on: without it a scan slow to appear lets
    // the previous scan's counts be reported as this batch's result.
    // Governing: ADR-0019, SPEC-0018 REQ "Maintenance Tasks"
    test('the queued scan\'s id reaches the summary', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: () async => const RommScanRequest(
          RommScanRequestOutcome.queued,
          taskName: 'scan_library',
          taskId: 'job-77',
        ),
      );
      expect(summary.scan, RommUploadScanState.requested);
      expect(summary.scanTaskId, 'job-77');
    });

    test('a batch that queued no scan carries no id', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: () async =>
            const RommScanRequest(RommScanRequestOutcome.refused),
      );
      expect(summary.scanTaskId, isEmpty);
    });

    test('is pending when the request never reached the server', () async {
      final summary = await batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        requestScan: () async =>
            const RommScanRequest(RommScanRequestOutcome.unavailable),
      );
      expect(summary.scan, RommUploadScanState.pending);
    });

    test('is not requested when nothing landed', () async {
      var scans = 0;
      final summary = await batch.run(
        candidates: [_candidate('dup.sfc')],
        platformId: 7,
        open: _Disk(sizes: {'/roms/snes/dup.sfc': 1}).open,
        upload: _Server(
          answers: {
            'dup.sfc': RommException(
              'exists',
              kind: RommErrorKind.alreadyExists,
            ),
          },
        ).upload,
        requestScan: () async {
          scans++;
          return const RommScanRequest(RommScanRequestOutcome.queued);
        },
      );
      expect(scans, 0);
      expect(summary.scan, RommUploadScanState.none);
    });
  });

  group('stopping', () {
    final disk = _Disk(
      sizes: {
        '/roms/snes/a.sfc': 1,
        '/roms/snes/b.sfc': 1,
        '/roms/snes/c.sfc': 1,
      },
    );

    // Governing: SPEC-0014 REQ "Concurrency Safety" — scenario "Disconnect
    // mid-batch"
    test(
      'a disconnect between files ends the batch with the rest unreported',
      () async {
        final server = _Server();
        var connected = true;

        final summary = await batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('b.sfc'),
            _candidate('c.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload:
              (
                source, {
                required platformId,
                required fileName,
                onProgress,
                shouldCancel,
              }) async {
                final sent = await server.upload(
                  source,
                  platformId: platformId,
                  fileName: fileName,
                  onProgress: onProgress,
                  shouldCancel: shouldCancel,
                );
                if (fileName == 'a.sfc') connected = false;
                return sent;
              },
          shouldStop: () => !connected,
          requestScan: () async =>
              const RommScanRequest(RommScanRequestOutcome.queued),
        );

        expect(server.sent, ['a.sfc']);
        expect(summary.end, RommUploadEnd.disconnected);
        expect(summary.uploaded.single.fileName, 'a.sfc');
        expect(summary.failed, isEmpty, reason: 'b and c were never tried');
        expect(summary.skipped, isEmpty);
      },
    );

    test(
      'cancel from outside ends the batch after the file in flight',
      () async {
        final server = _Server();
        final progress = <String>[];

        final run = batch.run(
          candidates: [
            _candidate('a.sfc'),
            _candidate('b.sfc'),
            _candidate('c.sfc'),
          ],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
          onProgress: (p) =>
              progress.add('${p.fileName}:${p.sentBytes}/${p.totalBytes}'),
          requestScan: () async =>
              const RommScanRequest(RommScanRequestOutcome.queued),
        );
        // Let the first file start, then cancel — the way the notification's
        // Cancel action does — while it is still going.
        while (server.sent.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(batch.isRunning, isTrue);
        expect(batch.currentFileName, 'a.sfc');
        batch.cancel();
        expect(batch.cancelRequested, isTrue);
        final summary = await run;

        expect(server.sent, ['a.sfc'], reason: 'no further file starts');
        expect(summary.uploaded.single.fileName, 'a.sfc');
        expect(summary.end, RommUploadEnd.cancelled);
        expect(
          summary.scan,
          RommUploadScanState.requested,
          reason: 'what landed still gets its scan',
        );
        expect(progress.first, 'a.sfc:0/1');
        expect(batch.isRunning, isFalse);
      },
    );

    test(
      'a cancel the session client sees mid-file lists that file as cancelled',
      () async {
        final server = _Server()..pollCancelMidFile = true;
        batch.cancel(); // before a run: ignored
        expect(batch.cancelRequested, isFalse);

        final run = batch.run(
          candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
          platformId: 7,
          open: disk.open,
          upload:
              (
                source, {
                required platformId,
                required fileName,
                onProgress,
                shouldCancel,
              }) {
                // Cancel lands the moment the first file is asked for.
                batch.cancel();
                return server.upload(
                  source,
                  platformId: platformId,
                  fileName: fileName,
                  onProgress: onProgress,
                  shouldCancel: shouldCancel,
                );
              },
        );
        final summary = await run;

        expect(server.sent, ['a.sfc']);
        expect(summary.failed.single.fileName, 'a.sfc');
        expect(summary.failed.single.failed, RommUploadFailure.cancelled);
        expect(summary.end, RommUploadEnd.cancelled);
        expect(summary.scan, RommUploadScanState.none);
      },
    );

    test('a second batch while one runs is refused, not queued', () async {
      final server = _Server();
      final first = batch.run(
        candidates: [_candidate('a.sfc')],
        platformId: 7,
        open: disk.open,
        upload: server.upload,
      );
      expect(batch.isRunning, isTrue);
      await expectLater(
        batch.run(
          candidates: [_candidate('b.sfc')],
          platformId: 7,
          open: disk.open,
          upload: server.upload,
        ),
        throwsA(isA<RommUploadBusyException>()),
      );
      await first;
      expect(server.sent, ['a.sfc']);
      expect(batch.isRunning, isFalse);
    });
  });

  group('progress', () {
    test('reports the file, its position and its bytes', () async {
      final disk = _Disk(
        sizes: {'/roms/snes/a.sfc': 40, '/roms/snes/b.sfc': 60},
      );
      final seen = <RommUploadProgress>[];

      await batch.run(
        candidates: [_candidate('a.sfc'), _candidate('b.sfc')],
        platformId: 7,
        open: disk.open,
        upload: _Server().upload,
        onProgress: seen.add,
      );

      expect(
        seen.map(
          (p) => '${p.index + 1}/${p.count} ${p.fileName} ${p.sentBytes}',
        ),
        [
          '1/2 a.sfc 0',
          '1/2 a.sfc 0',
          '1/2 a.sfc 40',
          '2/2 b.sfc 0',
          '2/2 b.sfc 0',
          '2/2 b.sfc 60',
        ],
      );
      expect(seen.last.fraction, 1.0);
      expect(batch.done, 2);
      expect(batch.total, 2);
    });
  });

  group('names and single-file rule', () {
    test('the upload name is the last path segment, SAF-decoded', () {
      expect(uploadFileNameFor('/roms/nes/Game (USA).zip'), 'Game (USA).zip');
      expect(uploadFileNameFor(r'C:\roms\nes\Game.nes'), 'Game.nes');
      expect(
        uploadFileNameFor(
          'content://com.android.externalstorage.documents/tree/primary%3Aemu/document/primary%3Aemu%2Froms%2Fnes%2FGame.zip',
        ),
        'Game.zip',
      );
    });

    test('playlists and disc containers are not single files', () {
      expect(isSingleFileRomPath('/roms/psx/game.m3u'), isFalse);
      expect(isSingleFileRomPath('/roms/psx/game.chd'), isFalse);
      expect(isSingleFileRomPath('/roms/psx/game.cue'), isFalse);
      expect(isSingleFileRomPath('/roms/snes/game.sfc'), isTrue);
      expect(isSingleFileRomPath('/roms/nes/game.zip'), isTrue);
    });
  });
}
