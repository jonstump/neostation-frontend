import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Every method name Dart sends on a channel `MainActivity` registers must have
/// a handler on *that* channel.
///
/// `SafDirectoryService.requestDirectoryAccess` shipped invoking
/// `openDirectoryPicker` while the native side has only ever handled
/// `openSafDirectoryPicker`. Nothing called it until the RomM firmware panel,
/// so the mismatch stayed dormant and then crashed with a
/// `MissingPluginException` the first time a user pressed "Choose BIOS folder"
/// on a device.
///
/// A runtime test cannot catch this: every caller is behind `Platform.isAndroid`,
/// so on a host the call never happens and the fake handler records nothing.
/// The analyzer cannot catch it either — the name is a string. So it is checked
/// statically here, for every caller rather than just the one that broke.
///
/// The guard's own failure mode is being a no-op. Discovery that finds nothing
/// passes trivially, so both sides carry canaries: the handler scan and the
/// caller scan must each come back non-empty, the game channel must clear a
/// floor of files and names, and a file that invokes a method on a channel this
/// test cannot attribute is a failure rather than a silent skip.
const _mainActivityPath =
    'android/app/src/main/kotlin/com/neogamelab/neostation/MainActivity.kt';

/// The game channel is the one this guard exists for, so its discovery is held
/// to a floor as well as to "not empty" — a scan that collapses to a couple of
/// files has broken even if it still finds something.
///
/// Both numbers are comfortably below today's counts (11 files, 27 names).
/// Lower them only alongside a real reduction in callers, never to make a
/// suddenly-shrunken scan pass.
const _minGameChannelCallerFiles = 8;
const _minGameChannelInvokedNames = 20;

