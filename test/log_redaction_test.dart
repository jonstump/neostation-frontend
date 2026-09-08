import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/log_redaction.dart';

void main() {
  group('redactSecrets — the observed leak', () {
    test('strips the RetroAchievements web API key from a request URI', () {
      // Shape of the line seen in app.log on the Thor: the key is in the URI
      // carried by an http ClientException, not in our own message.
      // NOTE: the key below is a dummy of the same shape (32 chars, base62) —
      // never paste a real key here, this file is public.
      const fakeKey = 'EXAMPLEexample0123456789ABCDefgh';
      const line =
          'Error getting user profile: ClientException with SocketException: '
          'Failed host lookup, uri=https://retroachievements.org/API/'
          'API_GetUserProfile.php?u=SomeUser&y=$fakeKey';

      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains(fakeKey)));
      expect(redacted, contains('y=<redacted>'));
      // Everything needed to debug the failure survives.
      expect(redacted, contains('u=SomeUser'));
      expect(redacted, contains('API_GetUserProfile.php'));
      expect(redacted, contains('Failed host lookup'));
    });

    test('strips ScreenScraper developer and user credentials', () {
      const line =
          'GET https://api.screenscraper.fr/api2/jeuInfos.php?devid=neo'
          '&devpassword=s3cr3t&softname=NeoStation&ssid=someone'
          '&sspassword=hunter2&output=json';

      final redacted = redactSecrets(line);

      expect(redacted, isNot(contains('s3cr3t')));
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('=neo&')));
      expect(redacted, contains('devpassword=<redacted>'));
      expect(redacted, contains('sspassword=<redacted>'));
      expect(redacted, contains('softname=NeoStation'));
      expect(redacted, contains('output=json'));
    });
  });

  group('redactSecrets — other credential shapes', () {
    test('redacts a bearer token', () {
      final redacted = redactSecrets(
        'headers: {Authorization: Bearer abc123DEF456ghi}',
      );
      expect(redacted, isNot(contains('abc123DEF456ghi')));
      expect(redacted, contains('Bearer <redacted>'));
    });

    test('redacts a JWT anywhere in the text', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
          '.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
          '.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final redacted = redactSecrets('NeoSync session restored: $jwt');
      expect(redacted, isNot(contains('eyJhbGci')));
      expect(redacted, contains('<redacted>'));
      expect(redacted, contains('NeoSync session restored'));
    });

    test('redacts credentials embedded in a URL', () {
      final redacted = redactSecrets(
        'RomM: connecting to https://user:hunter2@romm.local/api/roms',
      );
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, contains('https://<redacted>@romm.local/api/roms'));
    });

    test('redacts credential-shaped JSON fields', () {
      final redacted = redactSecrets(
        'body: {"username": "someone", "password": "hunter2", '
        '"token": "abc.def"}',
      );
      expect(redacted, isNot(contains('hunter2')));
      expect(redacted, isNot(contains('abc.def')));
      expect(redacted, contains('someone'));
    });

    test('is case-insensitive about parameter names', () {
      final redacted = redactSecrets('?API_KEY=abc123&Password=xyz789');
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('xyz789')));
    });
  });

  group('redactSecrets — leaves ordinary logs alone', () {
    test('does not touch a normal message', () {
      const line = 'Database loaded: 35 systems with games';
      expect(redactSecrets(line), line);
    });

    test('does not touch a plain path or non-secret query', () {
      const line =
          'Scanning /storage/emulated/0/roms/nes — '
          'https://example.com/manifest.json?v=2&platform=android';
      expect(redactSecrets(line), line);
    });

    test('handles an empty string', () {
      expect(redactSecrets(''), '');
    });

    test('redaction is idempotent', () {
      const line = 'uri=https://retroachievements.org/API/x.php?u=me&y=SECRET';
      final once = redactSecrets(line);
      expect(redactSecrets(once), once);
    });
  });

  group('redactSecrets — does not eat ordinary words (false positives)', () {
    // Every sensitive name was matched without a leading word boundary, so any
    // word *ending* in one of them scrubbed the following token. Observed live:
    // "[EmuSel] ANOMALY: system ds has 2 user defaults" lost the word "system"
    // because "ANOMALY" ends in "y", the RetroAchievements API key parameter.
    const survivors = <String, String>{
      'ANOMALY: system ds has 2 user defaults': 'system',
      'Summary: 12 games scanned': '12',
      'Directory: /storage/emulated/0/roms': '/storage/emulated/0/roms',
      'Activity: com.retroarch.browser.RetroActivity':
          'com.retroarch.browser.RetroActivity',
      'Query: SELECT * FROM user_roms': 'SELECT',
      'Priority: high': 'high',
      'Body: null': 'null',
      'monkey: banana': 'banana',
      'bypass: true': 'true',
      'oauth: disabled': 'disabled',
    };

    survivors.forEach((line, mustSurvive) {
      test('leaves "$line" alone', () {
        final redacted = redactSecrets(line);
        expect(redacted, contains(mustSurvive));
        expect(redacted, isNot(contains(redactedPlaceholder)));
      });
    });
  });

  group('redactSecrets — still redacts real credentials', () {
    test('a standalone key/token/password field is still redacted', () {
      for (final line in [
        'key: abc123',
        'token: abc123',
        'password: abc123',
        'secret = abc123',
        '"api_key": "abc123"',
      ]) {
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains('abc123')), reason: line);
        expect(redacted, contains(redactedPlaceholder), reason: line);
      }
    });

    test('the RA api key is still redacted as a query parameter', () {
      final redacted = redactSecrets('https://ra.org/API/x.php?u=me&y=SECRET1');
      expect(redacted, isNot(contains('SECRET1')));
      expect(redacted, contains('y=<redacted>'));
    });
  });

  group('redactSecrets — snake_case credential fields', () {
    // The word-boundary that fixes the false positives must NOT treat `_` as a
    // word character: snake_case is how credentials appear in SQLite columns
    // and JSON payloads here, and excluding `_` silently un-redacted them.
    test('a snake_case credential field is still redacted', () {
      for (final line in [
        'user_password: hunter2',
        'ra_key: hunter2',
        'dev_password=hunter2',
        '{ss_password: hunter2}',
        '"refresh_token": "hunter2"',
      ]) {
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains('hunter2')), reason: line);
        expect(redacted, contains(redactedPlaceholder), reason: line);
      }
    });
  });

  group('redactSecrets — the #195 keyword review', () {
    // The four names the /sdd:review of #192 flagged as unmatched. Three were
    // added here; the fourth, `credential`, was rejected on a rationale that
    // measurement later disproved and is now covered in the #197 group below.

    test('an Authorization value with no scheme is redacted', () {
      // `auth` is a sensitive field name already, but the field pattern needs
      // the name to be followed straight away by `:`/`=`, so `authorization:`
      // slipped past it entirely.
      final redacted = redactSecrets('headers: {authorization: abc123DEF456}');
      expect(redacted, isNot(contains('abc123DEF456')));
      expect(redacted, contains('authorization: <redacted>'));
    });

    test('an Authorization value with an unknown scheme is redacted', () {
      final redacted = redactSecrets(
        'headers: {Authorization: MAC k3y-material-here}',
      );
      expect(redacted, isNot(contains('k3y-material-here')));
      expect(redacted, contains('Authorization: <redacted>'));
    });

    test('authorization as a query parameter is redacted', () {
      final redacted = redactSecrets('GET /api?authorization=abc123&page=2');
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, contains('authorization=<redacted>'));
      // The rest of the query still survives.
      expect(redacted, contains('page=2'));
    });

    test('Bearer/Basic keep their scheme visible — unchanged by #195', () {
      // The new authorization pattern defers to the older header pattern for
      // the three schemes it words better. Losing `Bearer` here would be a
      // regression in the log, not an improvement.
      expect(
        redactSecrets('headers: {Authorization: Bearer abc123DEF456ghi}'),
        'headers: {Authorization: Bearer <redacted>}',
      );
      expect(
        redactSecrets('Authorization: Basic dXNlcjpwYXNz'),
        'Authorization: Basic <redacted>',
      );
    });

    test('a Set-Cookie session value is redacted, attributes survive', () {
      final redacted = redactSecrets(
        'Set-Cookie: sid=SESSIONSECRET; Path=/; HttpOnly',
      );
      expect(redacted, isNot(contains('SESSIONSECRET')));
      expect(redacted, 'Set-Cookie: sid=<redacted>; Path=/; HttpOnly');
    });

    test('a signed Express cookie is redacted', () {
      final redacted = redactSecrets(
        'set-cookie: connect.sid=s%3Aabc.def; Path=/',
      );
      expect(redacted, isNot(contains('s%3Aabc.def')));
      expect(redacted, contains('connect.sid=<redacted>'));
    });

    test('sid as a query parameter is redacted', () {
      final redacted = redactSecrets('/api/files?sid=SESSIONSECRET&limit=20');
      expect(redacted, isNot(contains('SESSIONSECRET')));
      expect(redacted, contains('sid=<redacted>'));
      expect(redacted, contains('limit=20'));
    });

    test('client_secret_id is redacted alongside client_secret', () {
      // `secret` alone never matched this one: the field pattern needs the
      // name to end at the `:`, and `client_secret_id` carries on past it.
      final redacted = redactSecrets(
        '{"client_secret_id": "cs_live_abc123", "client_secret": "sk_xyz"}',
      );
      expect(redacted, isNot(contains('cs_live_abc123')));
      expect(redacted, isNot(contains('sk_xyz')));
    });

    test('the new patterns stay idempotent', () {
      for (final line in [
        'headers: {authorization: abc123DEF456}',
        'headers: {Authorization: Bearer abc123DEF456}',
        'Set-Cookie: sid=SESSIONSECRET; Path=/; HttpOnly',
        '{"client_secret_id": "cs_live_abc123"}',
        '/api/files?sid=SESSIONSECRET&limit=20',
      ]) {
        final once = redactSecrets(line);
        expect(redactSecrets(once), once, reason: line);
      }
    });
  });

  group('redactSecrets — the #197 review findings', () {
    // The nine `... credentials: <exception>` log lines this repo actually
    // emits, rendered with the exception text they carry. `grep -rn
    // 'credentials:' lib/` finds them in scraper_repository.dart (3) and
    // screenscraper_service.dart (6).
    const pluralCredentialLogLines = <String>[
      'Error saving scraper credentials: SocketException: Connection refused',
      'Error getting scraper credentials: SocketException: Connection refused',
      'Error clearing scraper credentials: SocketException: Connection refused',
      'Error verifying credentials: SocketException: Connection refused',
      'Error saving credentials: SocketException: Connection refused',
      'Error refreshing credentials: SocketException: Connection refused',
      'Error getting saved credentials: SocketException: Connection refused',
      'Error deleting credentials: SocketException: Connection refused',
      'Invalid credentials: Erreur de login : verifiez vos identifiants',
    ];

    test('`credential` (singular) IS a sensitive field name', () {
      // Fails if `credential` is dropped from _sensitiveFieldNames. #196
      // rejected it believing it would blank the nine lines above; the test
      // below measures that it does not.
      for (final line in [
        'credential: hunter2SECRET',
        '{"credential": "hunter2SECRET"}',
        "{'credential': 'hunter2SECRET'}",
        '{credential: hunter2SECRET, user: bob}',
        'credential=hunter2SECRET',
        'user_credential: hunter2SECRET',
      ]) {
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains('hunter2SECRET')), reason: line);
        expect(redacted, contains(redactedPlaceholder), reason: line);
      }
    });

    test('`credentials` (plural) must never become a sensitive field name', () {
      // Fails the moment `credentials` is added: the field pattern would take
      // the exception text after the `:` and these nine lines would carry
      // `<redacted>` instead of the reason they exist to report. `credential`
      // does not have that effect, because the pattern needs the name to end
      // at the `:` and the plural carries on with an `s`.
      for (final line in pluralCredentialLogLines) {
        expect(redactSecrets(line), line, reason: line);
      }
    });

    test('the credential store log lines survive intact', () {
      // Singular, but followed by a space rather than a `:`/`=`.
      for (final line in [
        'ScreenScraper: credential store unreadable: PlatformException(x)',
        'Skipping RetroAchievements auto-login: credential storage unavailable',
        'moved "ra_api_key" out of the database into the credential store',
      ]) {
        expect(redactSecrets(line), line, reason: line);
      }
    });

    test(
      'the JSON-quoted Authorization keeps its scheme, as the header does',
      () {
        // The negative lookahead used to see `"Bearer` rather than `Bearer`, so
        // the quoted form lost the scheme the header form kept.
        expect(
          redactSecrets('{"authorization": "Bearer abc123DEF456ghi"}'),
          '{"authorization": "Bearer <redacted>"}',
        );
        expect(
          redactSecrets("{'authorization': 'Bearer abc123DEF456ghi'}"),
          "{'authorization': 'Bearer <redacted>'}",
        );
        expect(
          redactSecrets('{"authorization": "Basic dXNlcjpwYXNz"}'),
          '{"authorization": "Basic <redacted>"}',
        );
        expect(
          redactSecrets('{"Authorization": "Token abc123DEF456ghi"}'),
          '{"Authorization": "Token <redacted>"}',
        );
        // A scheme we never named still loses the whole value — unchanged.
        final unknown = redactSecrets('{"authorization": "MAC k3y-material"}');
        expect(unknown, isNot(contains('k3y-material')));
        expect(unknown, contains(redactedPlaceholder));
      },
    );

    test('a semicolon-joined header dump loses only the secret', () {
      expect(
        redactSecrets(
          'headers: api_key=SECRETKEY; content-type=application/json; accept=*',
        ),
        'headers: api_key=<redacted>; content-type=application/json; accept=*',
      );
      expect(
        redactSecrets(
          'authorization=SECRETKEY; content-type=application/json; accept=*',
        ),
        'authorization=<redacted>; content-type=application/json; accept=*',
      );
      expect(
        redactSecrets('token: SECRETTOKEN; retry=3; timeout=30s'),
        'token: <redacted>; retry=3; timeout=30s',
      );
    });

    test('the #197 shapes stay idempotent', () {
      for (final line in [
        'credential: hunter2SECRET',
        '{"credential": "hunter2SECRET"}',
        '{"authorization": "Bearer abc123DEF456ghi"}',
        '{"authorization": "MAC k3y-material"}',
        'authorization=SECRETKEY; content-type=application/json; accept=*',
        'token: SECRETTOKEN; retry=3; timeout=30s',
        ...pluralCredentialLogLines,
      ]) {
        final once = redactSecrets(line);
        expect(redactSecrets(once), once, reason: line);
      }
    });
  });

  group('redactSecrets — the #199 over-redaction', () {
    // Measured on main (d158cab): `session`, `token` and `pass` matched as
    // field names in the middle of ordinary prose, so the word after them was
    // blanked. The right-hand side of each pair is what main produced.
    const restored = <String, String>{
      'Session: restored': 'Session: <redacted>',
      'Session: active game session ended':
          'Session: <redacted> game session ended',
      'Token preserved': 'Token <redacted>',
      'RomM token preserved across reconnect':
          'RomM token <redacted> across reconnect',
      'Scan first_pass: 3 folders': 'Scan first_pass: <redacted> folders',
    };

    restored.forEach((line, whatMainDid) {
      test('"$line" keeps its diagnostic text', () {
        expect(line, isNot(whatMainDid), reason: 'sanity: the pair differs');
        expect(redactSecrets(line), line);
      });
    });

    // The real `_log.*` lines the sweep of lib/ found being over-redacted,
    // rendered with the exception text they carry.
    const logLines = <String>[
      'AuthService: Network error during initialization. Token preserved.',
      'AuthService: Token invalid or expired (SocketException: refused). '
          'Clearing storage.',
      'Could not read the NeoSync token: SocketException: Connection refused',
      'Error clearing RA API key: SocketException: Connection refused',
      'Error saving game session: SocketException: Connection refused',
      'Error saving RomM paired-token metadata: PlatformException(x, y)',
      'RomM token refresh failed, re-authenticating: TimeoutException',
      'RomM pairing: token metadata not persisted: name=demo expires_at=never',
      'Login succeeded but the token could not be persisted; '
          'the session ends when the app closes',
      'Error checking the pending game session: SocketException: refused',
      'Error clearing RA API key: /storage/emulated/0/neostation/app.log',
      // A label in front is dump syntax; a plain word in front is not, and the
      // sentence has to survive the difference.
      'AuthService: restored the game session: SocketException: refused',
    ];

    for (final line in logLines) {
      test('leaves "${line.substring(0, 32)}…" alone', () {
        expect(redactSecrets(line), line);
      });
    }

    test('the #175 log line no longer needs its workaround wording', () {
      // `game_session_manager.dart` had to write `session, error=$e` because
      // `session: $e` lost the exception. Both wordings survive now; the
      // natural one is what the file carries again.
      expect(
        redactSecrets(
          'Error checking the pending game session: '
          'PlatformException(channel-error, no implementation, null, null)',
        ),
        'Error checking the pending game session: '
        'PlatformException(channel-error, no implementation, null, null)',
      );
    });
  });

  group('redactSecrets — #199 must not have loosened anything', () {
    // Each entry is a shape that has to stay redacted. The names in the
    // `password` family are the ones a value test alone would have leaked, so
    // they are listed at every position a dump can put them in.
    const mustRedact = <String, String>{
      // A benign-looking value at a structured position is still a credential.
      '{password: correcthorse}': 'correcthorse',
      '{"password": "correcthorse"}': 'correcthorse',
      'LoginRequest(username: bob, password: correcthorse)': 'correcthorse',
      '{password: 1234}': '1234',
      '"passwd": "letmein"': 'letmein',
      '{secret: opensesame}': 'opensesame',
      // logfmt: the token before the name is a k=v pair, so this is a dump,
      // not a sentence, however much the surrounding text reads like one.
      'user=bob api_key=9f8c1d2e3a4b5c6d': '9f8c1d2e3a4b5c6d',
      'req id=7 password=correcthorse': 'correcthorse',
      // The same rule with a spaced colon, so it is the preceding `k=v` /
      // `label:` — not the separator — doing the work. Without that test both
      // of these read as sentences and hand back the password.
      'headers: password: correcthorse': 'correcthorse',
      'uri=https://api.example.com/login password: correcthorse':
          'correcthorse',
      // `=` is assignment even mid-sentence; only a spaced colon is prose.
      'Failed to POST /login with password=correcthorse': 'correcthorse',
      // Ordinary credential shapes, unchanged from before #199.
      'password: hunter2': 'hunter2',
      'user_password: hunter2': 'hunter2',
      'token: abc123DEF456ghi': 'abc123DEF456ghi',
      'session=aB3xK9zQ7mR2pL5v': 'aB3xK9zQ7mR2pL5v',
      'key: 9f8c1d2e3a4b5c6d7e8f90a1b2c3d4e5':
          '9f8c1d2e3a4b5c6d7e8f90a1b2c3d4e5',
      'first_pass: aB3xK9zQ7mR2pL5v': 'aB3xK9zQ7mR2pL5v',
      // Base64 is letters-only often enough that the word test has to reject
      // internal capitals: this is base64 of `user:password123`.
      'Authorization: Basic dXNlcjpwYXNzd29yZDEyMw==': 'dXNlcjpwYXNzd29yZDEyMw',
      'Bearer dXNlcjpwYXNz': 'dXNlcjpwYXNz',
      // A long all-lowercase blob is not a word, whatever it looks like.
      'Bearer abcdefghijklmnopqrstuvwxyzabcdefghij':
          'abcdefghijklmnopqrstuvwxyzabcdefghij',
      'token: abcdefghijklmnopqrstuvwxyzabcdefghij':
          'abcdefghijklmnopqrstuvwxyzabcdefghij',
      // A secret nested inside a value that is itself spared must not ride out
      // on the back of the spared match.
      'session: "user=bob password=9f8c1d2e3a4b5c6d"': '9f8c1d2e3a4b5c6d',
      'key: "a password=9f8c1d2e3a4b5c6d"': '9f8c1d2e3a4b5c6d',
      // --- review round 2 -------------------------------------------------
      // The first cut let `key`/`pass`/`session`/`token` be decided by the
      // value shape *wherever they sat*, so every branch of the value test
      // became a leak inside a dump. One line per branch, under each of the
      // four names, at each container shape a dump can take.
      '{pass: 1234}': '1234', // small number
      '{key: 4821}': '4821',
      '{"session": 9137}': '9137',
      '{pass: OpenSesame}': 'OpenSesame', // CamelCase
      '{key: CorrectHorseBattery}': 'CorrectHorseBattery',
      '{token: SecretKeyValue}': 'SecretKeyValue',
      '{token: correcthorsebattery}': 'correcthorsebattery', // lower case
      '{"session":"deadbeefcafebabe"}': 'deadbeefcafebabe',
      // `/` is in the base64 alphabet, so roughly one credential in 64 starts
      // with one and used to be handed to the path test.
      '{token: /wEPDwUKLTcyMzY2MTA1MQ}': '/wEPDwUKLTcyMzY2MTA1MQ',
      '{"session": "~aB3xK9zQ7mR2pL5v"}': 'aB3xK9zQ7mR2pL5v',
      // `$` is outside the credential alphabet — a bcrypt hash is still a
      // credential.
      r'{pass: $2y$10$N9qo8uLOickgx2ZMRZoMye}': 'N9qo8uLOickgx2ZMRZoMye',
      // A secret in a URL *path* — a pairing / redeem link — is not covered by
      // the query-parameter pattern.
      '{token: https://neosync.app/redeem/aB3xK9zQ7mR2pL5v}':
          'aB3xK9zQ7mR2pL5v',
      // The name reached through a snake_case prefix, and through a quote.
      '{"session_token": "hunterhunterhunter"}': 'hunterhunterhunter',
      '{user_pass: 1234}': '1234',
      '[key: correcthorsebattery]': 'correcthorsebattery',
      '{a: 1, pass: 1234}': '1234',
      'headers: {content-type: application/json, key: 1234}': '1234',
      'user=bob token=correcthorsebattery': 'correcthorsebattery',
      // A quoted value is a dump's value, not a sentence's next word.
      'session: "deadbeefcafebabe"': 'deadbeefcafebabe',
      r'[KeyboardRaw] key="opensesame" physical="KeyA"': 'opensesame',
      // The auth-header schemes. `Bearer` and `Basic` are never prose, so no
      // value shape may stand them down; `Token` may, but not after an
      // `Authorization` header name, not in a container, and not for a value
      // longer than any word the corpus uses.
      'Basic dxnlcjpwyxnz': 'dxnlcjpwyxnz',
      'Bearer opensesameopen': 'opensesameopen',
      'Token abcdefghijklmnop': 'abcdefghijklmnop',
      'Bearer /wEPDwUKLTcyMzY2MTA1MQ': 'wEPDwUKLTcyMzY2MTA1MQ',
      'Basic correcthorsebattery': 'correcthorsebattery',
      'authorization: Token opensesame': 'opensesame',
      '{"authorization": "Token opensesame"}': 'opensesame',
      // Only the four prose-colliding names get a prose exemption. Every other
      // sensitive name redacts on the name alone, mid-sentence included.
      'Could not store the access_token: opensesame': 'opensesame',
      'RA request failed for api_key: hunter': 'hunter',
      'Rotating the client_secret_id: opensesame': 'opensesame',
      'Wrote the signature: Deadbeef': 'Deadbeef',
      'Using devpassword: mysecretword': 'mysecretword',
      'Saved the secret: opensesame': 'opensesame',
      'Error migrating the ScreenScraper password: correcthorse':
          'correcthorse',
      // The neighbouring token, not the separator, is what makes a
      // space-separated dump a dump — under the four prose-colliding names
      // too, and whether the neighbour is a `k=v` pair or a `label:`.
      'user=bob session: 1234': '1234',
      'req id=7 key: opensesame': 'opensesame',
      'headers: key: correcthorse': 'correcthorse',
      'uri=https://api.example.com/login token: opensesame': 'opensesame',
      // `=` is assignment, never a sentence, under those four names as well.
      'pass=1234': '1234',
      'token=opensesame': 'opensesame',
      // A short lower-case word is still a credential after a scheme that is
      // not an English word.
      'Basic opensesame': 'opensesame',
      'Bearer letmein': 'letmein',
    };

    mustRedact.forEach((line, secret) {
      test('"$line" is still redacted', () {
        expect(line, contains(secret), reason: 'sanity: the fixture is wrong');
        final redacted = redactSecrets(line);
        expect(redacted, isNot(contains(secret)));
        expect(redacted, contains(redactedPlaceholder));
      });
    });

    test('a re-scanned nested secret keeps the context around it', () {
      // The spared value is passed back through `redactSecrets`, and the inner
      // match must not take the closing paren of the exception with it.
      expect(
        redactSecrets('token: SocketException(api_key=9f8c1d2e3a4b5c6d)'),
        'token: SocketException(api_key=$redactedPlaceholder)',
      );
    });

    test('the #199 shapes stay idempotent', () {
      for (final line in [...restoredLines199, ...mustRedact.keys]) {
        final once = redactSecrets(line);
        expect(redactSecrets(once), once, reason: line);
      }
    });
  });
}

/// The lines #199 restored, reused by the idempotence check above.
const List<String> restoredLines199 = <String>[
  'Session: restored',
  'Session: active game session ended',
  'Token preserved',
  'RomM token preserved across reconnect',
  'Scan first_pass: 3 folders',
  'Error checking the pending game session: SocketException: refused',
];
