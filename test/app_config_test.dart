import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/app_config.dart';

void main() {
  group('AppConfig', () {
    test('should have default auth base URL', () {
      expect(AppConfig.authBaseUrl, 'https://auth.neosync.cloud');
    });

    test('should have default neoSync base URL', () {
      expect(AppConfig.neoSyncBaseUrl, 'https://sync.neosync.cloud');
    });

    test('should have default billing base URL', () {
      expect(AppConfig.billingBaseUrl, 'https://billing.neosync.cloud');
    });

    test('should have default notify base URL', () {
      expect(AppConfig.notifyBaseUrl, 'ws://notify.neosync.cloud/ws');
    });
  });

  // Pins where the app looks for its own updates, so a fork build never asks
  // upstream.
  group('AppConfig update channels', () {
    // Fails for anyone running the tests with NEOSTATION_GITHUB_REPO defined:
    // it pins the default, which is what a plain build uses.
    test('defaults to this fork', () {
      expect(AppConfig.githubRepository, 'jonstump/neostation-frontend');
    });

    test('the release check asks the configured repository', () {
      expect(
        AppConfig.latestReleaseApiUrl,
        'https://api.github.com/repos/jonstump/neostation-frontend/releases/latest',
      );
    });

    test('the systems channel reads the configured repository and branch', () {
      expect(AppConfig.systemsBranch, 'main');
      expect(
        AppConfig.systemsManifestUrl,
        'https://raw.githubusercontent.com/jonstump/neostation-frontend/main/assets/manifest.json',
      );
      expect(
        AppConfig.systemsRawBaseUrl,
        'https://raw.githubusercontent.com/jonstump/neostation-frontend/main/assets/systems',
      );
      expect(
        AppConfig.systemsContentsApiUrl,
        'https://api.github.com/repos/jonstump/neostation-frontend/contents/assets/systems',
      );
    });

    // The services must take their URLs from AppConfig, and each constant must
    // take the RIGHT member: pointing the manifest URL at the raw-base member
    // would still compile and still look like a repository URL. A hard-coded
    // repository in either file would silently send a fork build back to
    // upstream, which is the bug this configuration exists to prevent.
    const declarations = {
      'lib/services/update_service.dart': [
        'static const String _githubApiUrl = AppConfig.latestReleaseApiUrl;',
      ],
      'lib/services/systems_update_service.dart': [
        'const _manifestUrl = AppConfig.systemsManifestUrl;',
        'const _baseRawUrl = AppConfig.systemsRawBaseUrl;',
        'const _githubApiUrl = AppConfig.systemsContentsApiUrl;',
      ],
    };
    declarations.forEach((file, expected) {
      test('$file takes each URL from the right AppConfig member', () {
        final source = File(file).readAsStringSync();
        for (final declaration in expected) {
          expect(source, contains(declaration));
        }
        expect(source, isNot(contains('misobadev')));
        expect(source, isNot(contains('api.github.com/repos/')));
        expect(source, isNot(contains('raw.githubusercontent.com')));
      });
    });
  });
}
