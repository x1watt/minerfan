import 'dart:typed_data';

/// BLAKE2b (RFC 7693), unkeyed, any digest length 1..64.
///
/// Words are Dart 64-bit ints; additions wrap like uint64_t.
class Blake2b {
  static const List<int> _iv = [
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, //
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
  ];

  static const List<List<int>> _sigma = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  ];

  final int digestLength;
  final Int64List _h = Int64List(8);
  final Uint8List _buf = Uint8List(128);
  final Int64List _m = Int64List(16);
  final Int64List _v = Int64List(16);
  int _bufLen = 0;
  int _t0 = 0; // byte counter (low 64 bits; inputs here never exceed 2^64)

  Blake2b([this.digestLength = 64]) {
    if (digestLength < 1 || digestLength > 64) {
      throw ArgumentError.value(digestLength, 'digestLength');
    }
    for (var i = 0; i < 8; i++) {
      _h[i] = _iv[i];
    }
    _h[0] ^= 0x01010000 ^ digestLength;
  }

  void update(List<int> data, [int start = 0, int? end]) {
    end ??= data.length;
    var i = start;
    while (i < end) {
      if (_bufLen == 128) {
        _t0 += 128;
        _compress(false);
        _bufLen = 0;
      }
      final take = (end - i) < (128 - _bufLen) ? end - i : 128 - _bufLen;
      _buf.setRange(_bufLen, _bufLen + take, data, i);
      _bufLen += take;
      i += take;
    }
  }

  Uint8List digest() {
    _t0 += _bufLen;
    for (var i = _bufLen; i < 128; i++) {
      _buf[i] = 0;
    }
    _compress(true);
    final out = Uint8List(digestLength);
    for (var i = 0; i < digestLength; i++) {
      out[i] = (_h[i >> 3] >>> (8 * (i & 7))) & 0xff;
    }
    return out;
  }

  void _compress(bool last) {
    final m = _m, v = _v, h = _h, b = _buf;
    for (var i = 0; i < 16; i++) {
      final o = i * 8;
      m[i] = b[o] |
          (b[o + 1] << 8) |
          (b[o + 2] << 16) |
          (b[o + 3] << 24) |
          (b[o + 4] << 32) |
          (b[o + 5] << 40) |
          (b[o + 6] << 48) |
          (b[o + 7] << 56);
    }
    for (var i = 0; i < 8; i++) {
      v[i] = h[i];
      v[i + 8] = _iv[i];
    }
    v[12] ^= _t0;
    if (last) v[14] = ~v[14];
    for (var r = 0; r < 12; r++) {
      final s = _sigma[r % 10];
      _g(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
      _g(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
      _g(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
      _g(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
      _g(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
      _g(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
      _g(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
      _g(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for (var i = 0; i < 8; i++) {
      h[i] ^= v[i] ^ v[i + 8];
    }
  }

  static void _g(Int64List v, int a, int b, int c, int d, int x, int y) {
    var va = v[a], vb = v[b], vc = v[c], vd = v[d];
    va = va + vb + x;
    vd ^= va;
    vd = (vd >>> 32) | (vd << 32);
    vc = vc + vd;
    vb ^= vc;
    vb = (vb >>> 24) | (vb << 40);
    va = va + vb + y;
    vd ^= va;
    vd = (vd >>> 16) | (vd << 48);
    vc = vc + vd;
    vb ^= vc;
    vb = (vb >>> 63) | (vb << 1);
    v[a] = va;
    v[b] = vb;
    v[c] = vc;
    v[d] = vd;
  }

  static Uint8List hash(List<int> data, [int digestLength = 64]) =>
      (Blake2b(digestLength)..update(data)).digest();

  /// Restarts this hasher for a new message of the same digest length.
  void reset() {
    for (var i = 0; i < 8; i++) {
      _h[i] = _iv[i];
    }
    _h[0] ^= 0x01010000 ^ digestLength;
    _bufLen = 0;
    _t0 = 0;
  }

  /// Finishes the message and writes the digest into [out] at [offset],
  /// without allocating.
  void digestInto(Uint8List out, int offset) {
    _t0 += _bufLen;
    for (var i = _bufLen; i < 128; i++) {
      _buf[i] = 0;
    }
    _compress(true);
    for (var i = 0; i < digestLength; i++) {
      out[offset + i] = (_h[i >> 3] >>> (8 * (i & 7))) & 0xff;
    }
  }
}
