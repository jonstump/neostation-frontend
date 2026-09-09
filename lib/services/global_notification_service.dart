import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Notification types supported by the global notification center.
enum GlobalNotificationType { info, success, error }

/// One thing the user can do from a notification besides dismiss it: cancel
/// the upload it tracks, or link the files it just reported.
///
/// The bell renders [label] as a pill on the row; a tap on it, or A on the
/// highlighted row, calls [onPressed] and leaves the notification in place —
/// whoever owns the work updates the row with what the action did. The X
/// still dismisses the row as before.
// Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Upload Surfaces"
class GlobalNotificationAction {
  final String label;
  final VoidCallback onPressed;

  const GlobalNotificationAction({
    required this.label,
    required this.onPressed,
  });
}

/// Immutable data holder for a global notification.
class GlobalNotificationData {
  final String id;
  final String message;
  final String? title;
  final Uint8List? imageBytes;
  final IconData? icon;
  final GlobalNotificationType type;
  final double? progress;

  /// True while the notification tracks work that is still running.
  ///
  /// "Clear all" leaves these listed: clearing the bell is a request to tidy
  /// away messages, not to abandon a scrape, an import or a hashing pass that
  /// is still going. Dropping one would also silence it for good, because
  /// [GlobalNotificationService.update] is a no-op once the id is gone, so the
  /// progress bar (and the inline bar Tools renders from it) would never come
  /// back and the completion message would never arrive.
  final bool ongoing;

  /// An action offered on the row, or null for a plain notification. See
  /// [GlobalNotificationAction].
  final GlobalNotificationAction? action;

  const GlobalNotificationData({
    required this.id,
    required this.message,
    this.title,
    this.imageBytes,
    this.icon,
    required this.type,
    this.progress,
    this.ongoing = false,
    this.action,
  });
}

/// Application-wide notification center.
///
/// Notifications are kept in an ordered list exposed through [notifier]. The
/// header notification bell renders the list in a dropdown, including progress
/// bars. There is no floating overlay; every notification lives in the dropdown.
///
/// Notifications never auto-dismiss: they stay listed until the user dismisses
/// them, either individually or with the "Clear all" action in the dropdown.
/// "Clear all" skips notifications marked [GlobalNotificationData.ongoing] so
/// running work keeps reporting; the per-notification close button still
/// removes any single one, including an ongoing one.
class GlobalNotificationService {
  static final GlobalNotificationService _instance =
      GlobalNotificationService._internal();
  factory GlobalNotificationService() => _instance;
  GlobalNotificationService._internal();

  final ValueNotifier<List<GlobalNotificationData>> notifier = ValueNotifier(
    [],
  );

  /// Displays a notification. If a notification with the same [id] is already
  /// active, it is updated in place and moved to the end (most recent).
  void show({
    required String id,
    required String message,
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    GlobalNotificationType type = GlobalNotificationType.info,
    double? progress,
    bool ongoing = false,
    GlobalNotificationAction? action,
  }) {
    final current = notifier.value;
    final existingIndex = current.indexWhere((n) => n.id == id);
    final updated = GlobalNotificationData(
      id: id,
      message: message,
      title: title,
      imageBytes: imageBytes,
      icon: icon,
      type: type,
      progress: progress,
      ongoing: ongoing,
      action: action,
    );

    if (existingIndex == -1) {
      notifier.value = [...current, updated];
    } else {
      final copy = List<GlobalNotificationData>.from(current);
      copy.removeAt(existingIndex);
      copy.add(updated);
      notifier.value = copy;
    }
  }

  /// Updates an active notification only if its [id] exists.
  ///
  /// [ongoing], [progress] and [action] deliberately do not carry the current
  /// value over: the last update of a run is the completion message, and those
  /// call sites are the ones that would forget to clear a flag, a bar or a
  /// Cancel that outlived the work it cancels. Every update names the state it
  /// still wants — a running pass passes its fraction and `ongoing: true`
  /// together — and anything left unsaid is cleared.
  ///
  /// [progress] joined that rule late. It read `progress ?? existing.progress`,
  /// which made `progress: null` mean "keep the bar" rather than "clear it",
  /// so a summary row sat under a bar left full by a completed pass or frozen
  /// part-way by a cancel. Three runners were fixed one at a time (#224, #226,
  /// #227) by routing their terminal rows through [show] before the shape was
  /// recognised as the default being backwards: 32 of the 43 update call sites
  /// in `lib/` wanted the bar gone, and 11 pass a real fraction and are
  /// unaffected either way. Issue #228.
  ///
  /// [title], [imageBytes] and [icon] still fall back, and stay that way: they
  /// are identity rather than state, an update is not expected to restate who
  /// the row belongs to, and none of them can imply work is still running.
  void update({
    required String id,
    required String message,
    String? title,
    Uint8List? imageBytes,
    IconData? icon,
    GlobalNotificationType? type,
    double? progress,
    bool ongoing = false,
    GlobalNotificationAction? action,
  }) {
    final current = notifier.value;
    final index = current.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = current[index];

    notifier.value = [
      ...current.sublist(0, index),
      GlobalNotificationData(
        id: id,
        message: message,
        title: title ?? existing.title,
        imageBytes: imageBytes ?? existing.imageBytes,
        icon: icon ?? existing.icon,
        type: type ?? existing.type,
        // Not `?? existing.progress` — see the doc comment. Issue #228.
        progress: progress,
        ongoing: ongoing,
        action: action,
      ),
      ...current.sublist(index + 1),
    ];
  }

  /// Removes the notification with the given [id], or clears every notification
  /// that is not tracking running work when no [id] is provided.
  ///
  /// The blanket form is what "Clear all" calls, and it keeps
  /// [GlobalNotificationData.ongoing] entries: see that field for why removing
  /// one silences the task for the rest of the run.
  void dismiss([String? id]) {
    if (id == null) {
      notifier.value = notifier.value.where((n) => n.ongoing).toList();
      return;
    }

    notifier.value = notifier.value.where((n) => n.id != id).toList();
  }
}
