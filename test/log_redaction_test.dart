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
    // The four names the /sdd:review of #192 flagged as unmatched. Three are
    // added here; `credential` is deliberately rejected — see the last test.

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

    test('`credential` is deliberately NOT a sensitive field name', () {
      // Rejected, not overlooked. The codebase logs `... credentials: \$e` in
      // eight places (scraper_repository, screenscraper_service); adding the
      // name would blank the exception text those lines exist to carry — the
      // documented `Directory: /roms` failure mode. The values themselves are
      // already covered by password/token/api_key/secret/auth.
      const line = 'Error saving scraper credentials: SocketException: refused';
      expect(redactSecrets(line), line);
      expect(
        redactSecrets('Invalid credentials: ClientException uri=https://x/y'),
        'Invalid credentials: ClientException uri=https://x/y',
      );
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
}
