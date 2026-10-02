import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:neostation/models/user.dart';
import 'package:neostation/services/credential_store.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/utils/app_config.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/log_redaction.dart';
import 'package:neostation/utils/neo_sync_error_message.dart';

/// Service responsible for managing user authentication and profile synchronization.
///
/// Handles registration, login, email verification, password recovery, and
/// session persistence. Where the token is kept is [CredentialStore]'s problem,
/// including the platforms whose secure storage cannot hold it.
/// What a [AuthService.restoreSession] attempt found.
enum SessionRestore {
  /// The server accepted the stored token: the user is signed in.
  live,

  /// Nothing could be asked. No network yet, an unreadable credential store,
  /// or a server error — the token is untouched and the attempt is worth
  /// repeating.
  unreachable,

  /// There is nothing to restore: no token is stored, or the server rejected
  /// the one that was.
  none,
}

class AuthService extends ChangeNotifier {
  /// [client] is the seam for tests: the success paths are pinned against a
  /// `MockClient` so the sentences they carry are measured, not reasoned.
  AuthService({http.Client? client}) : _client = client ?? http.Client();

  /// Storage key for the authentication JWT token.
  static const String _tokenKey = 'auth_token';

  static final _log = LoggerService.instance;

  final http.Client _client;

  /// How long the profile request may take before it counts as unreachable.
  /// `main` awaits [initialize], so an unbounded request on a handheld that
  /// powered on before its Wi-Fi associated would hold the whole app on the
  /// splash screen for as long as the socket took to give up.
  static const Duration _profileTimeout = Duration(seconds: 10);

