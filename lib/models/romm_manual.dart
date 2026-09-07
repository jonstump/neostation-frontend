/// The file types the manual viewer can open.
///
/// RomM will happily store any file as a ROM's manual, so the extension is a
/// gate rather than a description: a `.pdf`, `.txt` or `.md` is opened, and
/// anything else is refused before a byte is fetched (SPEC-0017 REQ "Manual
/// Download And Cache").
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
enum RommManualKind {
  /// Rendered page by page with the pdfium-backed renderer.
  pdf,

  /// Rendered as scrollable plain text.
  text,

  /// Rendered as scrollable text as well — Markdown source is readable as-is,
  /// and a Markdown widget is explicitly optional for v1 (SPEC-0017 design).
  markdown,

  /// Anything else. Never downloaded, never opened.
  unsupported,
}

/// A manual RomM holds for a ROM: where to fetch it and what it is.
///
/// Built from [RommRom.pathManual] — the server-relative path under
/// `/assets/romm/resources/` that the static manual route serves. Pure and
/// synchronous, so both the availability check in the game info tab and the
/// refusal in `RommService.downloadManual` reach the same verdict without a
/// request.
// Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
class RommManual {
  /// Server-relative path under `/assets/romm/resources/`, without a leading
  /// slash (RomM sends it either way).
  final String path;

  /// Lower-case extension without the dot, or an empty string when the path
  /// has none.
  final String extension;

  const RommManual._(this.path, this.extension);

  /// The extensions the viewer accepts, lower-case and without the dot.
  static const Set<String> supportedExtensions = {'pdf', 'txt', 'md'};

  /// A manual for [pathManual], or null when the ROM has none.
  ///
  /// An unsupported extension still produces a [RommManual] — the caller needs
  /// something to name in the refusal — but with [kind] `unsupported`.
  static RommManual? fromPath(String? pathManual) {
    final raw = pathManual?.trim() ?? '';
    if (raw.isEmpty) return null;
    final path = raw.startsWith('/') ? raw.substring(1) : raw;
    if (path.isEmpty) return null;

    // Only the last segment can carry the extension: a directory named
    // "manuals.v2" must not lend its suffix to an extensionless file.
    final lastSlash = path.lastIndexOf('/');
    final fileName = lastSlash == -1 ? path : path.substring(lastSlash + 1);
    final dot = fileName.lastIndexOf('.');
    final ext = dot <= 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    return RommManual._(path, ext);
  }

  /// What the viewer will do with this file.
  RommManualKind get kind => switch (extension) {
    'pdf' => RommManualKind.pdf,
    'txt' => RommManualKind.text,
    'md' => RommManualKind.markdown,
    _ => RommManualKind.unsupported,
  };

  /// Whether the viewer can open this file at all.
  bool get isSupported => kind != RommManualKind.unsupported;

  /// The name this manual is cached under: `<romId>.<ext>`.
  ///
  /// Keyed by the RomM rom id rather than the file name so a manual replaced
  /// on the server overwrites its own cache entry instead of leaving a second
  /// copy behind.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
  String cacheFileName(int romId) => '$romId.$extension';
}
