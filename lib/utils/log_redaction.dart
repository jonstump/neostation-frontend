/// Secret redaction for anything written to the application log.
///
/// The log file lives on shared external storage and users routinely attach it
/// to public bug reports, so credentials must never reach it. Redaction is
/// applied centrally in [LoggerService] rather than at call sites: the leaks
/// that matter come from error objects we do not format ourselves — an HTTP
/// client exception, for example, embeds the full request URI including its
/// query string.
///
/// A field name is not on its own enough to redact on. `session`, `token`,
/// `key` and `pass` are words this codebase writes in prose constantly, and
/// matching them as field names blanked the word after them — `Session:
/// restored`, `Token preserved`, `Scan first_pass: 3 folders`, and every
/// `... game session: $e` line, which lost the exception it existed to report.
/// So each match is tested twice more: the value has to look like a credential
/// ([_looksLikeSecret]), and the name has to be either one of the four
/// prose-colliding ones or standing mid-sentence rather than in a dump
/// ([_isProsePosition], [_isSentenceColon]). Issue #199.
///
/// The residue of that trade is narrow and worth naming: an all-lowercase,
/// dictionary-word credential handed to a sensitive name in a hand-written
/// sentence — `Login for user bob password: correcthorse` — now survives.
/// Every structured form of the same thing does not (`{password:
/// correcthorse}`, `password=correcthorse`, `?password=correcthorse`,
/// `"password": "correcthorse"`, `user=bob password=correcthorse`), and the
/// leaks this file exists for — an error object or a URI we did not format —
/// never take that shape. Measured against every `_log.*` literal in `lib/`.
///
/// Kept pure and dependency-free so the patterns can be tested directly.
library;

/// Placeholder substituted for every redacted value.
const String redactedPlaceholder = '<redacted>';

/// Query-string parameters whose values are credentials.
///
/// `y` is the RetroAchievements web API key; `devpassword`/`sspassword` and
/// `devid`/`ssid` are the ScreenScraper developer and user credentials. The
/// rest are generic names used across the HTTP clients.
///
/// This list is only ever matched after a literal `?` or `&`, which is what
/// makes a name as short as `y` or `sid` safe here. See
/// [_sensitiveFieldNames]. `authorization` and `sid` are anchored-only for the
/// same reason the header and cookie cases get their own patterns below: as a
/// bare field name `authorization` needs the scheme-aware handling
/// [_authorizationFieldPattern] gives it, and `sid` is too short to match
/// safely inside prose.
const List<String> _sensitiveQueryParams = [
  'y',
  'authorization',
  'sid',
  ..._sensitiveFieldNames,
];

/// Field names whose values are credentials in JSON / map / `toString` output.
///
/// Deliberately excludes `y`: unlike a query string there is no `?`/`&` to
/// anchor against, so a one-letter name matches inside ordinary prose. It is a
/// URL parameter of the RetroAchievements web API and never a field name.
const List<String> _sensitiveFieldNames = [
  'api_key',
  'apikey',
  'access_token',
  'refresh_token',
  'auth',
  // `secret` alone does not cover this one: the pattern below requires the
  // name to be followed immediately by `:` or `=`, and `client_secret_id`
  // continues past `secret` with `_id`. A wildcard suffix would fix the whole
  // family at once but would also eat `keyboard:`, `keys:` and `passing:`, so
  // suffixed credential names are listed out instead. Issue #195.
  'client_secret_id',
  // The singular name only. `credentials` (plural) is deliberately NOT here:
  // that is the name that would eat the nine `... credentials: $e` log lines in
  // `scraper_repository` and `screenscraper_service`, blanking the exception
  // text those lines exist to carry. Adding `credential` leaves all nine
  // untouched, by the same rule that made `client_secret_id` necessary above:
  // the pattern requires the name to end at the `:`/`=`, and `credentials`
  // carries on past it with an `s`. Measured, not assumed. Issues #195, #197.
  'credential',
  'devid',
  'devpassword',
  'key',
  'pass',
  'passwd',
  'password',
  'secret',
  'session',
  'sig',
  'signature',
  'ssid',
  'sspassword',
  'token',
];

/// The subset of [_sensitiveFieldNames] that are also ordinary English words.
///
/// `session`, `token`, `key` and `pass` are the four names this codebase writes
/// in prose far more often than it writes them as fields — "game session",
/// "RA API key", "first_pass", "Token preserved". For them the name on its own
/// is weak evidence, so [_looksLikeSecret] has to agree before the value is
/// scrubbed, wherever the name sits. Every other name in
/// [_sensitiveFieldNames] keeps the old behaviour at a structured position and
/// is only spared mid-prose (see [_isProsePosition]). Issue #199.
const Set<String> _proseCollidingFieldNames = {
  'key',
  'pass',
  'session',
  'token',
};

