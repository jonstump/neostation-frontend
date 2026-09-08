import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:neostation/utils/neo_sync_error_message.dart';

/// The sign-in screen renders `AppLocale.<key>.getString(context)` fed through
/// [NeoSyncLocalizedError.format]. `format` is the pure-Dart half of that, so
/// resolving the key against the locale map by hand gives the exact string the
/// user would see — measured, without a `BuildContext` or a widget pump.
String render(NeoSyncLocalizedError error, Map<String, dynamic> locale) =>
    error.format(locale[error.localeKey] as String);

void main() {
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

  group('what the sign-in screen actually renders', () {
    // Issue #195. `'Network error: $e'` interpolated the raw exception, and an
    // http ClientException carries the whole request URI. On an auth call that
    // is the likeliest place for a credential-bearing URL to surface, and this
    // string is drawn in the message box of `auth_form.dart` — shoulder-surfed,
    // screenshotted into a bug report, read aloud in a support thread.
    const token = 'EXAMPLEexample0123456789ABCDefgh';
    final authFailure = Exception(
      'ClientException with SocketException: Connection refused, '
      'uri=https://auth.neostation.app/login?token=$token&sid=SESSIONSECRET',
    );

    test('a network auth failure renders with no credential in it', () {
      final rendered = render(neoSyncNetworkError(authFailure), AppLocale.en);

      expect(rendered, isNot(contains(token)));
      expect(rendered, isNot(contains('SESSIONSECRET')));
      expect(rendered, contains('token=<redacted>'));
      expect(rendered, contains('sid=<redacted>'));
      // Still diagnosable: the host, the endpoint and the cause survive.
      expect(rendered, startsWith('Network error: '));
      expect(rendered, contains('auth.neostation.app/login'));
      expect(rendered, contains('Connection refused'));
    });

    test('the pre-fix wording really did put the token on screen', () {
      // What `auth_service.dart` used to hand `auth_form.dart` verbatim. Kept
      // as the measurement the fix is against, so nobody has to take the leak
      // on trust: the old shape carries the credential, the new one does not.
      final before = 'Network error: $authFailure';
      expect(before, contains(token));
      expect(before, contains('SESSIONSECRET'));

      final after = render(neoSyncNetworkError(authFailure), AppLocale.en);
      expect(after, isNot(contains(token)));
      expect(after, isNot(contains('SESSIONSECRET')));
    });

    test('a server error body is redacted before it is framed', () {
      // A body echoed back by an auth endpoint is a credential carrier.
      final rendered = render(
        neoSyncServerError(
          '{"error":"invalid session","authorization":"Bearer $token",'
          '"client_secret_id":"cs_live_abc"}',
          AppLocale.neoSyncLoginFailed,
        ),
        AppLocale.en,
      );

      expect(rendered, isNot(contains(token)));
      expect(rendered, isNot(contains('cs_live_abc')));
      expect(rendered, contains('invalid session'));
    });

    test('every rendered message is clean in every language', () {
      for (final entry in locales.entries) {
        final rendered = render(neoSyncNetworkError(authFailure), entry.value);
        expect(rendered, isNot(contains(token)), reason: entry.key);
        expect(rendered, isNot(contains('SESSIONSECRET')), reason: entry.key);
        expect(rendered, contains(redactedPlaceholder), reason: entry.key);
      }
    });
  });

  group('NeoSyncLocalizedError', () {
    test('a server that sent no error text falls back to our own sentence', () {
      final error = neoSyncServerError(null, AppLocale.neoSyncLoginFailed);
      expect(error.localeKey, AppLocale.neoSyncLoginFailed);
      expect(error.detail, isNull);
      expect(render(error, AppLocale.en), 'Login failed');
      expect(render(error, AppLocale.ja), 'ログインに失敗しました');
    });

    test('a blank server error text is treated as none at all', () {
      final error = neoSyncServerError('   ', AppLocale.neoSyncPlansFailed);
      expect(error.localeKey, AppLocale.neoSyncPlansFailed);
      expect(error.detail, isNull);
    });

    test('format leaves a placeholder-free sentence alone', () {
      const error = NeoSyncLocalizedError(AppLocale.neoSyncLoginFailed);
      expect(error.format('Login failed'), 'Login failed');
    });

    test('a result map carries both wordings side by side', () {
      // The English `message` stays in the map as the log string and as the
      // classification input (`contains('email not verified')`), which is why
      // `neoSyncResultMessage` has to prefer the localized entry over it.
      final result = <String, dynamic>{
        'success': false,
        'message': 'Network error: raw',
        kNeoSyncLocalizedError: const NeoSyncLocalizedError(
          AppLocale.neoSyncLoginFailed,
        ),
      };
      expect(result[kNeoSyncLocalizedError], isA<NeoSyncLocalizedError>());
      expect(result['message'], 'Network error: raw');
    });
  });

  group('the translations keep their placeholder', () {
    for (final entry in locales.entries) {
      test('${entry.key} keeps {error} in both frames', () {
        for (final key in [
          AppLocale.neoSyncNetworkError,
          AppLocale.neoSyncServerError,
        ]) {
          expect(
            entry.value[key] as String,
            contains('{error}'),
            reason: '$key in app_locale_${entry.key}.dart',
          );
        }
      });
    }
  });
}
