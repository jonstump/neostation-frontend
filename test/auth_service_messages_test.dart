import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/neosync/auth_service.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:neostation/utils/neo_sync_error_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_credential_backends.dart';

/// Issue #200. `AuthService` handed `auth_form.dart` five hardcoded English
/// success sentences while four translated `AppLocale` keys sat with no caller.
/// Each success path is driven here against a scripted HTTP client and the
/// key it carries is read back — so a cleanup pass that sees those keys as
/// "unused" fails a test instead of deleting them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response json(int status, Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  AuthService service(Future<http.Response> Function(http.Request) handler) =>
      AuthService(client: MockClient(handler));

  /// The key the widget will resolve for [result], or null when the result
  /// carries no localized sentence at all.
  String? keyOf(Map<String, dynamic> result) =>
      (result[kNeoSyncLocalizedError] as NeoSyncLocalizedError?)?.localeKey;

  setUp(() {
    // `CredentialStore.read` falls through to the legacy SharedPreferences copy
    // when no backend holds the token, which the getProfile case relies on.
    SharedPreferences.setMockInitialValues({});
    CredentialStore.debugUseBackends(
      secure: MemoryBackend(),
      file: MemoryBackend(),
    );
  });

  tearDown(CredentialStore.debugReset);

  group('each success path carries an AppLocale key', () {
    test('register', () async {
      final result = await service(
        (_) async => json(201, {'id': 'u1'}),
      ).register('jon', 'jon@example.com', 'hunter2hunter2');

      expect(result['success'], isTrue);
      expect(keyOf(result), AppLocale.registrationSuccessCheckEmail);
    });

    test('login with a verified email', () async {
      final result = await service(
        (_) async => json(200, {
          'token': 'jwt',
          'user': {'id': 'u1', 'email_verified': true},
        }),
      ).login('jon@example.com', 'hunter2hunter2');

      expect(result['success'], isTrue);
      expect(result['emailVerified'], isTrue);
      expect(keyOf(result), AppLocale.loginSuccessful);
    });

    test('login with an unverified email', () async {
      final result = await service(
        (_) async => json(200, {
          'token': 'jwt',
          'user': {'id': 'u1', 'email_verified': false},
        }),
      ).login('jon@example.com', 'hunter2hunter2');

      expect(result['success'], isTrue);
      expect(result['emailVerified'], isFalse);
      expect(keyOf(result), AppLocale.neoSyncLoginSuccessfulEmailNotVerified);
    });

    test('verifyEmail', () async {
      final result = await service(
        (_) async => json(200, {}),
      ).verifyEmail('token');

      expect(keyOf(result), AppLocale.emailVerifiedSuccess);
    });

    test('resendVerificationEmail', () async {
      final result = await service(
        (_) async => json(200, {}),
      ).resendVerificationEmail('jon@example.com');

      expect(keyOf(result), AppLocale.neoSyncVerificationEmailSent);
    });

    test('forgotPassword', () async {
      final result = await service(
        (_) async => json(200, {}),
      ).forgotPassword('jon@example.com');

      expect(keyOf(result), AppLocale.neoSyncPasswordResetEmailSent);
    });

    test('resetPassword', () async {
      final result = await service(
        (_) async => json(200, {}),
      ).resetPassword('token', 'hunter2hunter2');

      expect(keyOf(result), AppLocale.passwordResetSuccess);
    });

    test('getProfile with no stored token', () async {
      final result = await service((_) async => json(200, {})).getProfile();

      expect(result['success'], isFalse);
      expect(keyOf(result), AppLocale.neoSyncNotAuthenticated);
    });
  });

  group('the server\'s own success text', () {
    // `data['message'] ?? 'Password reset successfully'` used to put the
    // server's English on screen ahead of the translated sentence. Now the
    // screen gets the `AppLocale` key and the server's wording survives only
    // in `message`, redacted, for the log.
    const token = 'EXAMPLEexample0123456789ABCDefgh';

    test('is not what the screen renders', () async {
      final result = await service(
        (_) async => json(200, {'message': 'Password has been reset.'}),
      ).resetPassword('token', 'hunter2hunter2');

      final localized = result[kNeoSyncLocalizedError] as NeoSyncLocalizedError;
      expect(localized.localeKey, AppLocale.passwordResetSuccess);
      expect(localized.detail, isNull);
      expect(
        localized.format(
          AppLocale.en[AppLocale.passwordResetSuccess] as String,
        ),
        'Password reset successfully! Please login with your new password.',
      );
      expect(result['message'], 'Password has been reset.');
    });

    test('is kept for the log, redacted', () async {
      final result = await service(
        (_) async => json(200, {
          'message':
              'Reset link consumed: '
              'https://auth.neostation.app/reset?token=$token',
        }),
      ).forgotPassword('jon@example.com');

      expect(keyOf(result), AppLocale.neoSyncPasswordResetEmailSent);
      final message = result['message'] as String;
      expect(message, isNot(contains(token)));
      expect(message, contains('token=$redactedPlaceholder'));
      expect(message, contains('Reset link consumed'));
    });

    test('falls back to our English diagnostic when absent or blank', () async {
      final absent = await service(
        (_) async => json(200, {}),
      ).forgotPassword('jon@example.com');
      final blank = await service(
        (_) async => json(200, {'message': '   '}),
      ).forgotPassword('jon@example.com');

      expect(absent['message'], 'Password reset email sent');
      expect(blank['message'], 'Password reset email sent');
    });
  });

  group('every key resolves in every language', () {
    const locales = <String, Map<String, dynamic>>{
      'en': AppLocale.en,
      'es': AppLocale.es,
      'pt': AppLocale.pt,
      'ru': AppLocale.ru,
      'zh': AppLocale.zh,
      'zh_Hant': AppLocale.zhHant,
      'fr': AppLocale.fr,
      'de': AppLocale.de,
      'it': AppLocale.it,
      'id': AppLocale.id,
      'ja': AppLocale.ja,
      'ko': AppLocale.ko,
    };
    const keys = [
      AppLocale.registrationSuccessCheckEmail,
      AppLocale.loginSuccessful,
      AppLocale.neoSyncLoginSuccessfulEmailNotVerified,
      AppLocale.emailVerifiedSuccess,
      AppLocale.neoSyncVerificationEmailSent,
      AppLocale.neoSyncPasswordResetEmailSent,
      AppLocale.passwordResetSuccess,
      AppLocale.neoSyncNotAuthenticated,
    ];

    for (final entry in locales.entries) {
      test(entry.key, () {
        for (final key in keys) {
          final value = entry.value[key];
          expect(value, isA<String>(), reason: key);
          expect((value as String).trim(), isNotEmpty, reason: key);
        }
      });
    }
  });
}
