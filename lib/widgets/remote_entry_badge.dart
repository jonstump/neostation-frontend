import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../l10n/app_locale.dart';
import '../models/game_model.dart';
import '../providers/romm_provider.dart';
import '../utils/byte_size_format.dart';

/// What a card and its footer say about one entry of the unified library.
///
/// A local game is [local] whatever the RomM provider knows about it. A
/// remote entry is [remote] until a download tracker exists for its rom id,
/// [downloading] while that tracker transfers (and, at 100 percent, while the
/// settle rescan has yet to index the file — the entry is still remote until
/// the list reloads), and [failed] when the tracker ended in an error. A
/// cancelled tracker reads as [remote] again: the press that cancelled it is
/// the only thing that happened.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
enum RemoteEntryState { local, remote, downloading, failed }

/// The footer's primary action for a [RemoteEntryState]: what A does.
///
/// [wait] is the 100-percent gap between a finished transfer and the settle
/// rescan that turns the entry local — nothing to cancel, nothing to launch.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
enum RemoteEntryAction { play, download, cancel, retry, wait }

/// The state of [game] given the download tracker's [status] for its rom id
/// (null when no tracker exists). Pure: the same answer for every view.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
RemoteEntryState remoteEntryStateFor(
  GameModel game,
  RommDownloadStatus? status,
) {
  if (!game.isRemote) return RemoteEntryState.local;
  return switch (status) {
    RommDownloadStatus.downloading ||
    RommDownloadStatus.completed => RemoteEntryState.downloading,
    RommDownloadStatus.failed => RemoteEntryState.failed,
    RommDownloadStatus.cancelled || null => RemoteEntryState.remote,
  };
}

/// The footer's primary action for [state] given the tracker's [status]:
/// Play for a local game, Download for a remote one, Cancel while it
/// transfers, Retry after a failure, and [RemoteEntryAction.wait] once the
/// bytes are down but the file is not indexed yet.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
RemoteEntryAction remoteEntryActionFor(
  RemoteEntryState state, {
  RommDownloadStatus? status,
}) => switch (state) {
  RemoteEntryState.local => RemoteEntryAction.play,
  RemoteEntryState.remote => RemoteEntryAction.download,
  RemoteEntryState.downloading =>
    status == RommDownloadStatus.completed
        ? RemoteEntryAction.wait
        : RemoteEntryAction.cancel,
  RemoteEntryState.failed => RemoteEntryAction.retry,
};

/// The whole percent a card draws for [tracker], or null when there is no
/// figure (no tracker, or a transfer whose total the server did not send —
/// the indeterminate bar). A completed tracker is 100 whatever its byte
/// count, since the file is whole.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
int? remoteEntryPercent(RommDownload? tracker) {
  if (tracker == null) return null;
  if (tracker.status == RommDownloadStatus.completed) return 100;
  return RommProvider.renderedPercent(tracker.fraction);
}

/// The size line a remote entry's subtitle carries ("12.3 MB"), or null for
/// a local game or a catalog row the server sent no size for.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
String? remoteEntrySizeLabel(GameModel game) {
  if (!game.isRemote) return null;
  final bytes = game.remoteSizeBytes;
  if (bytes == null || bytes <= 0) return null;
  return formatByteSize(bytes);
}

/// The footer's button label for [action], in the footer's upper case.
///
/// PLAY keeps its own key (it is the one label that was translated as a
/// button); the rest reuse the plain words and upper-case them the way the
/// folder row's ENTER does.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
String remoteEntryActionLabel(
  BuildContext context,
  RemoteEntryAction action,
) => switch (action) {
  RemoteEntryAction.play => AppLocale.playButton.getString(context),
  RemoteEntryAction.download =>
    AppLocale.download.getString(context).toUpperCase(),
  RemoteEntryAction.cancel => AppLocale.cancel.getString(context).toUpperCase(),
  RemoteEntryAction.retry => AppLocale.retry.getString(context).toUpperCase(),
  RemoteEntryAction.wait =>
    AppLocale.rommDownloading.getString(context).toUpperCase(),
};

/// The download tracker's status for [game], watched so the caller rebuilds
/// when it changes state and not on every byte. Null for a local game, for a
/// remote entry with no tracker, and when no [RommProvider] is in scope (a
/// widget test hosting the footer alone).
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
RommDownloadStatus? watchRemoteDownloadStatus(
  BuildContext context,
  GameModel game,
) {
  final romId = game.rommRomId;
  if (romId == null || !game.isRemote) return null;
  try {
    return context.select<RommProvider, RommDownloadStatus?>(
      (provider) => provider.downloadFor(romId)?.status,
    );
  } on ProviderNotFoundException {
    return null;
  }
}

/// The tracker's status and rendered percent for [game], watched so a card's
/// overlay repaints when either moves and stays put between two chunks that
/// round to the same figure.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
(RommDownloadStatus?, int?) watchRemoteDownloadProgress(
  BuildContext context,
  GameModel game,
) {
  final romId = game.rommRomId;
  if (romId == null || !game.isRemote) return (null, null);
  try {
    return context.select<RommProvider, (RommDownloadStatus?, int?)>((
      provider,
    ) {
      final tracker = provider.downloadFor(romId);
      return (tracker?.status, remoteEntryPercent(tracker));
    });
  } on ProviderNotFoundException {
    return (null, null);
  }
}

