import 'package:flutter/widgets.dart';
import 'package:flutter_localization/flutter_localization.dart';

import '../l10n/app_locale.dart';
import '../services/romm_service.dart';

/// The `AppLocale` key the connect screen shows for a failed pairing, chosen
/// by the sentinel on the exception rather than by its message: a code that
/// never matched the format or that the server refused, one that expired or
/// was already spent, and the rate limit each get their own sentence. Null
/// for [RommErrorKind.other] and for no kind at all, which tells the caller
/// to fall back to the message the provider returned, as the password and
/// API-key modes do.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Error Handling Standards"
String? rommPairErrorKey(RommErrorKind? kind) {
  return switch (kind) {
    RommErrorKind.pairCodeInvalid => AppLocale.rommPairCodeInvalid,
    RommErrorKind.pairCodeExpired => AppLocale.rommPairCodeExpired,
    RommErrorKind.pairRateLimited => AppLocale.rommPairRateLimited,
    // Not a pairing outcome: a scope refusal comes from a later, authenticated
    // call (firmware, say), and its own screen words it.
    // Governing: ADR-0012 (download BIOS firmware from RomM), SPEC-0012 REQ "Firmware Model And Service"
    RommErrorKind.scopeDenied => null,
    // A server that predates the pairing endpoint gets its own sentence, so
    // the user is told to upgrade RomM instead of shown a raw 404.
    // Governing: ADR-0010 (RomM heartbeat capability probe),
    // SPEC-0010 REQ "Gated Call Sites"
    RommErrorKind.unsupported => AppLocale.rommPairServerTooOld,
    // A maintenance task that is already running is a maintenance outcome, not
    // a pairing one; the browse screen's own toast words it.
    // Governing: ADR-0019 (expose RomM library filters, search and
    // maintenance), SPEC-0018 REQ "Maintenance Tasks"
    RommErrorKind.taskBusy => null,
    // Not a pairing outcome either: an unconfigured metadata provider only
    // surfaces from the match picker's own server-side search, which has its
    // own sentence for it.
    // Governing: ADR-0019 (expose RomM library filters, search and
    // maintenance), SPEC-0018 REQ "Metadata Search And Apply"
    RommErrorKind.noMetadataSource => null,
    // A duplicate collection name only comes from the collection push, which
    // words it itself.
    // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Collection Write Calls"
    RommErrorKind.alreadyExists => null,
    // Every non-pairing kind falls back to the provider's own message, the
    // same as [RommErrorKind.other]: they cannot arise from an exchange.
    RommErrorKind.other || RommErrorKind.payloadTooLarge || null => null,
  };
}

/// `yyyy-MM-dd` in the device's local zone, for the "token expires on"
/// line. The app carries no date-formatting dependency, and the day is all a
/// user needs to know whether to pair again.
String rommTokenExpiryDate(DateTime expiresAt) {
  final local = expiresAt.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// A failure the provider worded itself rather than taking from
/// [RommException.message]: an `AppLocale` [localeKey] plus the optional
/// [detail] to substitute into its `{error}` placeholder.
///
/// The provider has no `BuildContext`, so it cannot translate; it records the
/// key here and the widget layer resolves it with [rommLocalizedErrorText].
/// `RommProvider.lastError` keeps the English sentence as the log/diagnostic
/// fallback, so a surface that has not adopted this still shows something.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Localized User-Facing Text"
class RommLocalizedError {
  const RommLocalizedError(this.localeKey, {this.detail});

  /// The `AppLocale` key holding the translated sentence.
  final String localeKey;

  /// What replaces `{error}` in that sentence — the raw exception text, kept
  /// so a network or TLS failure is still diagnosable. Null when the sentence
  /// carries no placeholder.
  final String? detail;

  /// [template] is the translated sentence for [localeKey]; this fills its
  /// `{error}` placeholder with [detail]. Split out from
  /// [rommLocalizedErrorText] so the substitution can be exercised without a
  /// `BuildContext`.
  String format(String template) {
    final value = detail;
    return value == null ? template : template.replaceFirst('{error}', value);
  }
}

/// The translated text for [error], with its [RommLocalizedError.detail]
/// substituted into the `{error}` placeholder when there is one.
// Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Localized User-Facing Text"
String rommLocalizedErrorText(BuildContext context, RommLocalizedError error) =>
    error.format(error.localeKey.getString(context));