/// The character set an opaque credential is drawn from: base64, base64url,
/// hex, percent-encoding, and the separators real tokens use. A value carrying
/// anything else — a space, a bracket, a parenthesis — is not one of these,
/// which is what tells `PlatformException(channel-error` and
/// `SocketException: Connection refused` apart from `aB3xK9zQ7mR2pL5v`.
final RegExp _credentialAlphabet = RegExp(r'^[A-Za-z0-9+/=_.~:%-]+$');

/// An ordinary word, or the CamelCase name of a Dart type.
///
/// `restored`, `preserved`, `A`, `Exception`, `SocketException`,
/// `PlatformException`. The type names matter as much as the words: `$e` is by
/// far the commonest interpolation in these logs, and what it renders to
/// starts with the exception's class name.
///
/// Each capital must be followed by lower case, which is what keeps
/// `dXNlcjpwYXNz` (base64 of `user:pass`) and `SECRETTOKEN` on the credential
/// side of the line. The 24-character ceiling keeps a long all-lowercase blob —
/// longer than any word or type name these logs use — a credential.
final RegExp _plainWord = RegExp(r'^(?:[A-Za-z]|[a-z]+|(?:[A-Z][a-z]+)+)$');

/// Length ceiling applied alongside [_plainWord].
const int _maxWordLength = 24;

/// A counter, an index, a size. `3 folders`, `retry=3`.
final RegExp _smallNumber = RegExp(r'^\d{1,4}$');

/// A filesystem path, a SAF `content://` URI or any other URL. Paths are the
/// single most common value in these logs and are never credentials; a URL
/// that does carry one in its query string is redacted by
/// [_queryParamPattern], which runs first.
final RegExp _pathLike = RegExp(
  r'^(?:[/~]|\.{1,2}/|[A-Za-z]:[\\/]|[A-Za-z][A-Za-z0-9+.-]*://)',
);

/// Trailing punctuation belongs to the sentence, not to the value.
final RegExp _trailingPunctuation = RegExp(r'[.,:;!?)\]}]+$');

/// Whether [raw] looks like an opaque credential rather than diagnostic text.
///
/// Answering "does this value look like a secret?" is what stops the field
/// name alone from deciding. It is deliberately biased towards `true`: every
/// branch that returns `false` names a shape a credential cannot have.
bool _looksLikeSecret(String raw) {
  var value = raw.trim();
  if (value.length >= 2) {
    final first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      value = value.substring(1, value.length - 1).trim();
    }
  }
  value = value.replaceFirst(_trailingPunctuation, '');
  if (value.isEmpty) return false;
  // Spaces, brackets, parentheses: exception text and prose, not a token.
  if (!_credentialAlphabet.hasMatch(value)) return false;
  if (value.length <= _maxWordLength && _plainWord.hasMatch(value)) {
    return false;
  }
  if (_smallNumber.hasMatch(value)) return false;
  if (_pathLike.hasMatch(value)) return false;
  return true;
}

/// Whether the field name starting at [start] is the tail of a prose phrase
/// rather than a field in a structured dump.
///
/// `Error migrating the ScreenScraper password: <exception>` and
/// `{password: hunter2}` are the same eight characters followed by the same
/// `:`; what separates them is the word in front. A field in a dump is
/// preceded by a structural character — `{`, `,`, `"`, `_`, a newline, the
/// start of the text — or by another `k=v` pair. A noun in a sentence is
/// preceded by a space and a plain word.
///
/// The `=`/`:` test on the preceding token is what keeps a space-separated
/// (logfmt-style) dump structured: in `user=bob api_key=SECRET` the token
/// before `api_key` is `user=bob`, so `api_key` is still a field and its value
/// is still redacted. Issue #199.
bool _isProsePosition(String input, int start) {
  var i = start;
  var sawSpace = false;
  while (i > 0 && (input[i - 1] == ' ' || input[i - 1] == '\t')) {
    i--;
    sawSpace = true;
  }
  if (!sawSpace || i == 0) return false;
  final end = i;
  while (i > 0 && !_isWhitespace(input.codeUnitAt(i - 1))) {
    i--;
  }
  final previous = input.substring(i, end);
  if (previous.isEmpty) return false;
  if (previous.contains('=') || previous.contains(':')) return false;
  return _isAlphanumeric(previous.codeUnitAt(previous.length - 1));
}