/// The cloud-download mark a remote entry wears in the favourite/collection
/// badge family: the same dark disc the heart sits on, with the cloud glyph
/// the search screen uses for a ROM that lives on the server. Becomes a retry
/// mark when the entry's download failed. Draws nothing for a local game, so
/// a card can place it unconditionally.
///
/// [RemoteEntryBadge.inline] is the list row's bare-glyph variant, sized and
/// coloured like the collection and achievements marks beside it, with the
/// download percent after the glyph while a transfer runs.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
class RemoteEntryBadge extends StatelessWidget {
  final GameModel game;

  /// Diameter of the disc, in the caller's already-scaled units.
  final double size;

  /// Bare-glyph mode for list rows: no disc, [color] for the glyph.
  final bool inline;
  final Color? color;

  const RemoteEntryBadge({super.key, required this.game, required this.size})
    : inline = false,
      color = null;

  const RemoteEntryBadge.inline({
    super.key,
    required this.game,
    required this.size,
    required this.color,
  }) : inline = true;

  @override
  Widget build(BuildContext context) {
    if (!game.isRemote) return const SizedBox.shrink();
    final (status, percent) = watchRemoteDownloadProgress(context, game);
    final state = remoteEntryStateFor(game, status);
    final (icon, label) = switch (state) {
      RemoteEntryState.failed => (
        Symbols.refresh_rounded,
        AppLocale.rommRemoteRetryBadge.getString(context),
      ),
      RemoteEntryState.downloading => (
        Symbols.cloud_download_rounded,
        percent == null
            ? AppLocale.rommRemoteDownloadingIndeterminate.getString(context)
            : AppLocale.rommRemoteDownloadingBadge
                  .getString(context)
                  .replaceFirst('{percent}', '$percent'),
      ),
      _ => (
        Symbols.cloud_download_rounded,
        AppLocale.rommRemoteBadge.getString(context),
      ),
    };

    if (inline) {
      final glyphColor = state == RemoteEntryState.failed
          ? Theme.of(context).colorScheme.error
          : color;
      return Semantics(
        label: label,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: size, color: glyphColor),
            if (state == RemoteEntryState.downloading && percent != null) ...[
              SizedBox(width: 2.r),
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: size * 0.8,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Semantics(
      label: label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: size * 0.55,
          color: state == RemoteEntryState.failed
              ? Theme.of(context).colorScheme.error
              : Colors.white,
        ),
      ),
    );
  }
}

/// The progress strip along a card's bottom edge while its download runs:
/// the cloud glyph, a bar, and the percent — or an indeterminate bar with no
/// figure when the server sent no content length. The same band the scrape
/// progress draws, so the two read as one family. Draws nothing unless a
/// transfer is running or finished-but-unindexed, so a card can place it
/// unconditionally.
// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Remote Entry Presentation"
class RemoteDownloadOverlay extends StatelessWidget {
  final GameModel game;
  final double height;
  final double radius;
  final double iconSize;
  final double fontSize;
  final double gap;
  final double horizontalPadding;

  const RemoteDownloadOverlay({
    super.key,
    required this.game,
    required this.height,
    required this.radius,
    required this.iconSize,
    required this.fontSize,
    required this.gap,
    required this.horizontalPadding,
  });

  /// The grid card's band: the same metrics as its scrape strip.
  RemoteDownloadOverlay.grid({Key? key, required GameModel game})
    : this(
        key: key,
        game: game,
        height: 20.r,
        radius: 12.r,
        iconSize: 10.r,
        fontSize: 9.r,
        gap: 4.r,
        horizontalPadding: 8.r,
      );

  /// The carousel card's band: the same metrics as its scrape strip.
  RemoteDownloadOverlay.carousel({Key? key, required GameModel game})
    : this(
        key: key,
        game: game,
        height: 24.r,
        radius: 24.r,
        iconSize: 14.r,
        fontSize: 11.r,
        gap: 6.r,
        horizontalPadding: 12.r,
      );

  @override
  Widget build(BuildContext context) {
    if (!game.isRemote) return const SizedBox.shrink();
    final (status, percent) = watchRemoteDownloadProgress(context, game);
    if (remoteEntryStateFor(game, status) != RemoteEntryState.downloading) {
      return const SizedBox.shrink();
    }
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(radius)),
      ),
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        children: [
          Icon(
            Symbols.cloud_download_rounded,
            size: iconSize,
            color: Colors.white70,
          ),
          SizedBox(width: gap),
          Expanded(
            child: LinearProgressIndicator(
              value: percent == null ? null : percent / 100,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          if (percent != null) ...[
            SizedBox(width: gap),
            Text(
              '$percent%',
              style: TextStyle(
                color: Colors.white70,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
