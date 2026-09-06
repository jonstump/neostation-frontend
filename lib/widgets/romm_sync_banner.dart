import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_locale.dart';
import '../providers/romm_bulk_sync.dart';
import '../providers/romm_provider.dart' show RommDownload;
import '../themes/corner_radii.dart';
import '../utils/romm_sync_progress.dart';

/// Human-readable byte size (e.g. "2.1 MB", "54 GB").
String rommFormatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Progress strip for a running bulk sync, shown above the RomM browser's
/// footer.
///
/// Deliberately a band inside the browse screen rather than an app-wide
/// overlay: a global progress overlay is what froze the Thor's primary display
/// (a raster stall over the video PlatformViews), so download progress stays
/// inside the screen that owns it.
///
/// Rebuilds are driven by the [RommBulkSync] alone, not the RomM provider, so a
/// sync stepping through its queue doesn't repaint the ROM grid behind it.
/// Renders nothing while no sync is running.
class RommSyncBanner extends StatelessWidget {
  final RommBulkSync sync;

  /// Looks up the live tracker of an in-flight ROM so each file's own bytes
  /// can be drawn; null keeps the count-based bar.
  final RommDownload? Function(int romId)? downloadFor;

  /// Fires on byte progress (the RomM provider). Listened to here, inside the
  /// band, so per-file bars tick without the browse screen rebuilding.
  final Listenable? progressTicks;

  const RommSyncBanner({
    super.key,
    required this.sync,
    this.downloadFor,
    this.progressTicks,
  });

  @override
  Widget build(BuildContext context) {
    final ticks = progressTicks;
    return ListenableBuilder(
      listenable: ticks == null ? sync : Listenable.merge([sync, ticks]),
      builder: (context, _) {
        if (!sync.isRunning) return const SizedBox.shrink();
        return _band(context);
      },
    );
  }

  Widget _band(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Anything before the queue starts draining has no denominator to show.
    final preparing = sync.phase != RommBulkSyncPhase.downloading;

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius:
            theme.extension<CornerRadii>()?.radiusExternal ??
            BorderRadius.circular(14.r),
        border: Border.all(color: scheme.outline, width: 1.r),
      ),
      child: Row(
        children: [
          Icon(
            sync.cancelRequested
                ? Symbols.cancel_rounded
                : Symbols.cloud_download_rounded,
            size: 18.r,
            color: scheme.primary,
          ),
          SizedBox(width: 10.r),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sync.sourceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    SizedBox(width: 8.r),
                    Text(
                      _statusText(context),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6.r),
                if (preparing || downloadFor == null || sync.activeRoms.isEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4.r),
                    child: LinearProgressIndicator(
                      // The enumeration pass has no meaningful denominator
                      // until the server reports a total, so it runs
                      // indeterminate.
                      value: preparing ? null : _fraction,
                      minHeight: 4.r,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: scheme.primary,
                    ),
                  )
                else
                  ..._fileRows(theme, scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One thin bar per transfer in flight (the queue drains a few at a time):
  /// the file's name, its own percentage, and its own bytes. The header line
  /// above keeps the whole-queue count, so the two answer different questions
  /// — how far this file is, and how far the sync is.
  List<Widget> _fileRows(ThemeData theme, ColorScheme scheme) {
    final rows = <Widget>[];
    for (final rom in sync.activeRoms) {
      final download = downloadFor!(rom.id);
      final fraction = download == null
          ? null
          : rommFileFraction(
              received: download.received,
              total: download.total,
            );
      final percent = fraction == null ? '' : '${(fraction * 100).round()}%';
      if (rows.isNotEmpty) rows.add(SizedBox(height: 4.r));
      rows.add(
        Row(
          children: [
            Expanded(
              child: Text(
                rom.fsName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (percent.isNotEmpty) ...[
              SizedBox(width: 8.r),
              Text(
                percent,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
      rows.add(SizedBox(height: 2.r));
      rows.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(4.r),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4.r,
            backgroundColor: scheme.surfaceContainerHighest,
            color: scheme.primary,
          ),
        ),
      );
    }
    return rows;
  }

  /// Whole-queue progress by ROM count, used while nothing is in flight or no
  /// tracker lookup was supplied: RomM reports sizes per ROM, but a byte bar
  /// across the queue would stall through a single large disc image and then
  /// jump, which reads as a hang.
  double? get _fraction {
    if (sync.total <= 0) return null;
    return (sync.finished / sync.total).clamp(0.0, 1.0);
  }

  String _statusText(BuildContext context) {
    if (sync.cancelRequested) {
      return AppLocale.rommSyncCancelling.getString(context);
    }
    // The confirmation sits behind its own dialog, so the band keeps saying
    // "Preparing…" through it rather than flashing a state of its own.
    if (sync.phase != RommBulkSyncPhase.downloading) {
      final found = sync.enumerated;
      final preparing = AppLocale.rommSyncPreparing.getString(context);
      return found > 0 ? '$preparing $found' : preparing;
    }
    final counts = '${sync.finished}/${sync.total}';
    if (sync.totalBytes <= 0) return counts;
    return '$counts · ${rommFormatBytes(sync.doneBytes)} / '
        '${rommFormatBytes(sync.totalBytes)}';
  }
}
