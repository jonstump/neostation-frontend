/// Per-file progress for the RomM sync banner.
///
/// A transfer whose size the server never reported (null or zero total) has
/// no meaningful fraction and is drawn indeterminate; anything else is the
/// received share clamped to the bar's range so a late Content-Length change
/// can never push it past full.
double? rommFileFraction({required int received, required int? total}) {
  if (total == null || total <= 0) return null;
  return (received / total).clamp(0.0, 1.0);
}
