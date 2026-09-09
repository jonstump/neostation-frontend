import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/collection_model.dart';
import 'package:neostation/screens/collections_screen/collection_cards.dart';
import 'package:neostation/screens/collections_screen/collection_menu_layout.dart';
import 'package:neostation/services/romm/romm_collection_mirror.dart';
import 'package:neostation/utils/romm_collection_sync_message.dart';

/// The user-facing pieces of collection mirroring that are pure: the outcome
/// sentence chosen from a mirror summary, the per-collection menu layout, the
/// card badge, and the six `AppLocale` keys in all twelve languages.

// Governing: ADR-0009 (mirror synced RomM collections), SPEC-0009 REQ "Sync Dialog And Outcome", REQ "Mirrored Collections In The Browser", REQ "Localized User-Facing Text"

const _allLanguages = {
  'en': AppLocale.en,
  'es': AppLocale.es,
  'ru': AppLocale.ru,
  'zh': AppLocale.zh,
  'zh_Hant': AppLocale.zhHant,
  'pt': AppLocale.pt,
  'fr': AppLocale.fr,
  'de': AppLocale.de,
  'it': AppLocale.it,
  'id': AppLocale.id,
  'ja': AppLocale.ja,
  'ko': AppLocale.ko,
};

const _newKeys = {
  AppLocale.rommSyncConfirmCollection,
  AppLocale.rommSyncOutcomeCollection,
  AppLocale.rommSyncOutcomeCollectionFailed,
  AppLocale.collectionRommMirrored,
  AppLocale.collectionUnlinkRomm,
  AppLocale.collectionUnlinkRommConfirm,
};

String _en(String key) => AppLocale.en[key] as String;

