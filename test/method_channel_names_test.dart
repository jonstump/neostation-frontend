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

/// Channels Dart may invoke on that `MainActivity.kt` deliberately does not
/// register, with where their handler actually lives.
///
/// Every *other* channel a `lib/` file sends on must appear in the
/// `MainActivity.kt` scan, or its calls would be dropped from every check below
/// — a channel nobody answers is the same bug class as a method nobody answers.
/// So the exceptions are named here rather than falling through silently, and
/// adding one is a deliberate act with a reason attached.
const _channelsHandledOutsideMainActivity = <String, String>{
  'com.neogamelab.neostation/secondary_apps':
      'registered by SecondaryAppsPresentation.kt on the second display '
      'engine; its handler names are not scanned yet',
};

/// The game channel is the one this guard exists for, so its discovery is held
/// to floors as well as to "not empty".
///
/// The name floor tracks features: 27 distinct names are sent today, and that
/// number moves only when platform methods are genuinely added or removed, so
/// 20 is a real assertion about the scan still matching call sites.
///
/// The file floor is deliberately structural rather than tight. It used to sit
/// at 8 against 11, but six of those callers make one or two calls each, so
/// folding a couple of them behind a shared service — an ordinary refactor —
/// would trip it and print a message reading like a broken scan, inviting the
/// next person to just lower the number. What actually guards resolution is
/// elsewhere and is not refactor-sensitive: a caller whose channel cannot be
/// resolved fails as unresolved, a channel nobody registers fails as
/// unregistered, and `openSafDirectoryPicker` is pinned to its file by name. So
/// this only asserts the scan has not collapsed onto a single file.
///
/// Lower either number only alongside a real reduction in callers, never to
/// make a suddenly-shrunken scan pass.
const _minGameChannelCallerFiles = 3;
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

    // Resolving to a channel is not enough: the last test iterates the
    // *handler* map, so a file resolving to a channel MainActivity.kt never
    // registers has every one of its calls dropped with nothing asserted. A
    // stale or mistyped channel string is the same bug as a stale or mistyped
    // method name — every call on it throws — so it fails here.
    final unregistered = <String, List<String>>{};
    dartChannelsByFile.forEach((file, channels) {
      for (final channel in channels) {
        if (handlersByChannel.containsKey(channel)) continue;
        if (_channelsHandledOutsideMainActivity.containsKey(channel)) continue;
        unregistered.putIfAbsent(channel, () => <String>[]).add(file);
      }
    });
    for (final files in unregistered.values) {
      files.sort();
    }

    expect(
      unregistered,
      isEmpty,
      reason:
          'these files send method calls on channels no handler in '
          '$_mainActivityPath registers, so every call on them is a '
          'MissingPluginException and none of them is checked by this test. '
          'Fix the channel name, register the handler, or — if the handler '
          'genuinely lives elsewhere — add it to '
          '_channelsHandledOutsideMainActivity with the reason: $unregistered',
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

  // The two scans above are regexes over source text, so their own failure
  // modes are best pinned on source we control rather than on MainActivity.kt
  // as it happens to be written today.
  group('the scans themselves', () {
    test('a commented-out when arm is not a handler', () {
      const kotlin = '''
class MainActivity {
  private val CHANNEL = "com.neogamelab.neostation/game"
  fun configure() {
    channel = MethodChannel(messenger, CHANNEL)
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "liveHandler" -> { result.success(true) }
        // "commentedOut" -> { removed for now
        /* "blockCommented" -> { also removed */
        else -> result.notImplemented()
      }
    }
  }
}
''';

      final handlers = _handlersByChannel(kotlin)[_gameChannel];
      expect(handlers, contains('liveHandler'));
      for (final ghost in const ['commentedOut', 'blockCommented']) {
        expect(
          handlers,
          isNot(contains(ghost)),
          reason:
              '$ghost is written in a comment, not registered. Reading it as a '
              'live handler would let a note in MainActivity.kt about a '
              'deleted method silently re-authorise that method for callers.',
        );
      }
    });

    test('handler names inside string literals survive the comment mask', () {
      // The comment mask must not blank string literals: the handler names are
      // string literals. This is the assertion that stops the B1 fix from
      // being "mask everything", which would empty the handler set instead.
      const kotlin = '''
class MainActivity {
  fun configure() {
    channel = MethodChannel(messenger, "com.neogamelab.neostation/game")
    channel.setMethodCallHandler { call, result ->
      // a comment mentioning } and " to skew a naive scan
      val message = "an unbalanced } and a \\" inside a string"
      when (call.method) {
        "realHandler" -> { result.success(message) }
        else -> result.notImplemented()
      }
    }
  }
}
''';

      expect(_handlersByChannel(kotlin)[_gameChannel], contains('realHandler'));
    });

    test('the caller pattern sees every MethodChannel invoke form', () {
      const dart = '''
        await platform.invokeMethod('plainSingle');
        await platform.invokeMethod("plainDouble");
        await platform.invokeMethod<bool>('generic');
        await platform.invokeListMethod<String>('listForm');
        await platform.invokeMapMethod<String, dynamic>("mapForm");
        await platform.invokeMethod(
          'wrappedOntoTheNextLine',
        );
      ''';

      expect(
        _invokePattern.allMatches(dart).map(_invokedName).toSet(),
        {
          'plainSingle',
          'plainDouble',
          'generic',
          'listForm',
          'mapForm',
          'wrappedOntoTheNextLine',
        },
        reason:
            'a call form the pattern misses is worse than unchecked: a file '
            'whose only platform calls use it never enters the scan at all, so '
            'it is not even reported as unresolved',
      );

      expect(
        _invokePattern.hasMatch("platform.invokeMethod('mismatched\")"),
        isFalse,
        reason: 'the opening and closing quote must match',
      );
    });
  });
}