void main() {
  late final Map<String, Set<String>> handlersByChannel;
  late final Map<String, Set<String>> dartChannelsByFile;

  setUpAll(() {
    handlersByChannel = _handlersByChannel(
      File(_mainActivityPath).readAsStringSync(),
    );
    dartChannelsByFile = _dartChannelsByFile(Directory('lib'));
  });

  test('MainActivity handlers are attributed to the channel that registers '
      'them', () {
    expect(
      handlersByChannel,
      isNotEmpty,
      reason:
          'failed to parse any channel registration out of MainActivity.kt — '
          'the registration syntax probably changed and this guard needs '
          'updating',
    );

    for (final entry in handlersByChannel.entries) {
      expect(
        entry.value,
        isNotEmpty,
        reason:
            'failed to parse any handler out of the ${entry.key} channel '
            'block — the handler syntax probably changed and this guard needs '
            'updating',
      );
    }

    // Scoping matters: the whole-file scan this replaced merged all three
    // channels into one permissive set, so a game-channel call naming a
    // launcher method would have passed here and still thrown on a device.
    final game = handlersByChannel[_gameChannel];
    expect(
      game,
      isNotNull,
      reason:
          'MainActivity.kt no longer registers a handler on $_gameChannel; '
          'this guard is built around that channel',
    );
    for (final foreign in const [
      'setSecondaryDisplayVisible',
      'isDefaultLauncher',
      'openLauncherSettings',
      'openSystemSettings',
    ]) {
      expect(
        game,
        isNot(contains(foreign)),
        reason:
            '$foreign is registered on another channel but leaked into the '
            'game channel handler set, so the scan is not scoped to the '
            'setMethodCallHandler block it thinks it is',
      );
    }
  });

  test('every Dart caller resolves to a channel', () {
    // A file that sends method calls but whose channel cannot be resolved is
    // the exact shape of the silent no-op this guard has to avoid: it would
    // simply drop out of the scan. Fail instead, so whoever moved the channel
    // name teaches the resolver about it.
    final unresolved =
        dartChannelsByFile.entries
            .where((e) => e.value.isEmpty)
            .map((e) => e.key)
            .toList()
          ..sort();

    expect(
      unresolved,
      isEmpty,
      reason:
          'these files invoke platform methods but this test could not work '
          'out which channel they use, so their calls are unchecked. Teach '
          '_dartChannelsByFile how the channel reaches them (a new shared '
          'constant, a new indirection) rather than leaving them silent: '
          '$unresolved',
    );

    final ambiguous =
        dartChannelsByFile.entries
            .where((e) => e.value.length > 1)
            .map((e) => '${e.key} -> ${e.value.toList()..sort()}')
            .toList()
          ..sort();

    expect(
      ambiguous,
      isEmpty,
      reason:
          'these files reference more than one platform channel, so their '
          'invokeMethod names cannot be attributed to one of them. Split the '
          'file or teach this test to resolve per call site: $ambiguous',
    );
  });

  test('the caller scan finds the game channel callers it is meant to '
      'check', () {
    // The canary for discovery itself. Files enter the scan by naming the
    // channel — today as a duplicated literal, which is drift worth cleaning
    // up. _dartChannelsByFile therefore also follows shared constants and
    // `part` files, but if that resolution ever stops working the scan goes
    // empty and every following expectation passes vacuously. So assert it
    // did not.
    final files = _filesOnChannel(dartChannelsByFile, _gameChannel);
    expect(
      files.length,
      greaterThanOrEqualTo(_minGameChannelCallerFiles),
      reason:
          'only ${files.length} file(s) were discovered as $_gameChannel '
          'callers. Either the channel name moved somewhere this test cannot '
          'follow — in which case fix the resolution, not this number — or '
          'callers really were removed: $files',
    );

    final invoked = _invokedNamesOnChannel(dartChannelsByFile, _gameChannel);
    expect(
      invoked.keys.length,
      greaterThanOrEqualTo(_minGameChannelInvokedNames),
      reason:
          'only ${invoked.keys.length} distinct method name(s) were found on '
          '$_gameChannel; the scan has probably stopped matching call sites: '
          '${invoked.keys.toList()..sort()}',
    );

    // The name the guard was written for, in the file it broke in, must be
    // among what the scan sees — a discovery regression that still cleared the
    // floors above would otherwise go unnoticed.
    expect(
      invoked['openSafDirectoryPicker'],
      contains('lib/services/saf_directory_service.dart'),
      reason:
          'the SAF directory picker call is the regression this guard exists '
          'for and the scan no longer sees it',
    );
  });

  test('every invoked channel method has a handler on its own channel', () {
    final missing = <String, List<String>>{};

    for (final channel in handlersByChannel.keys) {
      final handled = handlersByChannel[channel]!;
      _invokedNamesOnChannel(dartChannelsByFile, channel).forEach((
        method,
        files,
      ) {
        if (!handled.contains(method)) {
          missing['$channel#$method'] = files;
        }
      });
    }

    expect(
      missing,
      isEmpty,
      reason:
          'These method names are sent on a channel whose MainActivity.kt '
          'handler block does not answer them, so each is a '
          'MissingPluginException waiting for its first caller on a device: '
          '$missing',
    );
  });
}

const _gameChannel = 'com.neogamelab.neostation/game';

/// Any `com.neogamelab.neostation/...` channel name, wherever it is written.
final _channelNamePattern = RegExp(
  r'com\.neogamelab\.neostation/[A-Za-z0-9_]+',
);

/// Callers look like:  `invokeMethod('name'`  /  `invokeMethod<T>('name'`
final _invokePattern = RegExp(
  r"""invokeMethod(?:<[^>]*>)?\(\s*'([A-Za-z][A-Za-z0-9_]*)'""",
);

// ---------------------------------------------------------------------------
// Kotlin side
// ---------------------------------------------------------------------------

/// Maps each channel name registered in [kotlin] to the method names its own
/// `setMethodCallHandler` block answers.
///
/// Scoped per block on purpose. `MainActivity` registers three channels in one
/// file, so a scan of the whole file merges them and can only ever make the
/// guard more permissive.
Map<String, Set<String>> _handlersByChannel(String kotlin) {
  final masked = _maskKotlinStringsAndComments(kotlin);

  // `private val CHANNEL = "com.neogamelab.neostation/game"` and friends: the
  // registration sites name the constant, not the string.
  final constants = <String, String>{};
  for (final match in RegExp(
    r'\bval\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"',
  ).allMatches(kotlin)) {
    constants[match.group(1)!] = match.group(2)!;
  }

  final result = <String, Set<String>>{};
  for (final match in RegExp(
    r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*MethodChannel\([^,]+,\s*([^)]+?)\s*\)',
  ).allMatches(kotlin)) {
    final variable = match.group(1)!;
    final channel = _resolveKotlinChannelExpression(match.group(2)!, constants);
    if (channel == null) continue;

    final block = _handlerBlock(kotlin, masked, variable, match.end);
    if (block == null) continue;

    // Handlers look like:  "methodName" -> {
    result
        .putIfAbsent(channel, () => <String>{})
        .addAll(
          RegExp(
            r'"([A-Za-z][A-Za-z0-9_]*)"\s*->',
          ).allMatches(block).map((m) => m.group(1)!),
        );
  }
  return result;
}

