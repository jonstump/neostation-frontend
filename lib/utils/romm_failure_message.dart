import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/romm_service.dart';

/// What to tell the user when connecting to RomM failed, in the app language:
/// [text] looks up an [AppLocale] key (callers pass
/// `(key) => key.getString(context)`). Free of widget imports so the choice
/// is testable on its own.
///
/// The exception's own [RommException.message] is English and meant for the
/// log, and the server's answer is never shown; only the system's reason a
/// server couldn't be reached and a status code are filled in.
String rommFailureMessage(RommException e, String Function(String key) text) {
  // Without a detail, drop the placeholder and the colon before it rather than
  // leave "…: " dangling.
  String withError(String key, String? error) => error == null || error.isEmpty
      ? text(key).replaceFirst(RegExp(r'\s*[:：]\s*\{error\}'), '')
      : text(key).replaceFirst('{error}', error);
  return switch (e.kind) {
    RommFailure.tls => text(AppLocale.rommErrorTls),
    RommFailure.unreachable => withError(
      AppLocale.rommErrorUnreachable,
      e.detail,
    ),
    RommFailure.timeout => text(AppLocale.rommErrorTimeout),
    RommFailure.invalidCredentials => text(AppLocale.invalidCredentials),
    RommFailure.invalidApiKey => text(AppLocale.rommErrorInvalidApiKey),
    RommFailure.unexpectedStatus => withError(
      AppLocale.rommErrorUnexpectedStatus,
      e.statusCode?.toString(),
    ),
    RommFailure.notRomm => text(AppLocale.rommErrorNotRomm),
    RommFailure.serverError => withError(
      AppLocale.rommErrorServerStatus,
      e.statusCode?.toString(),
    ),
    RommFailure.other => text(AppLocale.rommConnectionFailed),
  };
}
