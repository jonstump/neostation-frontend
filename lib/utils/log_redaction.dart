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
/// Issue #199.
///
/// The exemption that buys those lines back is deliberately narrow, and it is
/// the *position* that narrows it, not the value:
///
///  * only the four prose-colliding names ([_proseCollidingFieldNames]) can be
///    spared at all. Every other sensitive name redacts on the name alone,
///    exactly as it did before #199;
///  * only with a sentence colon (`session: x`, never `session=x`);
///  * only outside a structured container ([_isStructuredPosition]) — a `{`,
///    `[`, `(`, `,` or quote in front, a quoted value, or a neighbouring
///    `k=v` pair or `label:` all mean "dump", and inside a dump the value
///    never gets a vote;
///  * and only when the value does not look like a credential
///    ([_looksLikeSecret]).
///
/// What survives that, stated as classes rather than as one example, because a
/// future reader needs the shape and not the instance. Each class is measured
/// and pinned by a fixture in `test/log_redaction_test.dart` ("the documented
/// residue, pinned"), so closing one means updating both the doc and the test:
///
///  1. **Any value [_looksLikeSecret] declines, in a hand-written sentence
///     under one of the four names** — `Login for user bob session:
///     correcthorse`, `... key: 1234`. That is broader than a dictionary word
///     or a short number: the test hands back every shape it can name as
///     impossible for a credential, so a CamelCase value (`pass: OpenSesame`),
///     a `/`- or `~`-leading base64 blob (`token: /wEPDwUKLTcy`), a `$`-bearing
///     bcrypt hash (`pass: $2y$10$N9qo` — `$` is outside
///     [_credentialAlphabet]), a drive-letter or `./` path and a URL with the
///     secret in its *path* rather than its query (`token:
///     https://host/redeem/aB3x`) all survive here too. Each is also the shape
///     of a path, an exception or a word the corpus logs, and is
///     indistinguishable from `Session: restored` and `first_pass: 3 folders`
///     by any test this file can apply: the two shapes are the same characters
///     in the same place. A value the test accepts — `key: aB3xK9zQ7mR2pL5v` —
///     is redacted in the same sentence.
///  2. **The same, spelled with a bare `Token` scheme** — `Token opensesame`
///     is kept because `Token preserved.` and `Token invalid or expired` are
///     real log lines. [_authSchemeWord] caps that at eleven alphabetic
///     characters, above the longest word the corpus actually uses (nine) and
///     below every credential shape measured, and it does not apply at all
///     after an `Authorization` header name or inside a container. The
///     boundary is pinned on both sides: `Token unavailable` (eleven) is kept,
///     `Token unrecognized` (twelve) is redacted.
///  3. **A `k: v` pair whose immediate left neighbour carries no `:` or `=`**.
///     [_isStructuredPosition] looks one whitespace-delimited token back and
///     asks only whether it ends in a container opener or is `k=v` / `label:`
///     syntax ([_isPairToken]). Everything else reads as prose: a bare word
///     (`user: bob pass: 1234`), a `[Tag]` prefix — this codebase's dominant
///     log-line shape, so `[NeoSync] token: /wEPDwUKLTcy` survives — a MIME
///     type (`application/json pass: 1234`) and a path (`/data/user/0/app
///     key: opensesame`). `user=bob pass: 1234`, `headers: pass: 1234` and
///     `x=1] token: correcthorse` are all caught, because their neighbour is.
///     This class only opens the door; the value still has to be one class 1
///     hands back, so `[NeoSync] token: aB3xK9zQ7mR2pL5v` is redacted.
///
/// Everything structured is redacted: `{pass: 1234}`, `{key:
/// CorrectHorseBattery}`, `{"session": "deadbeefcafebabe"}`, `{token:
/// /wEPDwUKLTcy}`, `{pass: $2y$10$N9qo}`, `{token: https://host/redeem/aB3x}`,
/// `key="..."`, `?password=...`, `user=bob password=...`, `Basic dXNlcjpwYXNz`
/// and `Bearer anything`. So is every one of the ~30 shapes reported against
/// the first cut of this exemption, across all three of its mechanisms. The
/// leaks this file exists for — an error object or a URI we did not format —
/// are all structured by construction.
/// Measured against every `_log.*` literal in `lib/` and against an adversarial
/// corpus of credential shapes.
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
/// "RA API key", "first_pass", "Token preserved". For them, and only for them,
/// a sentence-shaped match with a non-credential value is spared. Every other
/// name in [_sensitiveFieldNames] redacts on the name alone wherever it
/// appears, which is what keeps `Could not store the access_token:
/// opensesame` and `Saved the secret: opensesame` from leaking mid-sentence:
/// the prose exemption is a licence these four need and the rest do not.
/// Issue #199.
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
///
/// It never sees a quoted value: a quoted value is a container's value and
/// [_isStructuredPosition] has already settled it. Only unquoted, prose-placed
/// values reach here.
bool _looksLikeSecret(String raw) {
  var value = raw.trim().replaceFirst(_trailingPunctuation, '');
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

/// Whether the field name starting at [start] sits inside a structured
/// container rather than in a hand-written sentence.
///
/// This is the gate that stops [_looksLikeSecret] from having the last word.
/// `Session: restored` and `{session: restored}` are the same seven characters
/// followed by the same `:`; only the first is prose, and only in prose is a
/// dictionary word evidence of anything. Inside a container the position
/// decides and the value shape is not consulted at all, which is what keeps
/// `{pass: 1234}`, `{key: CorrectHorseBattery}`, `{token: correcthorsebattery}`,
/// `{token: /wEPDwUKLTcy}`, `{pass: $2y$10$N9qo}` and
/// `{token: https://host/redeem/aB3x}` redacted — every one of them a shape
/// [_looksLikeSecret] would otherwise hand back. Issue #199, review round 2.
///
/// Three things mark a container:
///
///  * a quoted value. A sentence's next word is not in quotes; a dump's value
///    is. `key="dpad_up"` is a dump even though `dpad_up` is not a credential,
///    and `session: "deadbeefcafebabe"` is a dump even though the value would
///    pass for an English word;
///  * an opening `{`, `[`, `(`, `,` or quote in front of the field. The scan
///    steps back over the whole identifier first, so `{session_token: 1234}`
///    is recognised through the `session_` prefix that `token` is a suffix of,
///    while `Scan first_pass: 3 folders` — whose scan reaches the start of the
///    text — is not;
///  * a neighbouring token that is itself dump syntax ([_isPairToken]), which
///    is what a space-separated logfmt dump looks like: in
///    `user=bob api_key=SECRET` the token before `api_key` is a `k=v` pair,
///    and in `headers: key: correcthorse` it is the label `headers:`.
bool _isStructuredPosition(String input, int start, String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && (trimmed[0] == '"' || trimmed[0] == "'")) {
    return true;
  }
  var i = start;
  while (i > 0 && _isNameChar(input.codeUnitAt(i - 1))) {
    i--;
  }
  while (i > 0 && _isWhitespace(input.codeUnitAt(i - 1))) {
    i--;
  }
  if (i == 0) return false;
  if (_containerOpeners.contains(input[i - 1])) return true;
  var j = i;
  while (j > 0 && !_isWhitespace(input.codeUnitAt(j - 1))) {
    j--;
  }
  return _isPairToken(input.substring(j, i));
}

