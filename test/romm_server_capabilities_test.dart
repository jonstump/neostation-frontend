import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_server_capabilities.dart';

/// The capability value object and the one feature-threshold table every RomM
/// version gate consults: parsing must survive anything a server or a reverse
/// proxy puts on the wire, ordering must put a prerelease below its release,
/// and `supports` must have exactly three outcomes with `unknown` never
/// gating.
///
/// Governing: ADR-0010 (RomM heartbeat capability probe), SPEC-0010 REQ
/// "Capability Value Object", REQ "Feature Threshold Table"
void main() {
  group('RommServerVersion.parse', () {
    test('plain major.minor.patch', () {
      expect(
        RommServerVersion.parse('5.2.0'),
        const RommServerVersion(5, 2, 0),
      );
    });

    test('tolerates a v prefix', () {
      expect(
        RommServerVersion.parse('v4.5.0'),
        const RommServerVersion(4, 5, 0),
      );
      expect(
        RommServerVersion.parse('V4.5.0'),
        const RommServerVersion(4, 5, 0),
      );
    });

    test('surrounding whitespace', () {
      expect(
        RommServerVersion.parse('  4.8.0  '),
        const RommServerVersion(4, 8, 0),
      );
    });

    test('a prerelease tag is kept without its dash', () {
      final v = RommServerVersion.parse('v4.4.1-beta.2');
      expect(v, isNotNull);
      expect(v!.major, 4);
      expect(v.minor, 4);
      expect(v.patch, 1);
      expect(v.prerelease, 'beta.2');
      expect(v.isPrerelease, isTrue);
    });

    test('build metadata is discarded', () {
      expect(
        RommServerVersion.parse('4.8.0+sha.abc123'),
        const RommServerVersion(4, 8, 0),
      );
      expect(
        RommServerVersion.parse('4.8.0-rc.1+sha.abc'),
        const RommServerVersion(4, 8, 0, prerelease: 'rc.1'),
      );
    });

    test('missing components default to zero', () {
      expect(RommServerVersion.parse('4'), const RommServerVersion(4, 0, 0));
      expect(RommServerVersion.parse('4.8'), const RommServerVersion(4, 8, 0));
    });

    test('garbage yields null rather than 0.0.0', () {
      for (final raw in <String?>[
        null,
        '',
        '   ',
        'latest',
        'v',
        '4.x.0',
        '1.2.3.4',
        'deadbeef',
        '-1.0.0',
      ]) {
        expect(
          RommServerVersion.parse(raw),
          isNull,
          reason: 'parse(${raw ?? 'null'})',
        );
      }
    });

    test('toString round-trips', () {
      expect(const RommServerVersion(4, 8, 0).toString(), '4.8.0');
      expect(
        const RommServerVersion(4, 8, 0, prerelease: 'beta.1').toString(),
        '4.8.0-beta.1',
      );
    });
  });

  group('RommServerVersion ordering', () {
    test('major, minor and patch in that order', () {
      final sorted = [
        const RommServerVersion(4, 8, 0),
        const RommServerVersion(5, 0, 0),
        const RommServerVersion(4, 5, 0),
        const RommServerVersion(4, 5, 3),
      ]..sort();
      expect(sorted.map((v) => v.toString()).toList(), [
        '4.5.0',
        '4.5.3',
        '4.8.0',
        '5.0.0',
      ]);
    });

    test('a prerelease sorts below its release', () {
      expect(
        const RommServerVersion(
          4,
          8,
          0,
          prerelease: 'beta.1',
        ).compareTo(const RommServerVersion(4, 8, 0)),
        lessThan(0),
      );
      expect(
        const RommServerVersion(4, 8, 0) <
            const RommServerVersion(4, 8, 0, prerelease: 'beta.1'),
        isFalse,
      );
    });

    test('numeric prerelease identifiers compare as numbers', () {
      expect(
        const RommServerVersion(
          4,
          8,
          0,
          prerelease: 'beta.2',
        ).compareTo(const RommServerVersion(4, 8, 0, prerelease: 'beta.10')),
        lessThan(0),
      );
      expect(
        const RommServerVersion(
          4,
          8,
          0,
          prerelease: 'alpha',
        ).compareTo(const RommServerVersion(4, 8, 0, prerelease: 'beta')),
        lessThan(0),
      );
    });

    test('equality and hashCode cover the prerelease', () {
      expect(
        const RommServerVersion(4, 8, 0),
        isNot(const RommServerVersion(4, 8, 0, prerelease: 'rc.1')),
      );
      expect(
        const RommServerVersion(4, 8, 0).hashCode,
        const RommServerVersion(4, 8, 0).hashCode,
      );
    });
  });

  group('RommFeature threshold table', () {
    // Pinned: a silent bump here would gate (or ungate) a real endpoint.
    // Governing: SPEC-0010 REQ "Feature Threshold Table"
    test('every threshold is the release its endpoint was found in', () {
      // Each of these was checked against the rommapp/romm source at the
      // release tags either side of it — see the citation on each entry. A
      // silent bump here would gate (or ungate) a real endpoint.
      // Governing: SPEC-0010 REQ "Feature Threshold Table"
      expect(
        RommFeature.values,
        hasLength(8),
        reason: 'a new entry needs a pin',
      );
      expect(
        // backend/endpoints/roms/upload.py is absent at 4.7.0 (whose rom.py
        // has only the single-shot POST /api/roms) and declares the four
        // session routes at 4.8.0.
        // Governing: ADR-0014 (chunked ROM upload), SPEC-0014 REQ "Chunked Upload Session"
        RommFeature.romUpload.minVersion,
        const RommServerVersion(4, 8, 0),
      );
      expect(
        RommFeature.playSessions.minVersion,
        // Not 4.8.0: play_sessions.py and models/play_session.py are absent
        // from the 4.8.0 and 4.8.1 trees (issue #136).
        const RommServerVersion(4, 9, 0),
      );
      expect(
        RommFeature.clientTokenExchange.minVersion,
        const RommServerVersion(4, 8, 0),
      );
      expect(
        RommFeature.romLookupByHash.minVersion,
        const RommServerVersion(4, 5, 0),
      );
      expect(
        RommFeature.romPropsBareBody.minVersion,
        const RommServerVersion(4, 9, 0),
      );
      expect(
        RommFeature.collectionRomsAddRemove.minVersion,
        const RommServerVersion(4, 9, 0),
      );
      expect(
        RommFeature.screenshotGallery.minVersion,
        const RommServerVersion(5, 0, 0),
      );
      expect(
        RommFeature.randomRom.minVersion,
        const RommServerVersion(5, 2, 0),
      );
    });

    test('every feature carries a threshold', () {
      expect(RommFeature.values, isNotEmpty);
      for (final feature in RommFeature.values) {
        expect(feature.minVersion.major, greaterThan(0), reason: feature.name);
      }
    });
  });

  group('RommServerCapabilities.fromJson', () {
    test('a full body', () {
      final caps = RommServerCapabilities.fromJson(
        jsonDecode('''
        {
          "SYSTEM": {"VERSION": "5.2.0", "SHOW_SETUP_WIZARD": false},
          "METADATA_SOURCES": {
            "SS_API_ENABLED": true,
            "IGDB_API_ENABLED": false,
            "SS_DEV_CREDENTIALS_SET": true
          },
          "FILESYSTEM": {"FS_PLATFORMS": ["snes", "nes"]},
          "EMULATION": {"DISABLE_EMULATOR_JS": true},
          "FRONTEND": {"DISABLE_USERPASS_LOGIN": false},
          "TASKS": {
            "ENABLE_SCHEDULED_RESCAN": true,
            "SCHEDULED_RESCAN_CRON": "0 3 * * *"
          }
        }
        ''')
            as Map<String, dynamic>,
      );

      expect(caps.version, const RommServerVersion(5, 2, 0));
      expect(caps.metadataSources['SS_API_ENABLED'], isTrue);
      expect(caps.metadataSources['IGDB_API_ENABLED'], isFalse);
      expect(caps.passwordLoginDisabled, isFalse);
      expect(caps.fsPlatforms, ['snes', 'nes']);
      expect(caps.emulation['DISABLE_EMULATOR_JS'], isTrue);
      expect(caps.tasks['ENABLE_SCHEDULED_RESCAN'], isTrue);
      expect(
        caps.tasks.containsKey('SCHEDULED_RESCAN_CRON'),
        isFalse,
        reason: 'a cron string is not a flag',
      );
    });

    test('a sparse body with an unknown section', () {
      final caps = RommServerCapabilities.fromJson(
        jsonDecode('''
        {
          "SYSTEM": {"VERSION": "v4.4.1-beta.2"},
          "SOMETHING_NEW": {"WHATEVER": 42}
        }
        ''')
            as Map<String, dynamic>,
      );

      expect(
        caps.version,
        const RommServerVersion(4, 4, 1, prerelease: 'beta.2'),
      );
      expect(caps.metadataSources, isEmpty);
      expect(caps.tasks, isEmpty);
      expect(caps.emulation, isEmpty);
      expect(caps.fsPlatforms, isEmpty);
      expect(caps.passwordLoginDisabled, isFalse);
      expect(caps.fetchedAt, isA<DateTime>());
    });

    test('sections of the wrong shape do not throw', () {
      final caps = RommServerCapabilities.fromJson({
        'SYSTEM': 'not a map',
        'METADATA_SOURCES': <String>['also not a map'],
        'FILESYSTEM': {'FS_PLATFORMS': 'snes'},
        'FRONTEND': {'DISABLE_USERPASS_LOGIN': 'yes please'},
        'TASKS': null,
      });
      expect(caps.version, isNull);
      expect(caps.metadataSources, isEmpty);
      expect(caps.fsPlatforms, isEmpty);
      expect(caps.passwordLoginDisabled, isFalse);
    });

    test('an empty body parses to an empty capability set', () {
      final caps = RommServerCapabilities.fromJson(const {});
      expect(caps.version, isNull);
      for (final feature in RommFeature.values) {
        expect(caps.supports(feature), RommFeatureSupport.unknown);
      }
    });

    test('string and numeric booleans are coerced, others dropped', () {
      final caps = RommServerCapabilities.fromJson({
        'FRONTEND': {'DISABLE_USERPASS_LOGIN': 'TRUE'},
        'METADATA_SOURCES': {
          'A_ENABLED': 1,
          'B_ENABLED': 0,
          'C_ENABLED': 'false',
          'D_ENABLED': 'maybe',
          'E_ENABLED': 7,
        },
      });
      expect(caps.passwordLoginDisabled, isTrue);
      expect(caps.metadataSources['A_ENABLED'], isTrue);
      expect(caps.metadataSources['B_ENABLED'], isFalse);
      expect(caps.metadataSources['C_ENABLED'], isFalse);
      expect(caps.metadataSources.containsKey('D_ENABLED'), isFalse);
      expect(caps.metadataSources.containsKey('E_ENABLED'), isFalse);
    });
  });

  group('supports', () {
    RommServerCapabilities capsAt(String? version) =>
        RommServerCapabilities.fromJson({
          if (version != null) 'SYSTEM': {'VERSION': version},
        });

    test('at or above the threshold is supported', () {
      expect(
        capsAt('4.9.0').supports(RommFeature.playSessions),
        RommFeatureSupport.supported,
      );
      expect(
        capsAt('5.2.0').supports(RommFeature.playSessions),
        RommFeatureSupport.supported,
      );
      expect(
        capsAt('4.5.0').supports(RommFeature.romLookupByHash),
        RommFeatureSupport.supported,
      );
    });

    test('below the threshold is unsupported', () {
      expect(
        capsAt('4.7.0').supports(RommFeature.playSessions),
        RommFeatureSupport.unsupported,
      );
      expect(
        capsAt('4.8.1').supports(RommFeature.playSessions),
        RommFeatureSupport.unsupported,
        reason: '4.8.x ships no play_sessions router (issue #136)',
      );
      expect(
        capsAt('4.7.9').supports(RommFeature.clientTokenExchange),
        RommFeatureSupport.unsupported,
      );
      expect(
        capsAt('4.4.9').supports(RommFeature.romLookupByHash),
        RommFeatureSupport.unsupported,
      );
    });

    test('a prerelease of the threshold counts as below it', () {
      expect(
        capsAt('4.9.0-beta.1').supports(RommFeature.playSessions),
        RommFeatureSupport.unsupported,
      );
      expect(
        capsAt('4.8.0-beta.1').supports(RommFeature.clientTokenExchange),
        RommFeatureSupport.unsupported,
      );
      expect(
        capsAt('4.8.0-beta.1').supports(RommFeature.romLookupByHash),
        RommFeatureSupport.supported,
        reason: 'still well past 4.5.0',
      );
    });

    test('no version at all is unknown for every feature', () {
      for (final caps in [capsAt(null), capsAt('nightly')]) {
        for (final feature in RommFeature.values) {
          expect(caps.supports(feature), RommFeatureSupport.unknown);
        }
      }
    });
  });
}
