import 'dart:typed_data';

/// Monero/P2Pool varint: 7 bits per byte, little-endian, high bit set on
/// every byte except the last. Values are unsigned 64-bit.

void writeVarint(BytesBuilder out, int value) {
  var v = value;
  while ((v & ~0x7f) != 0) {
    out.addByte((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  out.addByte(v);
}

Uint8List encodeVarint(int value) {
  final b = BytesBuilder(copy: false);
  writeVarint(b, value);
  return b.takeBytes();
}

/// Reads a varint at [offset]; returns (value, bytesConsumed), or null if it
/// runs past the end or exceeds 64 bits.
(int, int)? readVarint(List<int> data, int offset) {
  var result = 0;
  var shift = 0;
  for (var i = offset; i < data.length; i++) {
    final b = data[i];
    if (shift == 63 && b > 1) return null;
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      // Reject non-canonical encodings with trailing zero groups.
      if (b == 0 && i != offset) return null;
      return (result, i - offset + 1);
    }
    shift += 7;
    if (shift > 63) return null;
  }
  return null;
}
