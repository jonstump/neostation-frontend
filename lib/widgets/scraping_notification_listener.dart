import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';

import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/scraping_provider.dart';
import 'package:neostation/services/global_notification_service.dart';

/// App-level listener that keeps the header notification bell's scraping
/// progress notification in sync with [ScrapingProvider] for the whole
/// duration of a scraping session.
///
/// Lives above the tab content (next to [MusicNotificationListener]) so the
/// progress bar keeps advancing even when the user switches tabs or leaves the
/// scraper screen while the session runs.
class ScrapingNotificationListener extends StatefulWidget {
  final Widget child;

  const ScrapingNotificationListener({super.key, required this.child});

  @override
  State<ScrapingNotificationListener> createState() =>
      _ScrapingNotificationListenerState();
}

class _ScrapingNotificationListenerState
    extends State<ScrapingNotificationListener> {
  static const _notificationId = 'scraping_progress';

  ScrapingProvider? _provider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<ScrapingProvider>();
    if (provider != _provider) {
      _provider?.removeListener(_onScrapingChanged);
      _provider = provider;
      _provider!.addListener(_onScrapingChanged);
    }
  }

  @override
  void dispose() {
    _provider?.removeListener(_onScrapingChanged);
    super.dispose();
  }

  void _onScrapingChanged() {
    final provider = _provider;
    if (provider == null || !mounted) return;
    if (!provider.isScraping) return;

    final total = provider.totalGames;
    final processed = provider.processedGames;
    GlobalNotificationService().update(
      id: _notificationId,
      message: total > 0
          ? '${AppLocale.scrapingInProgress.getString(context)} $processed / $total'
          : AppLocale.scrapingInProgress.getString(context),
      type: GlobalNotificationType.info,
      // Zero, not null, while the total is unknown: the scrape opens this same
      // id at `progress: 0` and `update` clears the bar unless the call names
      // one (#229), so null here would blank a bar that is about to come back.
      //
      // The window is not a frame. `startScraping()` zeroes `_totalGames` and
      // notifies immediately, and the count is only known after the system-id
      // sync round trip, so the bar would vanish for as long as that network
      // call takes and reappear at the first counted game — a flicker on every
      // single scrape. A zeroed bar is also the honest reading: nothing has
      // been processed yet. Issue #230.
      progress: total > 0 ? processed / total : 0,
      ongoing: true,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