String? _resolveKotlinChannelExpression(
  String expression,
  Map<String, String> constants,
) {
  final trimmed = expression.trim();
  if (trimmed.startsWith('"')) {
    final literal = RegExp(r'^"([^"]+)"$').firstMatch(trimmed);
    return literal?.group(1);
  }
  return constants[trimmed];
}

/// Source of the `variable.setMethodCallHandler { ... }` lambda that follows
/// [from], or null when the variable never gets a handler.
String? _handlerBlock(String kotlin, String masked, String variable, int from) {
  final registration = RegExp(
    RegExp.escape(variable) + r'\s*\??\s*\.setMethodCallHandler',
  ).firstMatch(masked.substring(from));
  if (registration == null) return null;

  final open = masked.indexOf('{', from + registration.end);
  if (open < 0) return null;

  final close = _matchingBrace(masked, open);
  if (close < 0) return null;

  return kotlin.substring(open, close + 1);
}

/// Index of the `}` closing the `{` at [open], or -1 when unbalanced.
///
/// Expects [source] to have had strings and comments masked out already, so a
/// brace inside a message or a `${...}` template cannot skew the depth.
int _matchingBrace(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final char = source[i];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Blanks every Kotlin string literal, char literal and comment with spaces,
/// preserving length so offsets still line up with the original source.
String _maskKotlinStringsAndComments(String source) {
  final out = List<String>.generate(source.length, (i) => source[i]);
  void blank(int from, int to) {
    for (var i = from; i < to && i < source.length; i++) {
      if (source[i] != '\n') out[i] = ' ';
    }
  }

  var i = 0;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      final stop = end < 0 ? source.length : end;
      blank(i, stop);
      i = stop;
    } else if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      final stop = end < 0 ? source.length : end + 2;
      blank(i, stop);
      i = stop;
    } else if (source.startsWith('"""', i)) {
      final end = source.indexOf('"""', i + 3);
      final stop = end < 0 ? source.length : end + 3;
      blank(i, stop);
      i = stop;
    } else if (source[i] == '"' || source[i] == "'") {
      final quote = source[i];
      var j = i + 1;
      while (j < source.length && source[j] != quote && source[j] != '\n') {
        j += source[j] == r'\' ? 2 : 1;
      }
      final stop = j < source.length ? j + 1 : source.length;
      blank(i, stop);
      i = stop;
    } else {
      i++;
    }
  }
  return out.join();
}

// ---------------------------------------------------------------------------
// Dart side
// ---------------------------------------------------------------------------

/// Every `lib/` file that sends method calls, mapped to the channel names it
/// can be shown to use.
///
/// Deliberately not "files containing the channel literal". That worked only
/// while all ~12 callers re-declared the literal; folding them into one shared
/// constant would empty the scan and leave a guard that passes without
/// checking anything. So a file is attributed by the literal *or* by any
/// identifier that resolves, somewhere in `lib/`, to a channel — and `part`
/// files inherit their library's channels.
///
/// An empty value means "invokes methods, channel unknown" and is reported as
/// a failure, not skipped.
Map<String, Set<String>> _dartChannelsByFile(Directory root) {
  final sources = <String, String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      sources[p.normalize(entity.path)] = entity.readAsStringSync();
    }
  }

  final identifierChannels = _channelBearingIdentifiers(sources);

  Set<String> channelsIn(String path) {
    final source = sources[path];
    if (source == null) return {};
    final channels = _channelNamePattern
        .allMatches(source)
        .map((m) => m.group(0)!)
        .toSet();
    identifierChannels.forEach((identifier, channel) {
      if (RegExp(r'\b' + RegExp.escape(identifier) + r'\b').hasMatch(source)) {
        channels.add(channel);
      }
    });
    return channels;
  }

  final result = <String, Set<String>>{};
  for (final entry in sources.entries) {
    if (!_invokePattern.hasMatch(entry.value)) continue;

    final channels = channelsIn(entry.key);
    // A `part` names no channel of its own; the declaration sits in the
    // library it belongs to (or in one of its sibling parts).
    if (channels.isEmpty) {
      for (final sibling in _libraryFiles(entry.key, sources)) {
        channels.addAll(channelsIn(sibling));
      }
    }
    result[entry.key] = channels;
  }
  return result;
}