const _gameChannel = 'com.neogamelab.neostation/game';

/// Any `com.neogamelab.neostation/...` channel name, wherever it is written.
final _channelNamePattern = RegExp(
  r'com\.neogamelab\.neostation/[A-Za-z0-9_]+',
);

/// Callers look like:  `invokeMethod('name'`  /  `invokeMethod<T>('name'`.
///
/// `invokeListMethod` / `invokeMapMethod` are ordinary `MethodChannel` APIs and
/// a double-quoted name is ordinary Dart, so both are matched too. Nothing in
/// `lib/` writes them today, but a file whose *only* platform calls took one of
/// those forms would not even enter the scan — it would be invisible rather
/// than reported as unresolved.
///
/// The quote is captured and back-referenced so `'name"` cannot match.
final _invokePattern = RegExp(
  r"""invoke(?:List|Map)?Method(?:<[^>]*>)?\(\s*(['"])([A-Za-z][A-Za-z0-9_]*)\1""",
);

/// The method name captured by [_invokePattern] (group 1 is the quote).
String _invokedName(RegExpMatch match) => match.group(2)!;

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
  // Two masks, because the two scans need opposite things. Brace matching has
  // to ignore string contents (a `}` in a message or a `${...}` template would
  // skew the depth); the handler-name scan must keep them, because the names
  // *are* string literals. Both must ignore comments — a commented-out `when`
  // arm is not a handler, and reading one as live is how a deleted method name
  // would silently re-authorise itself.
  final masked = _maskKotlin(kotlin, maskStrings: true);
  final live = _maskKotlin(kotlin, maskStrings: false);

  // `private val CHANNEL = "com.neogamelab.neostation/game"` and friends: the
  // registration sites name the constant, not the string.
  final constants = <String, String>{};
  for (final match in RegExp(
    r'\bval\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"',
  ).allMatches(live)) {
    constants[match.group(1)!] = match.group(2)!;
  }

  final result = <String, Set<String>>{};
  for (final match in RegExp(
    r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*MethodChannel\([^,]+,\s*([^)]+?)\s*\)',
  ).allMatches(live)) {
    final variable = match.group(1)!;
    final channel = _resolveKotlinChannelExpression(match.group(2)!, constants);
    if (channel == null) continue;

    final block = _handlerBlock(live, masked, variable, match.end);
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
///
/// [masked] (strings *and* comments blanked) locates the block, because only it
/// gives a reliable brace depth. The block is then sliced out of [live]
/// (comments blanked, string literals kept) so that whatever scans the result
/// sees the handler names but not anything written in a comment. Both masks
/// preserve length, so the offsets are interchangeable.
String? _handlerBlock(String live, String masked, String variable, int from) {
  final registration = RegExp(
    RegExp.escape(variable) + r'\s*\??\s*\.setMethodCallHandler',
  ).firstMatch(masked.substring(from));
  if (registration == null) return null;

  final open = masked.indexOf('{', from + registration.end);
  if (open < 0) return null;

  final close = _matchingBrace(masked, open);
  if (close < 0) return null;

  return live.substring(open, close + 1);
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

/// Blanks Kotlin comments — and, when [maskStrings], single-line string and
/// char literals too — with spaces, preserving length so offsets still line up
/// with the original source and with the other mask of the same source.
///
/// Raw (`"""`) strings are always blanked: they can hold arbitrary text,
/// including braces and quotes, and no handler arm is written as one.
/// Single-line literals are kept when [maskStrings] is false, because that mask
/// exists to read `"handlerName" ->` arms out of live code.
///
/// The walk is the same either way — string literals still have to be traversed
/// so that a `//` inside one is not mistaken for a comment.
String _maskKotlin(String source, {required bool maskStrings}) {
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
      if (maskStrings) blank(i, stop);
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
      invoked.putIfAbsent(_invokedName(match), () => <String>[]).add(path);
    }
  }
  return invoked;
}
