import 'dart:typed_data';

/// Hex and little-endian helpers shared by every module.

const _hexDigits = '0123456789abcdef';

String toHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb
      ..write(_hexDigits[(b >> 4) & 0xf])
      ..write(_hexDigits[b & 0xf]);
  }
  return sb.toString();
}

Uint8List fromHex(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('odd hex length', hex);
  }
  final out = Uint8List(hex.length >> 1);
  for (var i = 0; i < out.length; i++) {
    out[i] = (_nibble(hex.codeUnitAt(2 * i)) << 4) | _nibble(hex.codeUnitAt(2 * i + 1));
  }
  return out;
}

int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  throw FormatException('invalid hex digit ${String.fromCharCode(c)}');
}

int readU32LE(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int readU64LE(List<int> b, int o) =>
    b[o] |
    (b[o + 1] << 8) |
    (b[o + 2] << 16) |
    (b[o + 3] << 24) |
    (b[o + 4] << 32) |
    (b[o + 5] << 40) |
    (b[o + 6] << 48) |
    (b[o + 7] << 56);

void writeU32LE(List<int> b, int o, int v) {
  b[o] = v & 0xff;
  b[o + 1] = (v >> 8) & 0xff;
  b[o + 2] = (v >> 16) & 0xff;
  b[o + 3] = (v >> 24) & 0xff;
}

void writeU64LE(List<int> b, int o, int v) {
  for (var i = 0; i < 8; i++) {
    b[o + i] = (v >>> (8 * i)) & 0xff;
  }
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

Uint8List concatBytes(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}