/// Identifiers that stand for a channel name — a shared `String` constant or a
/// `MethodChannel` built from one.
///
/// Only unambiguous ones are kept. Half the callers name their local channel
/// `platform` or `_channel`, and those bind to different channels in different
/// files, so treating them as global would attribute calls to the wrong
/// channel. A genuinely shared constant has a distinct name and survives.
Map<String, String> _channelBearingIdentifiers(Map<String, String> sources) {
  final candidates = <String, Set<String>>{};

  void record(String identifier, String channel) {
    candidates.putIfAbsent(identifier, () => <String>{}).add(channel);
  }

  final stringConstant = RegExp(
    r"""\b(?:const|final)\s+(?:String\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'(com\.neogamelab\.neostation/[A-Za-z0-9_]+)'""",
  );
  final channelConstruction = RegExp(
    r'\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:const\s+)?MethodChannel\(\s*([^),]+?)\s*,?\s*\)',
    dotAll: true,
  );

  for (final source in sources.values) {
    for (final match in stringConstant.allMatches(source)) {
      record(match.group(1)!, match.group(2)!);
    }
    for (final match in channelConstruction.allMatches(source)) {
      final argument = match.group(2)!.trim();
      final literal = RegExp(
        r"""^'(com\.neogamelab\.neostation/[A-Za-z0-9_]+)'$""",
      ).firstMatch(argument);
      if (literal != null) {
        record(match.group(1)!, literal.group(1)!);
      } else if (candidates[argument]?.length == 1) {
        record(match.group(1)!, candidates[argument]!.single);
      }
    }
  }

  return {
    for (final entry in candidates.entries)
      if (entry.value.length == 1) entry.key: entry.value.single,
  };
}

/// The other files making up [path]'s library: the file it is a `part of`, and
/// that file's other parts.
Iterable<String> _libraryFiles(String path, Map<String, String> sources) {
  final partOf = RegExp(
    r"""^\s*part\s+of\s+'([^']+)'""",
    multiLine: true,
  ).firstMatch(sources[path] ?? '');
  if (partOf == null) return const [];

  final parent = p.normalize(p.join(p.dirname(path), partOf.group(1)!));
  final parentSource = sources[parent];
  if (parentSource == null) return const [];

  return [
    parent,
    for (final part in RegExp(
      r"""^\s*part\s+'([^']+)'""",
      multiLine: true,
    ).allMatches(parentSource))
      p.normalize(p.join(p.dirname(parent), part.group(1)!)),
  ];
}

List<String> _filesOnChannel(
  Map<String, Set<String>> channelsByFile,
  String channel,
) =>
    (channelsByFile.entries
          .where((e) => e.value.length == 1 && e.value.single == channel)
          .map((e) => e.key)
          .toList())
      ..sort();

/// Method names sent on [channel], each mapped to the files that send it.
Map<String, List<String>> _invokedNamesOnChannel(
  Map<String, Set<String>> channelsByFile,
  String channel,
) {
  final invoked = <String, List<String>>{};
  for (final path in _filesOnChannel(channelsByFile, channel)) {
    final source = File(path).readAsStringSync();
    for (final match in _invokePattern.allMatches(source)) {
      invoked.putIfAbsent(match.group(1)!, () => <String>[]).add(path);
    }
  }
  return invoked;
}
