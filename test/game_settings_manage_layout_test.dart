import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/game_settings_manage_layout.dart';
import 'package:neostation/utils/enabled_index_nav.dart';

/// The Manage tab's row gating (SPEC-0005 "Per-Game Fetch Action") as a pure
/// function: the fetch row is appended at index 6 and enabled only when the
/// game is linked and RomM is connected, indices 0-5 keep their meaning and
/// their enable rules, and the D-pad fallback never strands on a row that
/// just disabled.

// Governing: ADR-0005 (RomM metadata source), SPEC-0005 REQ "Per-Game Fetch Action"

bool _enabled(
  int idx, {
  bool showCloudSync = true,
  bool rommConnected = true,
  bool hasRommLink = true,
}) => ManageTabLayout.isEnabled(
  idx,
  showCloudSync: showCloudSync,
  rommConnected: rommConnected,
  hasRommLink: hasRommLink,
);

void main() {
  group('ManageTabLayout indices', () {
    test('indices 0-5 are unchanged and fetch is appended at 6', () {
      expect(ManageTabLayout.cloudSync, 0);
      expect(ManageTabLayout.playTime, 1);
      expect(ManageTabLayout.hide, 2);
      expect(ManageTabLayout.delete, 3);
      expect(ManageTabLayout.linkRomm, 4);
      expect(ManageTabLayout.unlinkRomm, 5);
      expect(ManageTabLayout.fetchRommMetadata, 6);
      expect(ManageTabLayout.total, 7);
    });

    test('out-of-range indices are never enabled', () {
      expect(_enabled(-1), isFalse);
      expect(_enabled(ManageTabLayout.total), isFalse);
    });
  });

  group('fetch row gating', () {
    test('enabled only when linked and connected', () {
      const fetch = ManageTabLayout.fetchRommMetadata;
      expect(_enabled(fetch, rommConnected: true, hasRommLink: true), isTrue);
      expect(_enabled(fetch, rommConnected: false, hasRommLink: true), isFalse);
      expect(_enabled(fetch, rommConnected: true, hasRommLink: false), isFalse);
      expect(
        _enabled(fetch, rommConnected: false, hasRommLink: false),
        isFalse,
      );
    });

    test('does not depend on cloud sync', () {
      expect(
        _enabled(ManageTabLayout.fetchRommMetadata, showCloudSync: false),
        isTrue,
      );
    });
  });

  group('existing rows keep their rules', () {
    test('cloud sync follows the sync provider only', () {
      expect(_enabled(ManageTabLayout.cloudSync, showCloudSync: true), isTrue);
      expect(
        _enabled(ManageTabLayout.cloudSync, showCloudSync: false),
        isFalse,
      );
      expect(
        _enabled(
          ManageTabLayout.cloudSync,
          rommConnected: false,
          hasRommLink: false,
        ),
        isTrue,
      );
    });

    test('play time, hide, and delete are always enabled', () {
      for (final idx in [
        ManageTabLayout.playTime,
        ManageTabLayout.hide,
        ManageTabLayout.delete,
      ]) {
        expect(
          _enabled(
            idx,
            showCloudSync: false,
            rommConnected: false,
            hasRommLink: false,
          ),
          isTrue,
          reason: 'index $idx',
        );
      }
    });

    test('link needs a connection, not a row', () {
      const link = ManageTabLayout.linkRomm;
      expect(_enabled(link, rommConnected: true, hasRommLink: false), isTrue);
      expect(_enabled(link, rommConnected: false, hasRommLink: true), isFalse);
    });

    test('unlink needs a row, not a connection', () {
      const unlink = ManageTabLayout.unlinkRomm;
      expect(_enabled(unlink, rommConnected: false, hasRommLink: true), isTrue);
      expect(
        _enabled(unlink, rommConnected: true, hasRommLink: false),
        isFalse,
      );
    });
  });

  group('focus fallback when the fetch row disables', () {
    // Mirrors the tab's `_ensureSelectedIndexEnabled`: try the next enabled
    // row below, else fall back upward.
    int fallback(int selected, bool Function(int) isEnabled) {
      if (isEnabled(selected)) return selected;
      final next = nextEnabledIndex(selected, ManageTabLayout.total, isEnabled);
      return isEnabled(next) && next != selected
          ? next
          : previousEnabledIndex(selected, ManageTabLayout.total, isEnabled);
    }

    test('after an unlink, focus falls back to the link row', () {
      bool unlinked(int idx) =>
          _enabled(idx, rommConnected: true, hasRommLink: false);
      expect(
        fallback(ManageTabLayout.fetchRommMetadata, unlinked),
        ManageTabLayout.linkRomm,
      );
    });

    test('after a disconnect, focus falls back past link and unlink', () {
      bool disconnected(int idx) =>
          _enabled(idx, rommConnected: false, hasRommLink: false);
      expect(
        fallback(ManageTabLayout.fetchRommMetadata, disconnected),
        ManageTabLayout.delete,
      );
    });

    test('a disconnect with a row kept lands on unlink', () {
      bool disconnected(int idx) =>
          _enabled(idx, rommConnected: false, hasRommLink: true);
      expect(
        fallback(ManageTabLayout.fetchRommMetadata, disconnected),
        ManageTabLayout.unlinkRomm,
      );
    });

    test('the D-pad skips the disabled fetch row from unlink', () {
      bool disconnected(int idx) =>
          _enabled(idx, rommConnected: false, hasRommLink: true);
      expect(
        nextEnabledIndex(
          ManageTabLayout.unlinkRomm,
          ManageTabLayout.total,
          disconnected,
        ),
        ManageTabLayout.unlinkRomm,
      );
    });
  });
}
