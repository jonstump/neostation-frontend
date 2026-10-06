class AppConfig {
  /// Base URL for the authentication service.
  static const String authBaseUrl = 'https://auth.neosync.cloud';

  /// Base URL for the NeoSync cloud synchronization service.
  static const String neoSyncBaseUrl = 'https://sync.neosync.cloud';

  /// Base URL for the billing and subscription management service.
  static const String billingBaseUrl = 'https://billing.neosync.cloud';

  /// WebSocket endpoint for the real-time notification service.
  static const String notifyBaseUrl = 'ws://notify.neosync.cloud/ws';

  /// Base URL for the NeoAssets public catalog API (system art packs).
  ///
  /// The `/api/v1/packs` endpoints are public and need no token or account;
  /// the developer-only `/api/v1/scrape/*` endpoints are not used.
  static const String neoAssetsApiBaseUrl = 'https://api.neoassets.dev';

  /// CDN that serves the NeoAssets pack images.
  static const String neoAssetsCdnBaseUrl = 'https://cdn.neoassets.dev';

  /// The GitHub repository (`owner/name`) this build updates itself from.
  ///
  /// Both over-the-air channels read it: the app-release check in
  /// `UpdateService` and the systems/emulator definitions in
  /// `SystemsUpdateService`. It defaults to this fork. A build against another
  /// repository (for example upstream) overrides it at build time with
  /// `--dart-define=NEOSTATION_GITHUB_REPO=owner/name`.
  static const String githubRepository = String.fromEnvironment(
    'NEOSTATION_GITHUB_REPO',
    defaultValue: 'jonstump/neostation-frontend',
  );

  /// Branch of [githubRepository] the systems definitions are read from.
  static const String systemsBranch = 'main';

  /// GitHub Releases API endpoint for the latest published release of
  /// [githubRepository]. Drafts are never returned by `releases/latest`.
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/$githubRepository/releases/latest';

  /// Raw URL of the systems manifest (`assets/manifest.json`).
  static const String systemsManifestUrl =
      'https://raw.githubusercontent.com/$githubRepository/$systemsBranch/assets/manifest.json';

  /// Raw base URL of the systems definition files (`assets/systems`).
  static const String systemsRawBaseUrl =
      'https://raw.githubusercontent.com/$githubRepository/$systemsBranch/assets/systems';

  /// GitHub Contents API URL listing the systems definition files.
  static const String systemsContentsApiUrl =
      'https://api.github.com/repos/$githubRepository/contents/assets/systems';
}
