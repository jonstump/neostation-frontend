/// Secret redaction for anything written to the application log.
///
/// The log file lives on shared external storage and users routinely attach it
/// to public bug reports, so credentials must never reach it. Redaction is
/// applied centrally in [LoggerService] rather than at call sites: the leaks
/// that matter come from error objects we do not format ourselves — an HTTP
/// client exception, for example, embeds the full request URI including its
/// query string.
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
/// excluding `_` would let `user_password: hunter2` through — a leak, and far
/// worse than over-redacting the occasional `first_pass: 3`.
///
/// The unquoted value must also stop at `&` and `<`: without that it runs past
/// the end of a query parameter and swallows the remainder of a URL, and it
/// re-matches an already-substituted `<redacted>`, breaking idempotence.
final RegExp _jsonFieldPattern = RegExp(
  '(?<![A-Za-z0-9])'
  '(["\']?(?:${_sensitiveFieldNames.join('|')})["\']?\\s*[:=]\\s*)'
  '(["\'][^"\']*["\']|[^,\\s}\\]&<>"\']+)',
  caseSensitive: false,
);

/// `Authorization: Bearer abc` and `Basic dXNlcjpwYXNz`.
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
/// The unquoted value stops at `&` and `<`/`>` for the same reasons
/// [_jsonFieldPattern] does: so it cannot run past the end of a query
/// parameter, and so it cannot re-match an already-substituted
/// [redactedPlaceholder]. It must also not *start* on whitespace, or the same
/// backtracking lets a lone space stand in for the value and redaction stops
/// being idempotent.
final RegExp _authorizationFieldPattern = RegExp(
  '(["\']?authorization["\']?\\s*[:=]'
  '(?!\\s*(?:Bearer|Basic|Token)[\\s"\'])'
  '\\s*)'
  '(["\'][^"\']*["\']|[^\\s,&<>\\r\\n}\\]][^,&<>\\r\\n}\\]]*)',
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
  result = result.replaceAllMapped(
    _jsonFieldPattern,
    (m) => '${m[1]}$redactedPlaceholder',
  );
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
    (m) => '${m[1]}$redactedPlaceholder',
  );
  result = result.replaceAll(_jwtPattern, redactedPlaceholder);
  result = result.replaceAllMapped(
    _urlUserInfoPattern,
    (m) => '${m[1]}$redactedPlaceholder@',
  );
  return result;
}
