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

/// A NeoSync auth/billing failure worded by us rather than by the server: an
/// `AppLocale` [localeKey] plus the optional [detail] to substitute into its
/// `{error}` placeholder.
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
/// The fallback matters for the success paths and for any result shape that has
/// not adopted [NeoSyncLocalizedError] yet.
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
