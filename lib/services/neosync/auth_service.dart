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
class AuthService extends ChangeNotifier {
  /// [client] is the seam for tests: the success paths are pinned against a
  /// `MockClient` so the sentences they carry are measured, not reasoned.
  AuthService({http.Client? client}) : _client = client ?? http.Client();

  /// Storage key for the authentication JWT token.
  static const String _tokenKey = 'auth_token';

  static final _log = LoggerService.instance;

  final http.Client _client;

  /// Whether a valid user session is currently active.
  bool _isLoggedIn = false;

  /// Metadata for the currently authenticated user.
  User? _currentUser;

  bool get isLoggedIn => _isLoggedIn;
  User? get currentUser => _currentUser;

  /// Initializes the service by attempting to restore a previous session from storage.
  ///
  /// If a token is found, it performs a profile fetch to validate its authenticity.
  /// Implements defensive logic to preserve tokens during network failures
  /// while purging them on explicit authentication errors (401/403).
  Future<void> initialize() async {
    try {
      final token = await CredentialStore.read(_tokenKey);
      if (token != null) {
        final profileResult = await getProfile();
        if (profileResult['success'] == true) {
          _isLoggedIn = true;
        } else if (profileResult['isNetworkError'] == true) {
          _isLoggedIn = false;
          _log.i(
            'AuthService: Network error during initialization. Token preserved.',
          );
        } else {
          final statusCode = profileResult['statusCode'];
          if (statusCode == 401 || statusCode == 403) {
            _log.w(
              'AuthService: Token invalid or expired ($statusCode). Clearing storage.',
            );
            await CredentialStore.delete(_tokenKey);
          } else {
            _log.i(
              'AuthService: Unexpected server error ($statusCode). Token preserved.',
            );
          }
          _isLoggedIn = false;
          _currentUser = null;
        }
      } else {
        _isLoggedIn = false;
        _currentUser = null;
      }
    } catch (e) {
      _isLoggedIn = false;
      _currentUser = null;
      _log.e('Error initializing auth service: $e');
    }
    notifyListeners();
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
  /// Automatically updates the internal [_currentUser] state on success.
  Future<Map<String, dynamic>> getProfile() async {
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

      final response = await _client.get(
        Uri.parse('${AppConfig.authBaseUrl}/auth/me'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _currentUser = User.fromJson(data);
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
    await CredentialStore.delete(_tokenKey);
    _isLoggedIn = false;
    _currentUser = null;
    notifyListeners();
  }
}
