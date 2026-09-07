import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every method name Dart sends on `com.neogamelab.neostation/game` must have a
/// handler in `MainActivity.kt`.
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
void main() {
  test('every invoked channel method has a MainActivity handler', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/neogamelab/neostation/MainActivity.kt',
    ).readAsStringSync();

    // Handlers look like:  "methodName" -> {
    final handled = RegExp(
      r'"([A-Za-z][A-Za-z0-9_]*)"\s*->',
    ).allMatches(kotlin).map((m) => m.group(1)!).toSet();
    expect(
      handled,
      isNotEmpty,
      reason:
          'failed to parse any handler out of MainActivity.kt — the '
          'handler syntax probably changed and this guard needs updating',
    );

    // Callers look like:  invokeMethod('name'  /  invokeMethod<T>('name'
    final invokePattern = RegExp(
      r"invokeMethod(?:<[^>]*>)?\(\s*'([A-Za-z][A-Za-z0-9_]*)'",
    );

    // Two names predate this guard and have no handler under any spelling —
    // MainActivity has never implemented them, so they are not typos to correct
    // but dead Dart that could never have worked. Both are uncalled. Tracked
    // separately; listed here so the guard stays live for everything else
    // rather than being disabled until they are dealt with.
    const knownDeadAndUncalled = {'releasePermission', 'uriToPath'};

    final missing = <String, List<String>>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (!source.contains('com.neogamelab.neostation/game')) continue;

      for (final match in invokePattern.allMatches(source)) {
        final method = match.group(1)!;
        if (knownDeadAndUncalled.contains(method)) continue;
        if (!handled.contains(method)) {
          missing.putIfAbsent(method, () => []).add(entity.path);
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'These method names are sent on the game channel but no handler '
          'in MainActivity.kt answers them, so each is a MissingPluginException '
          'waiting for its first caller on a device: $missing',
    );
  });
}
