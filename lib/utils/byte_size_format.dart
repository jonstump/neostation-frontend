/// Human-readable byte counts for summaries ("12.3 MB", "980 B").
///
/// Binary units (1024), one decimal above bytes, trailing ".0" dropped so a
/// round count reads as "2 GB" rather than "2.0 GB". Unit symbols are the
/// same in every shipped language, so this stays a plain function and the
/// surrounding sentence is what gets localized.
String formatByteSize(int bytes) {
  if (bytes < 0) return formatByteSize(0);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes ${units[0]}';
  var text = value.toStringAsFixed(1);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${units[unit]}';
}