void main() {
  group('rommCollectionOutcomeMessage', () {
    test('no mirror run says nothing', () {
      expect(rommCollectionOutcomeMessage(null, name: 'Best of SNES'), isNull);
    });

    test('a created collection reports its member count', () {
      final message = rommCollectionOutcomeMessage(
        const RommCollectionMirrorSummary(
          collectionId: 'local-1',
          created: true,
          added: 6,
        ),
        name: 'Best of SNES',
      );
      expect(message, isNotNull);
      expect(message!.key, AppLocale.rommSyncOutcomeCollection);
      expect(message.placeholders, {'name': 'Best of SNES', 'count': '6'});
      expect(message.format(_en), 'Collection "Best of SNES": 6 games');
    });

    test('an updated collection counts added plus kept, not removed', () {
      final message = rommCollectionOutcomeMessage(
        const RommCollectionMirrorSummary(
          collectionId: 'local-1',
          added: 1,
          kept: 3,
          removed: 2,
          unresolved: 4,
        ),
        name: 'Best of SNES',
      );
      expect(message!.key, AppLocale.rommSyncOutcomeCollection);
      expect(message.placeholders['count'], '4');
    });

    test('a failed run says the collection could not be updated', () {
      final message = rommCollectionOutcomeMessage(
        const RommCollectionMirrorSummary(
          collectionId: 'local-1',
          failed: true,
          error: 'timeout',
        ),
        name: 'Best of SNES',
      );
      expect(message!.key, AppLocale.rommSyncOutcomeCollectionFailed);
      expect(message.placeholders, {'name': 'Best of SNES'});
      expect(
        message.format(_en),
        'Collection "Best of SNES" could not be updated',
      );
    });

    test('a run that stopped before writing says nothing', () {
      final message = rommCollectionOutcomeMessage(
        const RommCollectionMirrorSummary(
          collectionId: 'local-1',
          cancelled: true,
        ),
        name: 'Best of SNES',
      );
      expect(message, isNull);
    });

    test('every outcome resolves without placeholders in every language', () {
      final summaries = [
        const RommCollectionMirrorSummary(collectionId: 'x', created: true),
        const RommCollectionMirrorSummary(collectionId: 'x', kept: 2),
        const RommCollectionMirrorSummary(collectionId: 'x', failed: true),
      ];
      for (final entry in _allLanguages.entries) {
        for (final summary in summaries) {
          final message = rommCollectionOutcomeMessage(summary, name: 'N');
          final text = message!.format((k) => entry.value[k] as String);
          expect(text, isNotEmpty, reason: entry.key);
          expect(text, isNot(contains('{')), reason: entry.key);
        }
      }
    });
  });

  group('localized keys', () {
    test('every new key has a value in every language', () {
      for (final entry in _allLanguages.entries) {
        for (final key in _newKeys) {
          expect(
            entry.value[key],
            isA<String>().having((s) => s.isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
        }
      }
    });

    test('the placeholders survive translation', () {
      for (final entry in _allLanguages.entries) {
        final maps = entry.value;
        expect(
          maps[AppLocale.rommSyncConfirmCollection],
          contains('{name}'),
          reason: entry.key,
        );
        expect(
          maps[AppLocale.rommSyncOutcomeCollection],
          allOf(contains('{name}'), contains('{count}')),
          reason: entry.key,
        );
        expect(
          maps[AppLocale.rommSyncOutcomeCollectionFailed],
          contains('{name}'),
          reason: entry.key,
        );
      }
    });
  });

  group('collectionMenuIds', () {
    const base = [
      kCollectionMenuRename,
      kCollectionMenuChangeImage,
      kCollectionMenuDelete,
      kCollectionMenuViewMode,
    ];

    test('an ordinary collection has no unlink entry', () {
      expect(collectionMenuIds(hasImage: false, isRommMirror: false), base);
      expect(
        collectionMenuIds(hasImage: true, isRommMirror: false),
        contains(kCollectionMenuRemoveImage),
      );
      expect(
        collectionMenuIds(hasImage: true, isRommMirror: false),
        isNot(contains(kCollectionMenuUnlinkRomm)),
      );
    });

    test(
      'a mirrored collection gets unlink after delete, before view mode',
      () {
        final ids = collectionMenuIds(hasImage: false, isRommMirror: true);
        expect(ids, [
          kCollectionMenuRename,
          kCollectionMenuChangeImage,
          kCollectionMenuDelete,
          kCollectionMenuUnlinkRomm,
          kCollectionMenuViewMode,
        ]);
        // The entries above it keep their positions.
        for (var i = 0; i < 3; i++) {
          expect(ids[i], base[i]);
        }
      },
    );

    test('unlink follows the remove-image entry when there is artwork', () {
      final ids = collectionMenuIds(hasImage: true, isRommMirror: true);
      expect(
        ids.indexOf(kCollectionMenuUnlinkRomm),
        ids.indexOf(kCollectionMenuDelete) + 1,
      );
      expect(ids.last, kCollectionMenuViewMode);
    });
  });

  group('collectionToSystemInfo badge', () {
    const mirrored = CollectionModel(
      id: 'c1',
      name: 'Best of SNES',
      rommServerUrl: 'https://romm.local',
      rommCollectionId: '12',
    );
    const plain = CollectionModel(id: 'c2', name: 'Mine');

    test('a mirrored collection carries the RomM glyph and its label', () {
      final info = collectionToSystemInfo(
        mirrored,
        imageVersion: 0,
        rommMirroredLabel: 'Synced from RomM',
      );
      expect(info.badgeIcon, kRommMirrorGlyph);
      expect(info.badgeLabel, 'Synced from RomM');
    });

    test('an ordinary collection has no badge', () {
      final info = collectionToSystemInfo(
        plain,
        imageVersion: 0,
        rommMirroredLabel: 'Synced from RomM',
      );
      expect(info.badgeIcon, isNull);
      expect(info.badgeLabel, isNull);
    });

    test('without a label the glyph is not drawn', () {
      final info = collectionToSystemInfo(mirrored, imageVersion: 0);
      expect(info.badgeIcon, isNull);
    });
  });

  // ── ADR-0015: the push side of the same surfaces ──────────────────────────
  // Governing: ADR-0015 (collections push), SPEC-0015 REQ "Push Action", REQ "Origin Badge", REQ "Origin Column", REQ "Localized User-Facing Text"

  group('collectionMenuIds with a pushable server', () {
    test('an unlinked collection gets push after delete while connected', () {
      final ids = collectionMenuIds(
        hasImage: false,
        isRommMirror: false,
        canPushToRomm: true,
      );
      expect(ids, [
        kCollectionMenuRename,
        kCollectionMenuChangeImage,
        kCollectionMenuDelete,
        kCollectionMenuPushRomm,
        kCollectionMenuViewMode,
      ]);
      expect(ids, isNot(contains(kCollectionMenuUnlinkRomm)));
    });

    test('no push without a server that may write', () {
      expect(
        collectionMenuIds(hasImage: true, isRommMirror: false),
        isNot(contains(kCollectionMenuPushRomm)),
      );
      expect(
        collectionMenuIds(
          hasImage: true,
          isRommMirror: false,
          canPushToRomm: false,
        ),
        isNot(contains(kCollectionMenuPushRomm)),
      );
    });

    test('a mirror is never offered push, even while connected', () {
      final ids = collectionMenuIds(
        hasImage: false,
        isRommMirror: true,
        canPushToRomm: true,
      );
      expect(ids, isNot(contains(kCollectionMenuPushRomm)));
      expect(ids, contains(kCollectionMenuUnlinkRomm));
    });

    test('a pushed collection gets unlink in the same slot, never push', () {
      final ids = collectionMenuIds(
        hasImage: true,
        isRommMirror: true,
        isPushedToRomm: true,
        canPushToRomm: true,
      );
      expect(ids, [
        kCollectionMenuRename,
        kCollectionMenuChangeImage,
        kCollectionMenuRemoveImage,
        kCollectionMenuDelete,
        kCollectionMenuUnlinkRomm,
        kCollectionMenuViewMode,
      ]);
      // The pushed flag alone is enough: the model's isRommMirror also reads
      // true for a pushed collection, but the layout must not depend on it.
      expect(
        collectionMenuIds(
          hasImage: false,
          isRommMirror: false,
          isPushedToRomm: true,
          canPushToRomm: true,
        ),
        allOf(
          contains(kCollectionMenuUnlinkRomm),
          isNot(contains(kCollectionMenuPushRomm)),
        ),
      );
    });

    test('the entries above the RomM slot keep their positions', () {
      final withPush = collectionMenuIds(
        hasImage: true,
        isRommMirror: false,
        canPushToRomm: true,
      );
      final without = collectionMenuIds(hasImage: true, isRommMirror: false);
      expect(withPush.sublist(0, 4), without.sublist(0, 4));
      expect(withPush.last, kCollectionMenuViewMode);
    });
  });

  group('rommCollectionOutcomeMessage for a pushed collection', () {
    test('a mirror run that declined a local-origin collection says so', () {
      final message = rommCollectionOutcomeMessage(
        const RommCollectionMirrorSummary(
          collectionId: 'local-1',
          skippedLocalOrigin: true,
        ),
        name: 'Best of SNES',
      );
      expect(message, isNotNull);
      expect(message!.key, AppLocale.rommSyncOutcomeCollectionManagedHere);
      expect(message.placeholders, {'name': 'Best of SNES'});
      expect(
        message.format(_en),
        'Collection "Best of SNES" is managed from this device and was not '
        'updated from RomM',
      );
    });

    test('the skip line resolves in every language', () {
      for (final entry in _allLanguages.entries) {
        final message = rommCollectionOutcomeMessage(
          const RommCollectionMirrorSummary(
            collectionId: 'x',
            skippedLocalOrigin: true,
          ),
          name: 'N',
        );
        final text = message!.format((k) => entry.value[k] as String);
        expect(text, isNotEmpty, reason: entry.key);
        expect(text, isNot(contains('{')), reason: entry.key);
      }
    });
  });

  group('collectionToSystemInfo pushed badge', () {
    const pushed = CollectionModel(
      id: 'c3',
      name: 'Mine, on RomM',
      rommServerUrl: 'https://romm.local',
      rommCollectionId: '77',
      rommOrigin: CollectionModel.originLocal,
    );
    const mirrored = CollectionModel(
      id: 'c1',
      name: 'Best of SNES',
      rommServerUrl: 'https://romm.local',
      rommCollectionId: '12',
      rommOrigin: CollectionModel.originRomm,
    );

    test('a pushed collection carries its own glyph and label', () {
      final info = collectionToSystemInfo(
        pushed,
        imageVersion: 0,
        rommMirroredLabel: 'Synced from RomM',
        rommPushedLabel: 'Pushed to RomM',
      );
      expect(info.badgeIcon, kRommPushedGlyph);
      expect(info.badgeLabel, 'Pushed to RomM');
      expect(kRommPushedGlyph, isNot(kRommMirrorGlyph));
    });

    test('a mirror keeps the mirror glyph when both labels are given', () {
      final info = collectionToSystemInfo(
        mirrored,
        imageVersion: 0,
        rommMirroredLabel: 'Synced from RomM',
        rommPushedLabel: 'Pushed to RomM',
      );
      expect(info.badgeIcon, kRommMirrorGlyph);
      expect(info.badgeLabel, 'Synced from RomM');
    });

    test('a pushed collection never falls back to the mirror glyph', () {
      // Only the mirror label given: the pushed collection is linked, but
      // saying "synced from RomM" about it would be the wrong owner.
      final info = collectionToSystemInfo(
        pushed,
        imageVersion: 0,
        rommMirroredLabel: 'Synced from RomM',
      );
      expect(info.badgeIcon, isNull);
      expect(info.badgeLabel, isNull);
    });
  });

  group('push localized keys', () {
    const pushKeys = {
      AppLocale.collectionPushRomm,
      AppLocale.collectionRommPushed,
      AppLocale.collectionPushRommOutcome,
      AppLocale.collectionPushRommAlreadyExists,
      AppLocale.collectionPushRommDenied,
      AppLocale.collectionPushRommFailed,
      AppLocale.collectionDeleteRommTitle,
      AppLocale.collectionDeleteRommBody,
      AppLocale.collectionDeleteRommConfirm,
      AppLocale.collectionDeleteRommKeep,
      AppLocale.collectionUnlinkPushedConfirm,
      AppLocale.rommSyncOutcomeCollectionManagedHere,
      AppLocale.collectionPushRommMembersQueued,
    };

    test('every new key has a value in every language', () {
      for (final entry in _allLanguages.entries) {
        for (final key in pushKeys) {
          expect(
            entry.value[key],
            isA<String>().having((s) => s.isNotEmpty, 'non-empty', true),
            reason: '$key missing in ${entry.key}',
          );
        }
      }
    });

    test('the placeholders survive translation', () {
      for (final entry in _allLanguages.entries) {
        final maps = entry.value;
        expect(
          maps[AppLocale.collectionPushRommOutcome],
          allOf(
            contains('{name}'),
            contains('{pushed}'),
            contains('{unlinked}'),
          ),
          reason: entry.key,
        );
        for (final key in [
          AppLocale.collectionPushRommFailed,
          AppLocale.collectionDeleteRommBody,
          AppLocale.rommSyncOutcomeCollectionManagedHere,
          AppLocale.collectionPushRommMembersQueued,
        ]) {
          expect(maps[key], contains('{name}'), reason: '$key ${entry.key}');
        }
      }
    });

    // Scenario: push with unlinked members — "3 pushed, 2 not linked".
    test('the outcome reads the two counts', () {
      final text = _en(AppLocale.collectionPushRommOutcome)
          .replaceFirst('{name}', 'RPGs')
          .replaceFirst('{pushed}', '3')
          .replaceFirst('{unlinked}', '2');
      expect(text, '"RPGs" pushed to RomM: 3 pushed, 2 not linked');
    });
  });
}
