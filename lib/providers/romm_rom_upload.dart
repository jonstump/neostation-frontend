import 'package:flutter/foundation.dart';

import '../models/game_model.dart';
import '../services/logger_service.dart';
import '../services/retroachievements_hash_service.dart';
import '../services/romm/rom_upload_source.dart';
import '../services/romm_service.dart';
import '../utils/rom_tree.dart';

/// One local file a batch will try to send to RomM.
///
/// [fileName] is the on-disk name with its extension — what RomM stores the
/// upload under and what SPEC-0001's name-based link pass will match it by
/// once the server has indexed it. Built by [uploadFileNameFor] from the ROM
/// path, because a `GameModel.romname` has already lost its extension.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
@immutable
class RommUploadCandidate {
  final String fileName;
  final String romPath;
  final String systemFolder;

  const RommUploadCandidate({
    required this.fileName,
    required this.romPath,
    required this.systemFolder,
  });
}

/// The upload name for [romPath]: its last path segment, with a SAF
/// `content://` document id decoded first so `Game.zip` comes out of
/// `primary%3Aemu%2Froms%2Fnes%2FGame.zip`.
String uploadFileNameFor(String romPath) {
  final normalized = normalizeRomPath(romPath);
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

/// Whether [romPath] names something the session can send as one ROM: not a
/// playlist and not a disc image or container. The source's own refusals
/// (directory, missing, empty) need I/O and are left to it.
bool isSingleFileRomPath(String romPath) =>
    !RomUploadSource.isPlaylist(romPath) &&
    !RetroAchievementsHashService.isDiscContainer(romPath);

/// Why the game context menu does or does not offer "Upload to RomM".
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
enum RommUploadGate {
  /// Offer the row.
  offered,

  /// The server or this login cannot take uploads right now, or RomM is not
  /// connected: the provider's gate is closed.
  serverGateClosed,

  /// A remote entry, or a local row without a path: nothing to send.
  notLocal,

  /// The game is already linked to a RomM ROM.
  linked,

  /// A multi-file game or a disc image, which the session does not take.
  notSingleFile,
}

/// The gate for one game. Pure: the caller supplies whether the game is
/// [linked] (from the ROM map) and whether the provider's server-side gate
/// is [serverAllows] (`RommProvider.canUploadRoms`).
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
RommUploadGate rommUploadGateFor(
  GameModel game, {
  required bool linked,
  required bool serverAllows,
}) {
  if (!serverAllows) return RommUploadGate.serverGateClosed;
  final path = game.romPath;
  if (game.isRemote || path == null || path.isEmpty) {
    return RommUploadGate.notLocal;
  }
  if (linked) return RommUploadGate.linked;
  if (!isSingleFileRomPath(path)) return RommUploadGate.notSingleFile;
  return RommUploadGate.offered;
}

/// Opens one candidate as an upload source, or throws
/// [RomUploadRefusedException]. `RomUploadSource.open` in the app.
typedef RommUploadSourceOpener =
    Future<RomUploadSource> Function(String romPath, {String? systemFolder});

/// Sends one source through the chunked session. `RommService.uploadRom` in
/// the app: true when the server confirmed, false when gated, throws
/// [RommException] otherwise.
typedef RommUploadSender =
    Future<bool> Function(
      RomUploadSource source, {
      required int platformId,
      required String fileName,
      void Function(int sent, int total)? onProgress,
      bool Function()? shouldCancel,
    });

/// Requests the server's `scan_library` task and resolves to its id, or null
/// when the call was gated. `RommProvider.runServerTask` in the app.
typedef RommUploadScanRequester = Future<String?> Function();

/// Last chance to call the batch off once the files have been opened and
/// their total size is known. Returning false ends the batch before anything
/// is sent.
typedef RommUploadConfirm = Future<bool> Function(int count, int totalBytes);

/// Where the batch is: which file, and how far into it.
@immutable
class RommUploadProgress {
  /// Zero-based position of the file in the batch.
  final int index;

  /// Files the batch set out to send (after refusals were dropped).
  final int count;
  final String fileName;
  final int sentBytes;
  final int totalBytes;

  const RommUploadProgress({
    required this.index,
    required this.count,
    required this.fileName,
    required this.sentBytes,
    required this.totalBytes,
  });

  /// The share of this file already sent, for a progress bar.
  double get fraction => totalBytes <= 0 ? 0 : sentBytes / totalBytes;
}

typedef RommUploadProgressCallback = void Function(RommUploadProgress progress);

/// Why a file was left out of the batch. Not a failure: the file is fine, it
/// is just not something the session takes, or the server has it already.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
enum RommUploadSkipReason {
  multiFile,
  discContainer,
  missing,
  empty,
  unsendableName,

  /// The server refused `start` or `complete` with "already exists". Listed
  /// distinctly from the other skips: nothing about the file is wrong, and
  /// the link pass will pick the server's copy up.
  alreadyExists,
}

/// Why a file that was sent, or was about to be, did not land.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Error Handling Standards"
enum RommUploadFailure {
  scopeDenied,
  cancelled,
  busy,

  /// The service reported the call gated (server too old, or the scope
  /// settled as denied mid-batch).
  gated,
  other,
}

/// What became of one candidate.
@immutable
class RommUploadFileOutcome {
  final String fileName;
  final RommUploadSkipReason? skipped;
  final RommUploadFailure? failed;

  /// The service's message for a failure, for the log and the summary.
  final String? detail;

  const RommUploadFileOutcome.uploaded(this.fileName)
    : skipped = null,
      failed = null,
      detail = null;

  const RommUploadFileOutcome.skip(this.fileName, RommUploadSkipReason reason)
    : skipped = reason,
      failed = null,
      detail = null;

  const RommUploadFileOutcome.fail(
    this.fileName,
    RommUploadFailure cause, {
    this.detail,
  }) : skipped = null,
       failed = cause;

  bool get uploaded => skipped == null && failed == null;
}

/// Whether the server was asked to scan after the batch.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
enum RommUploadScanState {
  /// Nothing was uploaded, so there was nothing to scan for.
  none,

  /// `scan_library` was queued.
  requested,

  /// The files are on the server but no scan was queued: this login lacks
  /// `tasks.run`, or the server was already scanning, or the request failed.
  /// Honest rather than "failed": the files are there and the link pass
  /// links them once the server indexes them.
  pending,
}

/// How the batch ended.
enum RommUploadEnd {
  /// Every candidate was tried.
  completed,

  /// The user cancelled; the file in flight (if any) was cancelled on the
  /// server and the rest were not tried.
  cancelled,

  /// The connection dropped between files; the rest were not tried and are
  /// not listed as failed.
  disconnected,

  /// The confirmation was declined; nothing was sent.
  declined,

  /// The provider's gate was closed when the action was asked for.
  notOffered,

  /// The system resolves to no RomM platform, or to more than one.
  noPlatform,

  /// No unlinked single-file game to send, or the one game asked for is
  /// already linked.
  nothingToUpload,
}

/// What a batch did: every file's outcome by list, the scan state and how
/// the batch ended.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
class RommUploadSummary {
  final List<RommUploadFileOutcome> uploaded;
  final List<RommUploadFileOutcome> skipped;
  final List<RommUploadFileOutcome> failed;
  final RommUploadScanState scan;
  final RommUploadEnd end;

  const RommUploadSummary({
    this.uploaded = const [],
    this.skipped = const [],
    this.failed = const [],
    this.scan = RommUploadScanState.none,
    required this.end,
  });

  /// A batch that never started, ended by [end].
  const RommUploadSummary.ended(this.end)
    : uploaded = const [],
      skipped = const [],
      failed = const [],
      scan = RommUploadScanState.none;

  /// True when anything reached the server.
  bool get wroteSomething => uploaded.isNotEmpty;

  /// True when nothing was even attempted: the early ends, and a declined
  /// confirmation.
  bool get neverStarted => switch (end) {
    RommUploadEnd.completed ||
    RommUploadEnd.cancelled ||
    RommUploadEnd.disconnected => false,
    RommUploadEnd.declined ||
    RommUploadEnd.notOffered ||
    RommUploadEnd.noPlatform ||
    RommUploadEnd.nothingToUpload => true,
  };
}

/// Thrown by [RommRomUpload.run] when a batch is already running.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Concurrency Safety"
class RommUploadBusyException implements Exception {
  final String runningFileName;
  RommUploadBusyException(this.runningFileName);

  @override
  String toString() =>
      'RommUploadBusyException: an upload batch is running (file=$runningFileName)';
}

/// The upload batch: opens every candidate, confirms, sends them one at a
/// time, then asks for one library scan.
///
/// Server and disk access come in as callbacks so the sequence — refusals
/// collected as skips, `alreadyExists` listed apart, one scan per batch and
/// only when the caller can request one, the stop on disconnect, the cancel
/// that ends the batch after the file in flight — is testable without a
/// server or a file. `RommProvider` binds the real ones.
///
/// One batch at a time: [run] throws [RommUploadBusyException] while another
/// is going, matching the service's own single-session guard. Progress is a
/// [ChangeNotifier] so a settings row still on screen can show the file in
/// flight, whichever surface started the batch.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces",
// REQ "Scan And Link After Upload", REQ "Concurrency Safety"
class RommRomUpload extends ChangeNotifier {
  static final _defaultLog = LoggerService.instance;

  /// The task the post-batch scan queues.
  static const String scanTaskName = 'scan_library';

  final LoggerService _log;

  bool _running = false;
  bool _cancelRequested = false;
  int _done = 0;
  int _total = 0;
  String? _currentFileName;

  RommRomUpload({LoggerService? logger}) : _log = logger ?? _defaultLog;

  /// True while [run] is in progress.
  bool get isRunning => _running;

  /// True once [cancel] was called on the running batch.
  bool get cancelRequested => _cancelRequested;

  /// Files finished (uploaded, skipped or failed) so far in the running batch.
  int get done => _done;

  /// Files the running batch set out to send.
  int get total => _total;

  /// The file in flight, or null between batches.
  String? get currentFileName => _currentFileName;

  /// Asks the running batch to stop. The session client sees it before the
  /// next chunk and cancels the file in flight on the server; no further
  /// file starts.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Concurrency Safety"
  void cancel() {
    if (!_running || _cancelRequested) return;
    _cancelRequested = true;
    _log.i(
      'RomM upload batch cancel requested: file=$_currentFileName '
      'done=$_done total=$_total',
    );
    notifyListeners();
  }

  /// Runs one batch of [candidates] into [platformId] and reports what it did.
  ///
  /// Every candidate is opened first — a refusal is a skip with its reason,
  /// a name the header cannot carry likewise — so [confirm] sees the real
  /// count and byte total. Files are then sent in order through [upload];
  /// [shouldStop] (the disconnect check) is read before every file and is
  /// folded into the session's own cancel poll. After the last file, when at
  /// least one landed, [requestScan] is called once; a null [requestScan]
  /// means the caller cannot ask (no `tasks.run`) and the scan is reported
  /// as pending. A scan the server refuses is pending too, never a failure.
  ///
  /// Never throws for a per-file problem: each is logged once and listed.
  /// Throws [RommUploadBusyException] before touching anything when a batch
  /// is already running.
  // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces",
  // REQ "Scan And Link After Upload", REQ "Error Handling Standards", REQ "Concurrency Safety"
  Future<RommUploadSummary> run({
    required List<RommUploadCandidate> candidates,
    required int platformId,
    required RommUploadSourceOpener open,
    required RommUploadSender upload,
    RommUploadScanRequester? requestScan,
    RommUploadConfirm? confirm,
    bool Function()? shouldStop,
    RommUploadProgressCallback? onProgress,
  }) async {
    if (_running) {
      throw RommUploadBusyException(_currentFileName ?? '');
    }
    // Claimed before the first await so two starts in one event-loop turn
    // cannot both pass the check above.
    _running = true;
    _cancelRequested = false;
    _done = 0;
    _total = 0;
    _currentFileName = null;
    notifyListeners();

    final started = DateTime.now();
    final uploaded = <RommUploadFileOutcome>[];
    final skipped = <RommUploadFileOutcome>[];
    final failed = <RommUploadFileOutcome>[];
    var end = RommUploadEnd.completed;
    var scan = RommUploadScanState.none;
    bool stopRequested() => shouldStop?.call() ?? false;

    try {
      // Open everything first: the confirmation quotes what will actually
      // be sent, and a refusal costs no more than a directory probe.
      // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Source"
      final sources = <(RommUploadCandidate, RomUploadSource)>[];
      var totalBytes = 0;
      for (final candidate in candidates) {
        if (!RomUploadSource.isSendableName(candidate.fileName)) {
          skipped.add(
            RommUploadFileOutcome.skip(
              candidate.fileName,
              RommUploadSkipReason.unsendableName,
            ),
          );
          _log.i(
            'RomM upload skipped: file=${candidate.fileName} '
            'system=${candidate.systemFolder} reason=unsendable_name',
          );
          continue;
        }
        try {
          final source = await open(
            candidate.romPath,
            systemFolder: candidate.systemFolder,
          );
          sources.add((candidate, source));
          totalBytes += source.size;
        } on RomUploadRefusedException catch (e) {
          skipped.add(
            RommUploadFileOutcome.skip(candidate.fileName, _skipFor(e.reason)),
          );
          _log.i(
            'RomM upload skipped: file=${candidate.fileName} '
            'system=${candidate.systemFolder} reason=${e.reason.name}',
          );
        } catch (e) {
          failed.add(
            RommUploadFileOutcome.fail(
              candidate.fileName,
              RommUploadFailure.other,
              detail: '$e',
            ),
          );
          _log.w(
            'RomM upload failed: file=${candidate.fileName} '
            'system=${candidate.systemFolder} stage=open error=$e',
          );
        }
      }

      if (sources.isNotEmpty && confirm != null) {
        final go = await confirm(sources.length, totalBytes);
        if (!go) {
          _log.i(
            'RomM upload batch declined: files=${sources.length} '
            'bytes=$totalBytes',
          );
          return RommUploadSummary(
            skipped: skipped,
            failed: failed,
            end: RommUploadEnd.declined,
          );
        }
      }

      _total = sources.length;
      notifyListeners();

      for (var i = 0; i < sources.length; i++) {
        final (candidate, source) = sources[i];
        // Between files: a dropped connection ends the batch with the rest
        // untried and unreported; a cancel likewise.
        // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Concurrency Safety"
        if (stopRequested()) {
          end = RommUploadEnd.disconnected;
          break;
        }
        if (_cancelRequested) {
          end = RommUploadEnd.cancelled;
          break;
        }
        _currentFileName = candidate.fileName;
        notifyListeners();
        void report(int sent, int total) => onProgress?.call(
          RommUploadProgress(
            index: i,
            count: sources.length,
            fileName: candidate.fileName,
            sentBytes: sent,
            totalBytes: total,
          ),
        );
        report(0, source.size);

        var stopAfter = false;
        try {
          final sent = await upload(
            source,
            platformId: platformId,
            fileName: candidate.fileName,
            onProgress: report,
            shouldCancel: () => _cancelRequested || stopRequested(),
          );
          if (sent) {
            uploaded.add(RommUploadFileOutcome.uploaded(candidate.fileName));
          } else {
            // The service logged the gate; nothing else in the batch will
            // fare better against it.
            failed.add(
              RommUploadFileOutcome.fail(
                candidate.fileName,
                RommUploadFailure.gated,
              ),
            );
            stopAfter = true;
          }
        } on RomUploadRefusedException catch (e) {
          skipped.add(
            RommUploadFileOutcome.skip(candidate.fileName, _skipFor(e.reason)),
          );
          _log.i(
            'RomM upload skipped: file=${candidate.fileName} '
            'system=${candidate.systemFolder} reason=${e.reason.name}',
          );
        } on RommException catch (e) {
          switch (e.kind) {
            case RommErrorKind.alreadyExists:
              skipped.add(
                RommUploadFileOutcome.skip(
                  candidate.fileName,
                  RommUploadSkipReason.alreadyExists,
                ),
              );
              _log.i(
                'RomM upload skipped: file=${candidate.fileName} '
                'system=${candidate.systemFolder} reason=already_exists',
              );
            case RommErrorKind.uploadCancelled:
              failed.add(
                RommUploadFileOutcome.fail(
                  candidate.fileName,
                  RommUploadFailure.cancelled,
                  detail: e.message,
                ),
              );
              end = stopRequested()
                  ? RommUploadEnd.disconnected
                  : RommUploadEnd.cancelled;
              stopAfter = true;
            case RommErrorKind.scopeDenied:
              failed.add(
                RommUploadFileOutcome.fail(
                  candidate.fileName,
                  RommUploadFailure.scopeDenied,
                  detail: e.message,
                ),
              );
              _log.w(
                'RomM upload failed: file=${candidate.fileName} '
                'system=${candidate.systemFolder} kind=scope_denied '
                'status=${e.statusCode}',
              );
              stopAfter = true;
            case RommErrorKind.uploadBusy:
              failed.add(
                RommUploadFileOutcome.fail(
                  candidate.fileName,
                  RommUploadFailure.busy,
                  detail: e.message,
                ),
              );
              _log.w(
                'RomM upload failed: file=${candidate.fileName} '
                'system=${candidate.systemFolder} kind=upload_busy',
              );
              stopAfter = true;
            default:
              // The service already logged the chunk and status; this line
              // is the batch's own record of the file.
              failed.add(
                RommUploadFileOutcome.fail(
                  candidate.fileName,
                  RommUploadFailure.other,
                  detail: e.message,
                ),
              );
              _log.w(
                'RomM upload failed: file=${candidate.fileName} '
                'system=${candidate.systemFolder} kind=${e.kind.name} '
                'status=${e.statusCode}',
              );
          }
        } catch (e) {
          failed.add(
            RommUploadFileOutcome.fail(
              candidate.fileName,
              RommUploadFailure.other,
              detail: '$e',
            ),
          );
          _log.w(
            'RomM upload failed: file=${candidate.fileName} '
            'system=${candidate.systemFolder} error=$e',
          );
        }
        _done = i + 1;
        notifyListeners();
        if (stopAfter) break;
      }

      // One scan per batch, only when something landed and only when this
      // login can ask. Every way the request does not go through — no scope,
      // the server already scanning, a failure — is "pending": the files are
      // on the server either way, and the link pass picks them up once they
      // are indexed.
      // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Scan And Link After Upload"
      if (uploaded.isNotEmpty) {
        scan = await _requestScan(requestScan);
      }

      return RommUploadSummary(
        uploaded: uploaded,
        skipped: skipped,
        failed: failed,
        scan: scan,
        end: end,
      );
    } finally {
      _log.i(
        'RomM upload batch ${end.name}: platform=$platformId '
        'candidates=${candidates.length} uploaded=${uploaded.length} '
        'skipped=${skipped.length} failed=${failed.length} '
        'scan=${scan.name} '
        'elapsed_ms=${DateTime.now().difference(started).inMilliseconds}',
      );
      _running = false;
      _currentFileName = null;
      notifyListeners();
    }
  }

  Future<RommUploadScanState> _requestScan(
    RommUploadScanRequester? requestScan,
  ) async {
    if (requestScan == null) {
      _log.i('RomM upload scan pending: reason=tasks_run_not_granted');
      return RommUploadScanState.pending;
    }
    try {
      final id = await requestScan();
      if (id == null) {
        _log.i('RomM upload scan pending: reason=gated');
        return RommUploadScanState.pending;
      }
      _log.i('RomM upload scan requested: task=$scanTaskName id=$id');
      return RommUploadScanState.requested;
    } on RommException catch (e) {
      if (e.kind == RommErrorKind.taskBusy) {
        _log.i('RomM upload scan pending: reason=already_running');
      } else {
        _log.w(
          'RomM upload scan pending: reason=request_failed '
          'kind=${e.kind.name} status=${e.statusCode}',
        );
      }
      return RommUploadScanState.pending;
    } catch (e) {
      _log.w('RomM upload scan pending: reason=request_failed error=$e');
      return RommUploadScanState.pending;
    }
  }

  static RommUploadSkipReason _skipFor(RomUploadRefusal refusal) =>
      switch (refusal) {
        RomUploadRefusal.multiFile => RommUploadSkipReason.multiFile,
        RomUploadRefusal.discContainer => RommUploadSkipReason.discContainer,
        RomUploadRefusal.missing => RommUploadSkipReason.missing,
        RomUploadRefusal.empty => RommUploadSkipReason.empty,
        RomUploadRefusal.unsendableName => RommUploadSkipReason.unsendableName,
      };
}
