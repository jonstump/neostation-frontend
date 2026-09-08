import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/romm_server_capabilities.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_repository.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/romm_service.dart';

import 'database_test_helper.dart';
import 'fake_credential_backends.dart';

/// [RommProvider.serverVersion] and [RommProvider.passwordLoginDisabled]
/// (SPEC-0010 "Provider Exposure And Re-Probe"): a restored session is
/// connected with the version unknown and sends nothing itself, the values
/// appear and listeners hear about it when a probe lands — including one on
/// an already-online connection, which the reachability state would not
/// announce — and a disconnect clears them. Plus the connect-screen strings
/// (REQ "Connect Screen Surfaces") in all twelve languages.
///
/// No network: the fake service answers the heartbeat however the test says,
/// through the same hooks the real service reports on.
///
/// Governing: ADR-0010 (heartbeat capability probe), SPEC-0010 REQ "Provider
/// Exposure And Re-Probe", REQ "Connect Screen Surfaces"

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

RommServerCapabilities _caps(String version, {bool passwordOff = false}) =>
    RommServerCapabilities.fromJson({
      'SYSTEM': {'VERSION': version},
      'FRONTEND': {'DISABLE_USERPASS_LOGIN': passwordOff},
    });

/// A service whose next heartbeat lands [pending] (or fails when null) and
/// reports it the way the real one does.
class _FakeService extends RommService {
  RommServerCapabilities? caps;
  RommServerCapabilities? pending;
  int heartbeats = 0;
  int forgets = 0;

  @override
  RommServerCapabilities? get capabilities => caps;

  @override
  Future<void> fetchHeartbeat({String? serverUrl}) async {
    heartbeats++;
    // The real probe is a request: nothing about it is synchronous.
    await Future<void>.delayed(Duration.zero);
    caps = pending;
    if (caps == null) return;
    onTransportSuccess?.call();
    onCapabilitiesChanged?.call();
  }

  @override
  void forgetServerState() {
    forgets++;
    caps = null;
  }
}

class _TestProvider extends RommProvider {
  final _FakeService fake = _FakeService();

  @override
  RommService get service => fake;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbHelper = DatabaseTestHelper();

  setUp(() async {
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
    final db = await dbHelper.setUp();
    // The restore drains the play-session outbox in the background.
    await db.execute(SqliteMigrations.createAppRommPlaySessionsTableSql);
  });

  tearDown(() async {
    CredentialStore.debugReset();
    await dbHelper.tearDown();
  });

  /// A provider restored from a saved API-key connection, the way the app
  /// starts.
  Future<_TestProvider> restored() async {
    await RommRepository.saveConfig(
      serverUrl: 'https://romm.local',
      username: 'jon',
      apiKey: 'rmm_${'ab' * 32}',
    );
    final provider = _TestProvider();
    await provider.initialize();
    return provider;
  }

  group('a restored session', () {
    // Governing: SPEC-0010 REQ "Provider Exposure And Re-Probe" — scenario
    // "Restored session"
    test('is connected with the version unknown, and sends nothing', () async {
      final provider = await restored();

      expect(provider.isConnected, isTrue);
      expect(provider.serverVersion, isNull);
      expect(provider.passwordLoginDisabled, isFalse, reason: 'unknown');
      expect(provider.fake.heartbeats, 0, reason: 'the restore is offline');

      provider.dispose();
    });

    // Governing: SPEC-0010 REQ "Provider Exposure And Re-Probe" — scenario
    // "Restored session, first authenticated request"
    test('exposes the version and notifies once the probe lands', () async {
      final provider = await restored();
      var notifications = 0;
      provider.addListener(() => notifications++);
      provider.fake.pending = _caps('5.2.0', passwordOff: true);

      await provider.reprobeNowForTesting();

      expect(provider.serverVersion, RommServerVersion.parse('5.2.0'));
      expect(provider.serverVersion.toString(), '5.2.0');
      expect(provider.passwordLoginDisabled, isTrue);
      expect(notifications, greaterThanOrEqualTo(1));

      provider.dispose();
    });

    test('a probe on an already-online connection still notifies', () async {
      final provider = await restored();
      provider.fake.pending = _caps('5.1.0');
      await provider.reprobeNowForTesting();
      expect(provider.reachability, RommReachability.online);
      var notifications = 0;
      provider.addListener(() => notifications++);

      // Reachability does not change here, so this notification can only
      // come from the capabilities hook.
      provider.fake.pending = _caps('5.2.0');
      await provider.fake.fetchHeartbeat();

      expect(provider.serverVersion, RommServerVersion.parse('5.2.0'));
      expect(notifications, 1);

      provider.dispose();
    });

    test('a failed probe leaves the values unknown', () async {
      final provider = await restored();
      provider.fake.pending = null;

      await provider.reprobeNowForTesting();

      expect(provider.serverVersion, isNull);
      expect(provider.passwordLoginDisabled, isFalse);

      provider.dispose();
    });
  });

  group('disconnect', () {
    test('clears the exposed values', () async {
      final provider = await restored();
      provider.fake.pending = _caps('5.2.0', passwordOff: true);
      await provider.reprobeNowForTesting();
      expect(provider.serverVersion, isNotNull);

      await provider.disconnect();

      expect(provider.serverVersion, isNull);
      expect(provider.passwordLoginDisabled, isFalse);
      expect(provider.fake.forgets, 1, reason: 'the service forgot the server');

      provider.dispose();
    });
  });

  group('dispose', () {
    test(
      'a probe that lands afterwards does not notify a dead provider',
      () async {
        final provider = await restored();
        provider.fake.pending = _caps('5.2.0');
        provider.dispose();

        // notifyListeners after dispose throws in debug builds; the hook must
        // not reach it.
        await provider.fake.fetchHeartbeat();

        expect(provider.fake.caps, isNotNull);
      },
    );
  });

  // Governing: SPEC-0010 REQ "Connect Screen Surfaces" — every string through
  // AppLocale with all twelve translations
  group('connect screen strings', () {
    test('the version line keeps its {version} placeholder everywhere', () {
      for (final entry in _allLanguages.entries) {
        final text = entry.value[AppLocale.rommServerVersionLine];
        expect(text, isA<String>(), reason: entry.key);
        expect(text, contains('{version}'), reason: entry.key);
        expect(
          (text as String).replaceFirst('{version}', '5.2.0'),
          isNot(contains('{')),
          reason: entry.key,
        );
      }
    });

    test('the password-login hint is translated everywhere', () {
      for (final entry in _allLanguages.entries) {
        final text = entry.value[AppLocale.rommPasswordLoginDisabledHint];
        expect(text, isA<String>(), reason: entry.key);
        expect(text, isNotEmpty, reason: entry.key);
        expect(text, isNot(contains('{')), reason: entry.key);
      }
    });
  });
}