/// Characters that open a structured container. A field sitting immediately
/// after one of these is a field in a dump, whatever its value looks like.
const String _containerOpeners = '{[(,"\'';

/// Whether [token] is dump syntax rather than an ordinary word.
///
/// `user=bob`, `id=7`, `uri=https://api.example.com/login` and the label
/// `headers:` are all things a dump writes and a sentence does not; a bare
/// `:` or `=` starting a token is neither, so the separator has to have
/// something in front of it. Counting the label form costs nothing across the
/// `_log.*` corpus — measured, 0 of 15,418 lines change — and it is what stops
/// `headers: key: correcthorse` reading as a sentence.
bool _isPairToken(String token) {
  for (final separator in const ['=', ':']) {
    if (token.indexOf(separator) > 0) return true;
  }
  return false;
}

/// Whether the separator is a sentence's colon (`password: x`) rather than an
/// assignment (`password=x`, `password:x`).
///
/// `Failed to POST /login with password=correcthorse` reads as prose but the
/// `=` is still field syntax, so only the spaced colon is allowed to stand a
/// name down mid-sentence. Every over-redacted line #199 measured uses `: `.
///
/// The space is load-bearing, not cosmetic: without it `pass:1234` is spared
/// as a sentence, and nothing else in this file would catch it. Pinned by the
/// #205 fixtures.
bool _isSentenceColon(String prefix) {
  var i = prefix.length;
  var sawSpace = false;
  while (i > 0 && _isWhitespace(prefix.codeUnitAt(i - 1))) {
    i--;
    sawSpace = true;
  }
  return sawSpace && i > 0 && prefix[i - 1] == ':';
}

bool _isNameChar(int c) =>
    _isAlphanumeric(c) || c == 0x5F || c == 0x2D || c == 0x2E;

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
///  * only one of the four prose-colliding names ([_proseCollidingFieldNames])
///    may be stood down at all, and only with a sentence colon
///    ([_isSentenceColon]) outside a structured container
///    ([_isStructuredPosition]);
///  * and only then does it matter whether the value looks like a credential
///    ([_looksLikeSecret]) — the test that keeps `Session: restored` and
///    `Scan first_pass: 3 folders` from losing the word that made them worth
///    logging.
///
/// The decision is made in [_redactField] rather than in the pattern so that a
/// declined match can have its value re-scanned instead of swallowed.
final RegExp _jsonFieldPattern = RegExp(
  '(?<![A-Za-z0-9])'
  '(["\']?(${_sensitiveFieldNames.join('|')})["\']?\\s*[:=]\\s*)'
  '(["\'][^"\']*["\']|[^,;\\s}\\])&<>"\']+)',
  caseSensitive: false,
);

