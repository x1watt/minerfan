import 'dart:typed_data';

import 'mac.dart';

/// scrypt (RFC 7914) for any N, r, p. [ScryptHasher] keeps its scratch
/// memory between calls (128 * r * N bytes), so mining can reuse it.
class ScryptHasher {
  final int n, r, p;
  final Uint32List _v;
  final Uint32List _x;
  final Uint32List _y;
  final Uint32List _t = Uint32List(16);
  final Uint32List _b = Uint32List(16);

  ScryptHasher({this.n = 1024, this.r = 1, this.p = 1})
      : _v = Uint32List(32 * r * n),
        _x = Uint32List(32 * r),
        _y = Uint32List(32 * r) {
    if (n < 2 || n & (n - 1) != 0) throw ArgumentError('N must be a power of two above 1');
  }

  Uint8List hash(List<int> password, List<int> salt, int length) {
    final b = pbkdf2(HashFunction.sha256, password, salt, 1, p * 128 * r);
    final bd = ByteData.sublistView(b);
    for (var i = 0; i < p; i++) {
      final off = i * 128 * r;
      for (var k = 0; k < 32 * r; k++) {
        _x[k] = bd.getUint32(off + k * 4, Endian.little);
      }
      _roMix();
      for (var k = 0; k < 32 * r; k++) {
        bd.setUint32(off + k * 4, _x[k], Endian.little);
      }
    }
    return pbkdf2(HashFunction.sha256, password, b, 1, length);
  }

  void _roMix() {
    final words = 32 * r;
    for (var i = 0; i < n; i++) {
      _v.setRange(i * words, (i + 1) * words, _x);
      _blockMix();
    }
    for (var i = 0; i < n; i++) {
      final j = _x[(2 * r - 1) * 16] & (n - 1);
      final base = j * words;
      for (var k = 0; k < words; k++) {
        _x[k] ^= _v[base + k];
      }
      _blockMix();
    }
  }

  /// BlockMix with Salsa20/8 over 2r 64-byte blocks, in place in [_x].
  void _blockMix() {
    final x = _x;
    final y = _y;
    _b.setRange(0, 16, x, (2 * r - 1) * 16);
    for (var i = 0; i < 2 * r; i++) {
      for (var k = 0; k < 16; k++) {
        _b[k] ^= x[i * 16 + k];
      }
      _salsa8(_b);
      // Even blocks go to the first half, odd blocks to the second.
      final dst = (i.isEven ? i ~/ 2 : r + i ~/ 2) * 16;
      y.setRange(dst, dst + 16, _b);
    }
    x.setAll(0, y);
  }

  void _salsa8(Uint32List b) {
    final x = _t..setAll(0, b);
    for (var i = 0; i < 8; i += 2) {
      x[4] ^= _rotl(x[0] + x[12], 7);
      x[8] ^= _rotl(x[4] + x[0], 9);
      x[12] ^= _rotl(x[8] + x[4], 13);
      x[0] ^= _rotl(x[12] + x[8], 18);
      x[9] ^= _rotl(x[5] + x[1], 7);
      x[13] ^= _rotl(x[9] + x[5], 9);
      x[1] ^= _rotl(x[13] + x[9], 13);
      x[5] ^= _rotl(x[1] + x[13], 18);
      x[14] ^= _rotl(x[10] + x[6], 7);
      x[2] ^= _rotl(x[14] + x[10], 9);
      x[6] ^= _rotl(x[2] + x[14], 13);
      x[10] ^= _rotl(x[6] + x[2], 18);
      x[3] ^= _rotl(x[15] + x[11], 7);
      x[7] ^= _rotl(x[3] + x[15], 9);
      x[11] ^= _rotl(x[7] + x[3], 13);
      x[15] ^= _rotl(x[11] + x[7], 18);
      x[1] ^= _rotl(x[0] + x[3], 7);
      x[2] ^= _rotl(x[1] + x[0], 9);
      x[3] ^= _rotl(x[2] + x[1], 13);
      x[0] ^= _rotl(x[3] + x[2], 18);
      x[6] ^= _rotl(x[5] + x[4], 7);
      x[7] ^= _rotl(x[6] + x[5], 9);
      x[4] ^= _rotl(x[7] + x[6], 13);
      x[5] ^= _rotl(x[4] + x[7], 18);
      x[11] ^= _rotl(x[10] + x[9], 7);
      x[8] ^= _rotl(x[11] + x[10], 9);
      x[9] ^= _rotl(x[8] + x[11], 13);
      x[10] ^= _rotl(x[9] + x[8], 18);
      x[12] ^= _rotl(x[15] + x[14], 7);
      x[13] ^= _rotl(x[12] + x[15], 9);
      x[14] ^= _rotl(x[13] + x[12], 13);
      x[15] ^= _rotl(x[14] + x[13], 18);
    }
    for (var i = 0; i < 16; i++) {
      b[i] += x[i];
    }
  }

  static int _rotl(int v, int n) {
    v &= 0xffffffff;
    return ((v << n) | (v >>> (32 - n))) & 0xffffffff;
  }
}

/// scrypt with N=1024, r=1, p=1 of an 80-byte block header (password and
/// salt both the header), as Litecoin-family proof of work.
Uint8List scryptPow(List<int> header, [ScryptHasher? hasher]) =>
    (hasher ?? ScryptHasher()).hash(header, header, 32);
