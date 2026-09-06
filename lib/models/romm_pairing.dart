/// Pure value types for RomM's device-pairing flow.
///
/// RomM's Client API Tokens screen generates an 8-character pairing code from
/// [RommPairCode.alphabet], shows it as `XXXX-XXXX` beside a QR code that
/// encodes `<origin>/pair?code=XXXX-XXXX`, and lets a device exchange the code
/// once, within about a minute, for a client token. Everything here is free of
/// I/O so the connect screen and the QR scanner can validate input before the
/// service touches the network.
library;

/// The pairing code as RomM defines it: [length] characters drawn from
/// [alphabet] (no `0`, `O`, `1`, `I`, or `L`, which read alike on a screen).
class RommPairCode {
  RommPairCode._();

  /// Characters RomM uses for pairing codes.
  static const String alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Characters in a code once the display dash is removed.
  static const int length = 8;

  static final RegExp _valid = RegExp('^[$alphabet]{$length}\$');
  static final RegExp _separators = RegExp(r'[\s\-]');

  /// Strips dashes and whitespace and upper-cases, mirroring the server's
  /// `code.replace("-", "").upper()`.
  static String normalize(String raw) =>
      raw.replaceAll(_separators, '').toUpperCase();

  /// Whether [normalized] is exactly [length] characters of [alphabet].
  static bool isValid(String normalized) => _valid.hasMatch(normalized);

  /// Formats a normalized code as `XXXX-XXXX`; anything that isn't [length]
  /// characters comes back unchanged.
  static String display(String normalized) {
    if (normalized.length != length) return normalized;
    return '${normalized.substring(0, 4)}-${normalized.substring(4)}';
  }
}

/// The payload of RomM's pairing QR code: the server origin and the code.
class RommPairLink {
  /// `scheme://host[:port]`, no path, no trailing slash.
  final String serverUrl;

  /// The normalized code (see [RommPairCode.normalize]).
  final String code;

  const RommPairLink({required this.serverUrl, required this.code});

  /// Parses `<scheme>://<host>[:port]/pair?code=<code>` (trailing slash on the
  /// path optional, code dashed or plain, any case). Returns null for anything
  /// else: a bare code, another path, a missing or malformed code parameter,
  /// a non-http(s) scheme, or text that isn't a URL at all.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Link Parsing"
  static RommPairLink? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (uri.path != '/pair' && uri.path != '/pair/') return null;

    final rawCode = uri.queryParameters['code'];
    if (rawCode == null) return null;
    final code = RommPairCode.normalize(rawCode);
    if (!RommPairCode.isValid(code)) return null;

    // Uri.host strips the brackets from an IPv6 literal; put them back so the
    // origin parses again.
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final origin = uri.hasPort
        ? '${uri.scheme}://$host:${uri.port}'
        : '${uri.scheme}://$host';
    return RommPairLink(serverUrl: origin, code: code);
  }

  @override
  bool operator ==(Object other) =>
      other is RommPairLink &&
      other.serverUrl == serverUrl &&
      other.code == code;

  @override
  int get hashCode => Object.hash(serverUrl, code);

  @override
  String toString() =>
      'RommPairLink(serverUrl: $serverUrl, code: ${RommPairCode.display(code)})';
}

/// The client token `POST /api/client-tokens/exchange` returns. [rawToken] is
/// the `rmm_…` secret and is used exactly like a pasted Client API Token; the
/// rest is display metadata.
class RommPairedToken {
  final String rawToken;
  final String name;
  final List<String> scopes;

  /// When the token stops working, or null for a token that never expires.
  final DateTime? expiresAt;

  const RommPairedToken({
    required this.rawToken,
    required this.name,
    required this.scopes,
    this.expiresAt,
  });

  /// Reads the exchange response. Tolerant of missing display fields; the
  /// caller decides what an empty [rawToken] means.
  factory RommPairedToken.fromJson(Map<String, dynamic> json) {
    final rawScopes = json['scopes'];
    final expires = json['expires_at']?.toString();
    return RommPairedToken(
      rawToken: json['raw_token']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      scopes: rawScopes is List
          ? rawScopes.map((s) => s.toString()).toList(growable: false)
          : const [],
      expiresAt: expires == null || expires.isEmpty
          ? null
          : DateTime.tryParse(expires),
    );
  }

  /// Never includes the token itself, so the object is safe to log.
  @override
  String toString() =>
      'RommPairedToken(name: $name, scopes: $scopes, expiresAt: $expiresAt, '
      'rawToken: <redacted>)';
}