/// Redacts one [_jsonFieldPattern] match, or hands the value back unredacted
/// when all four gates agree it is diagnostic text.
///
/// Every one of them has to pass: the name must be prose-colliding, the
/// separator must be a sentence colon, the match must not sit in a container,
/// and only then does the value get a vote. Reversing the last two — letting
/// the value shape speak inside a dump — is what leaked `{pass: 1234}` and
/// its family.
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
      _proseCollidingFieldNames.contains(name) &&
      _isSentenceColon(prefix) &&
      !_isStructuredPosition(match.input, match.start, value) &&
      !_looksLikeSecret(value);
  return spare
      ? '$prefix${redactSecrets(value)}'
      : '$prefix$redactedPlaceholder';
}

/// `Authorization: Bearer abc` and `Basic dXNlcjpwYXNz`.
///
/// `Token` is the only scheme here that is also an ordinary noun, and matching
/// it ate the word after every prose use of it: `Token preserved.`,
/// `Token invalid or expired`, `the token could not be persisted`,
/// `paired-token metadata`, `token refresh failed`. So `Token` — and only
/// `Token` — can be stood down; `Bearer` and `Basic` redact unconditionally.
/// The first cut of this exemption ran the general [_looksLikeSecret] test
/// over the value of all three schemes, which spared `Basic dxnlcjpwyxnz`
/// (base64 of `user:pass` happens to be all lower case), `Bearer
/// opensesameopen` and `Bearer /wEPDwUKLTcy`. Issue #199, review round 2.
final RegExp _authHeaderPattern = RegExp(
  r'((?:Bearer|Basic|Token)\s+)([A-Za-z0-9\-._~+/]+=*)',
  caseSensitive: false,
);

/// The value shape a bare `Token` is allowed to keep: an alphabetic word, with
/// the sentence punctuation that may follow it.
///
/// Eleven characters is measured, not guessed. The longest word following
/// `Token`/`token` anywhere in `lib/`'s log literals is nine (`preserved`,
/// `persisted`); the shortest credential shape reported against the first cut
/// was twelve (`dxnlcjpwyxnz`). Anything carrying a digit, `/`, `-`, `_`, `.`,
/// `+`, `~` or `=` padding is a credential encoding and never a word, so the
/// class is deliberately alphabetic only.
final RegExp _authSchemeWord = RegExp(r'^[A-Za-z]{1,11}[.,;:!?]*$');

/// The header names after which a scheme word is a credential, never prose.
final RegExp _authHeaderNamePattern = RegExp(
  r'(?:proxy-)?authorization|www-authenticate|auth$',
  caseSensitive: false,
);

/// Whether the scheme word starting at [start] follows an `Authorization`
/// header name or sits in a container, in which case its value is a credential
/// whatever it looks like.
///
/// `{"authorization": "Token abcdefghij"}` and `authorization=Token abc` carry
/// the same credential as `Authorization: Bearer …`; `AuthService: Token
/// invalid or expired` does not. What separates them is the header name in
/// front, and the quote or `{` that a dump puts there.
bool _isAuthCredentialContext(String input, int start) {
  var i = start;
  while (i > 0 && _isWhitespace(input.codeUnitAt(i - 1))) {
    i--;
  }
  if (i == 0) return false;
  var c = input[i - 1];
  if (c == '"' || c == "'" || c == '{' || c == '[' || c == ',' || c == '=') {
    return true;
  }
  if (c != ':') return false;
  i--;
  while (i > 0 && _isWhitespace(input.codeUnitAt(i - 1))) {
    i--;
  }
  if (i > 0 && (input[i - 1] == '"' || input[i - 1] == "'")) i--;
  final end = i;
  while (i > 0 && (_isNameChar(input.codeUnitAt(i - 1)))) {
    i--;
  }
  if (i == end) return false;
  final name = input.substring(i, end);
  final match = _authHeaderNamePattern.firstMatch(name);
  return match != null && match.start == 0 && match.end == name.length;
}

/// Whether an [_authHeaderPattern] match is a credential rather than prose.
bool _isAuthHeaderSecret(Match match) {
  final scheme = match[1]!.trim().toLowerCase();
  if (scheme != 'token') return true;
  if (_isAuthCredentialContext(match.input, match.start)) return true;
  return !_authSchemeWord.hasMatch(match[2]!);
}

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
    (m) => _isAuthHeaderSecret(m) ? '${m[1]}$redactedPlaceholder' : m[0]!,
  );
  result = result.replaceAll(_jwtPattern, redactedPlaceholder);
  result = result.replaceAllMapped(
    _urlUserInfoPattern,
    (m) => '${m[1]}$redactedPlaceholder@',
  );
  return result;
}
