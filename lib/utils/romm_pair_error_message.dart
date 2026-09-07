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
    RommErrorKind.other || null => null,
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
