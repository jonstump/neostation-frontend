import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../l10n/app_locale.dart';
import 'log_redaction.dart';

/// The map key under which the NeoSync services park a [NeoSyncLocalizedError]
/// alongside the English `message` their result maps have always carried.
///
/// Keeping both is deliberate: `message` stays the diagnostic/log string and
/// the classification input (`contains('email not verified')`,
/// `contains('quota')`), while this entry is what the screen renders.
const String kNeoSyncLocalizedError = 'localizedError';

/// A NeoSync auth/billing outcome worded by us rather than by the server: an
/// `AppLocale` [localeKey] plus the optional [detail] to substitute into its
/// `{error}` placeholder.
///
/// The name says "error" because failures adopted it first (issue #195); the
/// success sentences ride the same carrier (issue #200) rather than a second
/// mechanism, since the widget already resolves this entry before `message`.
///
/// `AuthService`, `BillingService` and `NeoSyncService` have no `BuildContext`,
/// so they cannot translate; they record the key here and the widget layer
/// resolves it with [neoSyncLocalizedErrorText]. This mirrors
/// `RommLocalizedError` in `romm_pair_error_message.dart` rather than inventing
/// a third mechanism.
///
/// [detail] is always redacted at construction — see [neoSyncNetworkError] and
/// [neoSyncServerError]. An exception's `toString()` embeds the request URI
/// query string, and a server error body can echo whatever it was sent, so the
/// text that reaches the sign-in screen has to be scrubbed before it is shown,
/// not only before it is logged.
// Governing: issue #195
class NeoSyncLocalizedError {
  const NeoSyncLocalizedError(this.localeKey, {this.detail});

  /// The `AppLocale` key holding the translated sentence.
  final String localeKey;

  /// What replaces `{error}` in that sentence — already redacted. Null when the
  /// sentence carries no placeholder.
  final String? detail;

  /// [template] is the translated sentence for [localeKey]; this fills its
  /// `{error}` placeholder with [detail]. Split out from
  /// [neoSyncLocalizedErrorText] so the substitution can be exercised without a
  /// `BuildContext`.
  String format(String template) {
    final value = detail;
    return value == null ? template : template.replaceFirst('{error}', value);
  }
}

/// A success sentence for [localeKey].
///
/// Issue #200. `AuthService` used to hand the widget hardcoded English here
/// (`'Login successful'`, `data['message'] ?? 'Password reset successfully'`).
/// The server's own success text, when it sends one, stays in the result map's
/// `message` for the log and is not rendered: it is English-only, which is the
/// complaint this fixes, and the sentences in `AppLocale` already say the same
/// thing — see `AuthService._success`.
NeoSyncLocalizedError neoSyncSuccess(String localeKey) =>
    NeoSyncLocalizedError(localeKey);

/// What the sign-in screen shows, and what it logs, when one of its own
/// handlers throws (issue #201).
///
/// Decision: the exception does not go on screen at all. `auth_form.dart`
/// appended `': $e'` to the translated [localeKey] sentence at six sites, and
/// the widget layer is the wrong place to rely on every service beneath it
/// never rethrowing something that carries a URL or a token. The sentence alone
/// is what the user can act on; the detail is only useful in the log, so
/// [logged] carries it there, redacted, tagged with [where] so the log line
/// still says which path failed.
///
/// [where] is the complete tag, class included (`'AuthForm.submit'`): this
/// helper does not know who called it, so a second adopter names its own site
/// rather than inheriting the first one's prefix.
({NeoSyncLocalizedError shown, String logged}) neoSyncCaughtException(
  Object error, {
  required String localeKey,
  required String where,
}) => (
  shown: NeoSyncLocalizedError(localeKey),
  logged: '$where: ${redactSecrets(error.toString())}',
);

/// The "Network error: {error}" sentence for a thrown [error], with the
/// exception text redacted.
NeoSyncLocalizedError neoSyncNetworkError(Object error) =>
    NeoSyncLocalizedError(
      AppLocale.neoSyncNetworkError,
      detail: redactSecrets(error.toString()),
    );

/// The sentence for a non-2xx response.
///
/// [serverError] is the body's `error` field. When the server worded the
/// failure itself that text is quoted — redacted — inside our own translated
/// "Server error: {error}" frame, because the client cannot translate prose it
/// has never seen. When the server sent nothing usable, [fallbackKey] carries
/// the whole sentence and there is nothing to substitute.
NeoSyncLocalizedError neoSyncServerError(
  Object? serverError,
  String fallbackKey,
) {
  final text = serverError?.toString().trim();
  if (text == null || text.isEmpty) {
    return NeoSyncLocalizedError(fallbackKey);
  }
  return NeoSyncLocalizedError(
    AppLocale.neoSyncServerError,
    detail: redactSecrets(text),
  );
}

/// The translated text for [error], with its [NeoSyncLocalizedError.detail]
/// substituted into the `{error}` placeholder when there is one.
String neoSyncLocalizedErrorText(
  BuildContext context,
  NeoSyncLocalizedError error,
) => error.format(error.localeKey.getString(context));

/// The message to show for a NeoSync service [result] map: the localized
/// sentence when the service recorded one, otherwise the map's own (already
/// redacted) English `message`.
///
/// The fallback matters for any result shape that has not adopted
/// [NeoSyncLocalizedError] yet; `AuthService` success paths have (issue #200).
String? neoSyncResultMessage(
  BuildContext context,
  Map<String, dynamic> result,
) {
  final localized = result[kNeoSyncLocalizedError];
  if (localized is NeoSyncLocalizedError) {
    return neoSyncLocalizedErrorText(context, localized);
  }
  return result['message'] as String?;
}

/// [neoSyncResultMessage], never null. A result map that carries neither a
/// localized sentence nor a `message` — an empty map, a shape nobody has
/// worded yet — renders the translated [fallbackKey] instead. The `String?`
/// is fine to park in a nullable field that hides the box when empty; it is
/// not fine to interpolate, where it prints the literal word `null` on the
/// sign-in screen (issue #221).
String neoSyncResultMessageOrFallback(
  BuildContext context,
  Map<String, dynamic> result, {
  String fallbackKey = AppLocale.anErrorOccurred,
}) => neoSyncResultMessage(context, result) ?? fallbackKey.getString(context);