  /// Background retry schedule for a session that could not be restored
  /// because nothing was reachable. Covers the cold-boot window in which a
  /// device running NeoStation as its launcher starts before the network:
  /// measured on an AYN Thor, Wi-Fi associated four and a half minutes after
  /// boot, so the schedule widens rather than repeating one short delay.
  /// Past the end of it, opening the tab and waking the device take over.
  static const List<Duration> _restoreRetryBackoff = [
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  /// HTTP client for the session reads. Null in the app, where the service
  /// uses [_client]; tests swap it between phases to take the network away
  /// and give it back.
  @visibleForTesting
  http.Client? httpClient;

  /// Guards against two overlapping retry loops (one from [initialize], one
  /// from a caller that retried by hand).
  bool _restoreRetryRunning = false;

  /// Bumped by [logout]. A profile request already in flight when the user
  /// signs out comes back with a 200 the server was right to send, and
  /// marking the session live on it would sign them back in with a token that
  /// no longer exists. Comparing the epoch the request started with costs
  /// nothing and closes that window.
  int _sessionEpoch = 0;

  /// Whether a valid user session is currently active.
  bool _isLoggedIn = false;

  /// Metadata for the currently authenticated user.
  User? _currentUser;

  bool get isLoggedIn => _isLoggedIn;
  User? get currentUser => _currentUser;

  /// Initializes the service by attempting to restore a previous session from
  /// storage, and keeps trying in the background while nothing is reachable.
  ///
  /// `main` awaits this, so only the first attempt is on the startup path; the
  /// retries are not. They exist because a device that powers on with
  /// NeoStation as its launcher reaches this line before Wi-Fi has associated.
  /// The token survived that (it always did), but nothing ever re-checked it,
  /// so the user stayed signed out — websocket included — until they typed
  /// their password again, however long the network had been back (issue
  /// #482).
  Future<void> initialize() async {
    final result = await restoreSession();
    if (result == SessionRestore.unreachable) {
      unawaited(_retryRestoreSession());
    }
  }

  /// Validates the stored token against the server and updates the session.
  ///
  /// Preserves the token on anything that is not an outright rejection: a
  /// network failure, an unreadable credential store (a cold boot can reach
  /// this before the database's volume is mounted) and a server error all
  /// leave the account alone, because treating any of them as "signed out"
  /// deletes a perfectly good session.
  Future<SessionRestore> restoreSession() async {
    try {
      final token = await CredentialStore.read(_tokenKey);
      if (token == null) {
        _isLoggedIn = false;
        _currentUser = null;
        notifyListeners();
        return SessionRestore.none;
      }

      final profileResult = await getProfile();
      if (profileResult['success'] == true) {
        // getProfile has already set _isLoggedIn and notified: a server that
        // answers the profile call has accepted the token.
        return SessionRestore.live;
      }

      if (profileResult['isNetworkError'] == true) {
        _log.i('AuthService: network unreachable. Token preserved.');
        return SessionRestore.unreachable;
      }

      final statusCode = profileResult['statusCode'];
      if (statusCode == 401 || statusCode == 403) {
        _log.w(
          'AuthService: Token invalid or expired ($statusCode). Clearing storage.',
        );
        await CredentialStore.delete(_tokenKey);
        _isLoggedIn = false;
        _currentUser = null;
        notifyListeners();
        return SessionRestore.none;
      }

      _log.i(
        'AuthService: Unexpected server error ($statusCode). Token preserved.',
      );
      return SessionRestore.unreachable;
    } catch (e) {
      // Includes an unreadable credential store, which is not a signed-out
      // user: change nothing and let the caller try again.
      _log.e('Error restoring the NeoSync session: $e');
      return SessionRestore.unreachable;
    }
  }

  Future<void> _retryRestoreSession() async {
    if (_restoreRetryRunning) return;
    _restoreRetryRunning = true;
    try {
      for (final delay in _restoreRetryBackoff) {
        await Future<void>.delayed(delay);
        final result = await restoreSession();
        if (result == SessionRestore.live) {
          _log.i('AuthService: session restored once the network came back');
          return;
        }
        if (result == SessionRestore.none) return;
        _log.i(
          'AuthService: nothing reachable yet; retrying the session restore',
        );
      }
    } finally {
      _restoreRetryRunning = false;
    }
  }

  /// Registers a new user account with the remote authentication server.
  ///
  /// Returns a status map indicating success or failure with a descriptive message.
  Future<Map<String, dynamic>> register(
    String username,
    String email,
    String password,
  ) async {
    try {
      final baseUrl = AppConfig.authBaseUrl;
      _log.i('Attempting registration to: $baseUrl/register');

      final response = await _client.post(
        Uri.parse('$baseUrl/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 201) {
        return _success(
          AppLocale.registrationSuccessCheckEmail,
          'Registration successful. Please check your email to verify your account.',
        );
      } else {
        return _serverFailure(
          data['error'],
          'Registration failed',
          AppLocale.neoSyncRegistrationFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Authenticates a user using their email and password.
  ///
  /// Upon successful authentication, it stores the JWT token securely,
  /// updates the internal [_currentUser] state, and notifies listeners.
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final baseUrl = AppConfig.authBaseUrl;
      _log.i('Attempting login to: $baseUrl/login');

      final response = await _client.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final token = data['token'];
        final userData = data['user'];

        final storage = await CredentialStore.write(_tokenKey, token);
        final tokenPersisted = storage != CredentialWriteOutcome.sessionOnly;
        if (!tokenPersisted) {
          _log.w(
            'Login succeeded but the token could not be persisted; the '
            'session ends when the app closes',
          );
        }

        _currentUser = User.fromJson(userData);
        _isLoggedIn = true;
        notifyListeners();

        final user = User.fromJson(userData);
        if (!user.emailVerified) {
          return {
            ..._success(
              AppLocale.neoSyncLoginSuccessfulEmailNotVerified,
              'Login successful, but email not verified',
            ),
            'emailVerified': false,
            'user': user,
            'tokenPersisted': tokenPersisted,
          };
        }

        return {
          ..._success(AppLocale.loginSuccessful, 'Login successful'),
          'emailVerified': true,
          'user': user,
          'tokenPersisted': tokenPersisted,
        };
      } else {
        // Classify on the raw server text, before redaction: the sentinel the
        // caller looks for is prose, and scrubbing could only ever remove it.
        final String rawError = data['error'] ?? 'Login failed';
        return {
          ..._serverFailure(
            data['error'],
            'Login failed',
            AppLocale.neoSyncLoginFailed,
          ),
          'emailNotVerified': rawError.toLowerCase().contains(
            'email not verified',
          ),
        };
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Verifies a user's email using a verification [token] sent via email.
  Future<Map<String, dynamic>> verifyEmail(String token) async {
    try {
      final response = await _client.post(
        Uri.parse('${AppConfig.authBaseUrl}/verify-email'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return _success(
          AppLocale.emailVerifiedSuccess,
          'Email verified successfully',
        );
      } else {
        return _serverFailure(
          data['error'] ?? data['message'],
          'Verification failed',
          AppLocale.neoSyncVerificationFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Checks the current verification status of an email address.
  Future<Map<String, dynamic>> checkEmailVerificationStatus(
    String email,
  ) async {
    try {
      final response = await _client.post(
        Uri.parse('${AppConfig.authBaseUrl}/check-email-status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'email_verified': data['email_verified'] ?? false,
          'username': data['username'],
        };
      } else {
        return _serverFailure(
          data['error'],
          'Failed to check status',
          AppLocale.neoSyncVerificationFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Triggers a resend of the account verification email to the specified address.
  Future<Map<String, dynamic>> resendVerificationEmail(String email) async {
    try {
      final response = await _client.post(
        Uri.parse('${AppConfig.authBaseUrl}/resend-verification'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return _success(
          AppLocale.neoSyncVerificationEmailSent,
          'Verification email sent',
        );
      } else {
        return _serverFailure(
          data['error'],
          'Failed to send verification email',
          AppLocale.neoSyncResendVerificationFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Fetches the detailed user profile for the current authenticated session.
  ///
  /// Automatically updates the internal [_currentUser] state on success — and
  /// marks the session live, because a server that answers this call has
  /// accepted the stored token. That is what makes opening the NeoSync tab
  /// enough to recover a session that started offline: the screen already
  /// calls this on entry, and used to throw the answer away and go on showing
  /// the login form.
  Future<Map<String, dynamic>> getProfile() async {
    // Captured before the first await, not next to the request: the token read
    // below is itself a suspension point, and a logout landing during it would
    // otherwise be invisible to the check.
    final epoch = _sessionEpoch;
    try {
      final token = await CredentialStore.read(_tokenKey);
      if (token == null) {
        return {
          'success': false,
          'message': 'Not authenticated',
          kNeoSyncLocalizedError: const NeoSyncLocalizedError(
            AppLocale.neoSyncNotAuthenticated,
          ),
        };
      }

      final response = await (httpClient ?? _client)
          .get(
            Uri.parse('${AppConfig.authBaseUrl}/auth/me'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(_profileTimeout);

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (epoch != _sessionEpoch) {
          // Signed out while this was in flight; the answer is stale.
          return {'success': false, 'message': 'Not authenticated'};
        }
        _currentUser = User.fromJson(data);
        _isLoggedIn = true;
        notifyListeners();
        return {'success': true, 'user': _currentUser};
      } else {
        return {
          ..._serverFailure(
            data['error'],
            'Failed to get profile',
            AppLocale.neoSyncServerError,
          ),
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      return {..._networkFailure(e), 'isNetworkError': true};
    }
  }

  /// Initiates a password recovery request for the specified email address.
  Future<Map<String, dynamic>> forgotPassword(String email) async {
    try {
      final response = await _client.post(
        Uri.parse('${AppConfig.authBaseUrl}/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return _success(
          AppLocale.neoSyncPasswordResetEmailSent,
          'Password reset email sent',
          serverMessage: data['message'],
        );
      } else {
        return _serverFailure(
          data['error'] ?? data['message'],
          'Failed to send password reset email',
          AppLocale.neoSyncPasswordResetEmailFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// Resets a user's password using a recovery [token] and a [newPassword].
  Future<Map<String, dynamic>> resetPassword(
    String token,
    String newPassword,
  ) async {
    try {
      final response = await _client.post(
        Uri.parse('${AppConfig.authBaseUrl}/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token, 'new_password': newPassword}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return _success(
          AppLocale.passwordResetSuccess,
          'Password reset successfully',
          serverMessage: data['message'],
        );
      } else {
        return _serverFailure(
          data['error'] ?? data['message'],
          'Failed to reset password',
          AppLocale.neoSyncPasswordResetFailed,
        );
      }
    } catch (e) {
      return _networkFailure(e);
    }
  }

  /// A 2xx response, worded twice like [_serverFailure]: `message` is the
  /// English diagnostic string these result maps have always carried, and
  /// [kNeoSyncLocalizedError] is what the screen renders. Issue #200.
  ///
  /// [serverMessage] is the body's `message` field where the endpoint sends
  /// one (`forgot-password`, `reset-password`). This used to take precedence on
  /// screen (`data['message'] ?? 'Password reset successfully'`); now it does
  /// not. Deliberately: the server's text is English-only, which is the very
  /// complaint here, and it says nothing the `AppLocale` sentence does not. It
  /// still replaces [englishMessage] in `message` — redacted, since a body from
  /// an auth endpoint can echo what it was sent — so the log keeps the server's
  /// specific wording for diagnosis.
  Map<String, dynamic> _success(
    String localeKey,
    String englishMessage, {
    Object? serverMessage,
  }) {
    final raw = serverMessage?.toString().trim();
    return {
      'success': true,
      'message': raw == null || raw.isEmpty
          ? englishMessage
          : redactSecrets(raw),
      kNeoSyncLocalizedError: neoSyncSuccess(localeKey),
    };
  }

  /// A non-2xx response, worded twice: `message` is the English diagnostic
  /// string these result maps have always carried (now redacted), and
  /// [kNeoSyncLocalizedError] is what the screen renders.
  ///
  /// The server's own text is redacted because it reaches `auth_form.dart`
  /// verbatim, and a body echoed back by an auth endpoint is exactly where a
  /// token or a credential-bearing URL turns up. Issue #195.
  Map<String, dynamic> _serverFailure(
    Object? serverError,
    String englishFallback,
    String localeKey,
  ) {
    final raw = serverError?.toString().trim();
    return {
      'success': false,
      'message': raw == null || raw.isEmpty
          ? englishFallback
          : redactSecrets(raw),
      kNeoSyncLocalizedError: neoSyncServerError(serverError, localeKey),
    };
  }

  /// A thrown exception, redacted. `'Network error: $e'` interpolates whatever
  /// the HTTP client threw, and on an auth call that string carries the request
  /// URI — query credentials included. Issue #195.
  Map<String, dynamic> _networkFailure(Object error) => {
    'success': false,
    'message': 'Network error: ${redactSecrets(error.toString())}',
    kNeoSyncLocalizedError: neoSyncNetworkError(error),
  };

  /// Terminates the current user session and purges the stored authentication token.
  Future<void> logout() async {
    _sessionEpoch++;
    await CredentialStore.delete(_tokenKey);
    _isLoggedIn = false;
    _currentUser = null;
    notifyListeners();
  }
}
