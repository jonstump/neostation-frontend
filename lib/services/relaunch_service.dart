import 'dart:io';

import 'package:flutter/services.dart';

import 'logger_service.dart';

// Governing: ADR-0022 (in-app reset), SPEC-0021 REQ "Relaunch"
/// Puts the freshly reset app out of its current state: Android finishes and
/// restarts the activity, desktop starts the process again where the platform
/// allows.
///
/// The providers were built once at startup from the state the reset just
/// deleted, so the app never tries to run on from an empty state — the process
/// goes away and the next launch runs the setup wizard.
class RelaunchService {
  /// The game channel `MainActivity` registers every handler on.
  static const MethodChannel _channel = MethodChannel(
    'com.neogamelab.neostation/game',
  );

  static final _log = LoggerService.instance;

  /// Attempts a relaunch and reports whether it started.
  ///
  /// False means the platform refused or could not be reached; the caller then
  /// shows the localized "start it again" notice and exits.
  static Future<bool> relaunch() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('restartActivity');
        return true;
      } on PlatformException catch (e) {
        _log.e('RelaunchService: store=android error=${e.message}');
        return false;
      } on MissingPluginException catch (e) {
        _log.e('RelaunchService: store=android error=${e.message}');
        return false;
      }
    }

    try {
      await Process.start(
        Platform.resolvedExecutable,
        [],
        mode: ProcessStartMode.detached,
        workingDirectory: Directory.current.path,
      );
      return true;
    } catch (e) {
      _log.w('RelaunchService: store=desktop outcome=failed error=$e');
      return false;
    }
  }
}