/// Whether the separator is a sentence's colon (`password: x`) rather than an
/// assignment (`password=x`, `password:x`).
///
/// `Failed to POST /login with password=correcthorse` reads as prose but the
/// `=` is still field syntax, so only the spaced colon is allowed to stand a
/// name down mid-sentence. Every over-redacted line #199 measured uses `: `.
bool _isSentenceColon(String prefix) {
  var i = prefix.length;
  var sawSpace = false;
  while (i > 0 && _isWhitespace(prefix.codeUnitAt(i - 1))) {
    i--;
    sawSpace = true;
  }
  return sawSpace && i > 0 && prefix[i - 1] == ':';
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

bool _isAlphanumeric(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A);

/// `?y=abc` / `&password=abc` — keeps the parameter name, drops the value.
/// The value stops at the next separator so the rest of the URI is preserved.
final RegExp _queryParamPattern = RegExp(
  '([?&](?:${_sensitiveQueryParams.join('|')})=)([^&\\s"\'<>)\\]}]+)',
  caseSensitive: false,
);

/// `"password": "abc"` / `password: abc` in JSON or map/toString output.
///
/// The leading `(?<![A-Za-z0-9])` requires the name to start a word. Without
/// it, any word *ending* in a sensitive name scrubbed the token after it, which
/// silently mangled ordinary log lines — `Directory: /roms`, `Summary: 12`,
/// `Activity: com.foo.Bar`, `monkey: banana`, `bypass: true`. The `y` entry made
/// this pervasive (every word ending in "y"), which is why it now lives only in
/// [_sensitiveQueryParams].
///
/// `_` is deliberately NOT in that character class. Snake_case credential fields
/// are the common case in this codebase (SQLite columns, JSON payloads), and
/// excluding `_` would let `user_password: hunter2` through. `first_pass: 3`,
/// which that choice used to blank, is now kept by the value test instead —
/// see [_looksLikeSecret].
///
/// The unquoted value must also stop at `&`, `;` and `<`. Without `&` and `<`
/// it runs past the end of a query parameter and swallows the remainder of a
/// URL, and it re-matches an already-substituted `<redacted>`, breaking
/// idempotence. `;` is what separates the fields of a header dump
/// (`api_key=abc; content-type=application/json`), so without it the secret
/// takes its neighbours down with it — over-redaction of the surrounding
/// diagnostic text. No credential encoding this file redacts (base64,
/// base64url, hex, a JWT) contains a `;`. Issue #197.
/// The name alone is not enough to redact on. Two further tests apply, both
/// added by issue #199 after measuring the whole `_log.*` corpus:
///
///  * the value must look like a credential ([_looksLikeSecret]) — otherwise
///    `Session: restored` and `Scan first_pass: 3 folders` lose the word that
///    made them worth logging;
///  * a name that is also an ordinary word ([_proseCollidingFieldNames]) needs
///    that agreement wherever it sits, while every other name only stands down
///    mid-sentence ([_isProsePosition]) — so `{password: correcthorse}` stays
///    redacted while `Error migrating the ScreenScraper password: <exception>`
///    keeps its exception.
///
/// The decision is made in [_redactField] rather than in the pattern so that a
/// declined match can have its value re-scanned instead of swallowed.
final RegExp _jsonFieldPattern = RegExp(
  '(?<![A-Za-z0-9])'
  '(["\']?(${_sensitiveFieldNames.join('|')})["\']?\\s*[:=]\\s*)'
  '(["\'][^"\']*["\']|[^,;\\s}\\]&<>"\']+)',
  caseSensitive: false,
);

/// Redacts one [_jsonFieldPattern] match, or hands the value back unredacted
/// when both tests agree it is diagnostic text.
///
/// A spared value is passed back through [redactSecrets] rather than returned
/// verbatim: the match has already consumed it, so anything nested inside —
/// `session: "user=bob password=SECRET"` — would otherwise escape the
/// remaining passes entirely. The recursion terminates because the prefix
/// group is never empty, so the value is always strictly shorter.
String _redactField(Match match) {
  final prefix = match[1]!;
  final name = match[2]!.toLowerCase();
  final value = match[3]!;
  final spare =
      !_looksLikeSecret(value) &&
      (_proseCollidingFieldNames.contains(name) ||
          (_isSentenceColon(prefix) &&
              _isProsePosition(match.input, match.start)));
  return spare
      ? '$prefix${redactSecrets(value)}'
      : '$prefix$redactedPlaceholder';
}

/// `Authorization: Bearer abc` and `Basic dXNlcjpwYXNz`.
///
/// `Token` is why this pattern also consults [_looksLikeSecret]. Unlike
/// `Bearer` and `Basic` it is an ordinary noun, and matching it as a scheme ate
/// the word after every prose use of it: `Token preserved.`,
/// `Token invalid or expired`, `the token could not be persisted`,
/// `paired-token metadata`, `token refresh failed`. The value test keeps all of
/// those and still redacts `Basic dXNlcjpwYXNz`, whose internal capitals put it
/// outside [_plainWord]. Issue #199.
final RegExp _authHeaderPattern = RegExp(
  r'((?:Bearer|Basic|Token)\s+)([A-Za-z0-9\-._~+/]+=*)',
  caseSensitive: false,
);

/// `Authorization: <anything>` for the values [_authHeaderPattern] does not
/// cover: a scheme we never named (`MAC`, `Digest`, a vendor scheme) or a bare
/// token with no scheme at all. `auth` is already in [_sensitiveFieldNames],
/// but that pattern needs the name to be followed straight away by `:`/`=`,
/// so `authorization:` slipped past it entirely. Issue #195.
///
/// The `Bearer|Basic|Token` lookahead hands those three back to
/// [_authHeaderPattern], which keeps the scheme visible in the log — strictly
/// more diagnostic than blanking the whole value, and it leaves that pattern's
/// existing output untouched.
///
/// The lookahead sits *inside* the first group, immediately after the `:`/`=`.
/// Placed after the trailing `\\s*` it was useless: the quantifier simply gave
/// the space back, the lookahead then saw ` Bearer` instead of `Bearer`, and
/// the whole `Bearer abc` value was swallowed scheme and all.
///
/// The lookahead also has to skip an opening quote. `{"authorization":
/// "Bearer abc"}` carries the same credential as the header form, but the
/// lookahead saw `"Bearer` rather than `Bearer` and so did not hand the match
/// back: the JSON form lost its scheme while the header form kept it. Issue
/// #197.
///
/// The unquoted value stops at `&`, `;` and `<`/`>` for the same reasons
/// [_jsonFieldPattern] does: so it cannot run past the end of a query
/// parameter or of its own header in a `;`-joined dump, and so it cannot
/// re-match an already-substituted [redactedPlaceholder]. It must also not
/// *start* on whitespace, or the same backtracking lets a lone space stand in
/// for the value and redaction stops being idempotent.
final RegExp _authorizationFieldPattern = RegExp(
  '(["\']?authorization["\']?\\s*[:=]'
  '(?!\\s*["\']?(?:Bearer|Basic|Token)[\\s"\'])'
  '\\s*)'
  '(["\'][^"\']*["\']|[^\\s,;&<>\\r\\n}\\]][^,;&<>\\r\\n}\\]]*)',
  caseSensitive: false,
);

/// `Set-Cookie: sid=abc; Path=/; HttpOnly` — keeps the cookie name and its
/// attributes, drops the value, the same trade [_queryParamPattern] makes.
///
/// A session cookie is a bearer credential in every way that matters, and a
/// response-header dump is exactly the kind of text an HTTP exception carries.
/// Only the first cookie of a comma-joined header is covered; stopping at the
/// comma is what keeps this from swallowing the neighbouring fields of a
/// single-line `Map.toString()`. Issue #195.
final RegExp _setCookiePattern = RegExp(
  '(set-cookie\\s*[:=]\\s*["\']?[A-Za-z0-9_.\\-]+=)'
  '([^;,\\s"\'<>\\]}]+)',
  caseSensitive: false,
);

/// A JWT anywhere in the text, including ones we never named.
final RegExp _jwtPattern = RegExp(
  r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+',
);

/// Credentials embedded in a URL's userinfo: `https://user:pass@host`.
final RegExp _urlUserInfoPattern = RegExp(r'(://)[^/\s:@]+:[^/\s@]+@');

/// Returns [text] with every recognised credential replaced by
/// [redactedPlaceholder].
///
/// Non-secret content is left untouched so the log stays useful for debugging:
/// usernames, hosts, paths and endpoint names all survive.
String redactSecrets(String text) {
  if (text.isEmpty) return text;

  var result = text.replaceAllMapped(
    _queryParamPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAllMapped(_jsonFieldPattern, _redactField);
  result = result.replaceAllMapped(
    _setCookiePattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _authorizationFieldPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAllMapped(
    _authHeaderPattern,
    (m) => _looksLikeSecret(m[2]!) ? '${m[1]}$redactedPlaceholder' : m[0]!,
  );
  result = result.replaceAll(_jwtPattern, redactedPlaceholder);
  result = result.replaceAllMapped(
    _urlUserInfoPattern,
    (m) => '${m[1]}$redactedPlaceholder@',
  );
  return result;
}
