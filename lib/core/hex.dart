import 'dart:typed_data';

/// Formats bytes as space-separated upper-case hex, e.g. `00 1D 06 00`.
String toHex(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Parses hex such as `001d0600`, `00 1D 06 00` or `0x00,0x1d`. Throws
/// [FormatException] on odd length or non-hex characters.
Uint8List fromHex(String input) {
  final cleaned = input
      .replaceAll(RegExp(r'0x', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s,:\-]'), '');
  if (cleaned.length.isOdd) {
    throw FormatException('Hex string has an odd number of digits', input);
  }
  if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(cleaned)) {
    throw FormatException('Not a hex string', input);
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
