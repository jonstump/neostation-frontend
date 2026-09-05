import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/screenscraper_service.dart';

/// How a per-game scrape notification should read: a success, a neutral
/// note, or an error. Mapped onto the notification widget's own type by the
/// caller so this file stays free of widget imports.
enum ScrapeResultTone { success, info, error }

/// The localized notification for one `scrapeSingleGame` result map: the
/// `AppLocale` key, the placeholder values to substitute into it, and its
/// tone.
///
/// [placeholders] are substituted verbatim; [localizedPlaceholders] name
/// another `AppLocale` key per placeholder and are resolved through the same
/// translator first, so a failure reason that is itself a key reads in the
/// user's language.
class ScrapeResultMessage {
  final String key;
  final Map<String, String> placeholders;
  final Map<String, String> localizedPlaceholders;
  final ScrapeResultTone tone;

  const ScrapeResultMessage({
    required this.key,
    this.placeholders = const {},
    this.localizedPlaceholders = const {},
    required this.tone,
  });

  /// Resolves [key] through [t] and substitutes every placeholder.
  String format(String Function(String key) t) {
    var text = t(key);
    for (final entry in placeholders.entries) {
      text = text.replaceFirst('{${entry.key}}', entry.value);
    }
    for (final entry in localizedPlaceholders.entries) {
      text = text.replaceFirst('{${entry.key}}', t(entry.value));
    }
    return text;
  }
}

/// Picks the notification for a `ScreenScraperService.scrapeSingleGame`
/// [result] map so every per-game entry point names the source the same way.
///
/// A success names the source that handled the game — RomM, ScreenScraper,
/// or ScreenScraper after RomM had nothing (`rommAttempted` without a `romm`
/// source). A failure wraps the service's own message key, which is already
/// localized, as the reason; a result with no message reads as an unexpected
/// error. Pure so the choice is testable without widgets.
// Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
ScrapeResultMessage scrapeResultMessageFor(Map<String, dynamic> result) {
  if (result['success'] == true) {
    if (result['source'] == ScreenScraperService.scrapeSourceRomm) {
      return const ScrapeResultMessage(
        key: AppLocale.scrapeCompletedFromRomm,
        tone: ScrapeResultTone.success,
      );
    }
    if (result['rommAttempted'] == true) {
      return const ScrapeResultMessage(
        key: AppLocale.scrapeCompletedFallback,
        tone: ScrapeResultTone.success,
      );
    }
    return const ScrapeResultMessage(
      key: AppLocale.scrapeCompletedFromScreenscraper,
      tone: ScrapeResultTone.success,
    );
  }

  final message = result['message'];
  final reasonKey = message is String && message.isNotEmpty
      ? message
      : AppLocale.scrapeUnexpectedError;
  // Missing credentials is a setup condition, not a failed attempt, and the
  // grid and card sites showed it as an info toast before the RomM-first
  // chain moved the check behind the step; keep that tone.
  final tone = reasonKey == AppLocale.scrapeNoCredentials
      ? ScrapeResultTone.info
      : ScrapeResultTone.error;
  return ScrapeResultMessage(
    key: AppLocale.scrapeFailedWithReason,
    localizedPlaceholders: {'reason': reasonKey},
    tone: tone,
  );
}
