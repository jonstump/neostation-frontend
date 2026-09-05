import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../l10n/app_locale.dart';
import '../utils/gamepad_nav.dart';
import '../services/game_service.dart';

/// Specialized dialog content providing gamepad-friendly navigation for
/// scraping session summaries.
///
/// Extracted verbatim from `ScreenScraperService`'s private
/// `_ScrapingSummaryDialogContent` so the service file stays lean; behavior and
/// layout are unchanged.
class ScrapingSummaryDialog extends StatefulWidget {
  final int totalGames;
  final int successfulGames;
  final int failedGames;
  final String elapsedTime;

  /// Games scraped by RomM and by ScreenScraper. Both are null when RomM took
  /// no part in the run, and the per-source lines are then not shown.
  // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
  final int? rommGames;
  final int? screenscraperGames;

  const ScrapingSummaryDialog({
    super.key,
    required this.totalGames,
    required this.successfulGames,
    required this.failedGames,
    required this.elapsedTime,
    this.rommGames,
    this.screenscraperGames,
  });

  @override
  State<ScrapingSummaryDialog> createState() => _ScrapingSummaryDialogState();
}

class _ScrapingSummaryDialogState extends State<ScrapingSummaryDialog> {
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onSelectItem: () => Navigator.of(context).pop(),
      onBack: () => Navigator.of(context).pop(),
    );
    _gamepadNav.initialize();
    GamepadNavigationManager.pushLayer(
      'scraping_summary_dialog',
      onActivate: () => _gamepadNav.activate(),
      onDeactivate: () => _gamepadNav.deactivate(),
    );
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('scraping_summary_dialog');
    _gamepadNav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rate = widget.totalGames > 0
        ? ((widget.successfulGames / widget.totalGames) * 100).toStringAsFixed(
            1,
          )
        : '0.0';
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
      child: Container(
        constraints: BoxConstraints(maxWidth: 240.w),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
            width: 1.r,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 10.r,
              spreadRadius: 1.r,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: 8.h),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).scaffoldBackgroundColor.withValues(alpha: 0.2),
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.1),
                      width: 1.r,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Symbols.check_circle_rounded,
                      size: 16.r,
                      color: Colors.green,
                    ),
                    SizedBox(width: 6.w),
                    Text(
                      'Scraping Finished',
                      style: TextStyle(
                        fontSize: 13.r,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                child: Column(
                  children: [
                    _buildCompactStatRow('Games', widget.totalGames.toString()),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Success',
                      '${widget.successfulGames} ($rate%)',
                      valueColor: Colors.green,
                    ),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Failed',
                      widget.failedGames.toString(),
                      valueColor: widget.failedGames > 0
                          ? Colors.orange
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    SizedBox(height: 4.h),
                    _buildCompactStatRow(
                      'Duration',
                      widget.elapsedTime,
                      valueColor: Theme.of(context).colorScheme.primary,
                    ),
                    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Bulk Source Chain"
                    if (widget.rommGames != null) ...[
                      SizedBox(height: 4.h),
                      _buildSourceLine(
                        AppLocale.scrapeSummaryFromRomm,
                        widget.rommGames!,
                      ),
                    ],
                    if (widget.screenscraperGames != null) ...[
                      SizedBox(height: 4.h),
                      _buildSourceLine(
                        AppLocale.scrapeSummaryFromScreenscraper,
                        widget.screenscraperGames!,
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: 12.r, right: 12.r, bottom: 10.r),
                child: SizedBox(
                  width: double.infinity,
                  height: 32.h,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                    ),
                    child: Text(
                      'OK',
                      style: TextStyle(
                        fontSize: 12.r,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One per-source line ("From RomM: N"), from a key with a `{count}`
  /// placeholder.
  Widget _buildSourceLine(String localeKey, int count) {
    return Text(
      localeKey.getString(context).replaceFirst('{count}', count.toString()),
      style: TextStyle(
        fontSize: 11.r,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildCompactStatRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.r,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.r,
            fontWeight: FontWeight.bold,
            color: valueColor ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
