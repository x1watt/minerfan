import 'dart:typed_data';

/// Single AES rounds with x86 AESENC / AESDEC semantics (the round key is
/// XORed last), on a 128-bit state held as four little-endian 32-bit columns.
///
/// Tables are generated at startup from the S-box definition, not copied.
class AesTables {
  final Uint32List e0 = Uint32List(256), e1 = Uint32List(256), e2 = Uint32List(256), e3 = Uint32List(256);
  final Uint32List d0 = Uint32List(256), d1 = Uint32List(256), d2 = Uint32List(256), d3 = Uint32List(256);

  static final AesTables instance = AesTables._();

  AesTables._() {
    final sbox = Uint8List(256), inv = Uint8List(256);
    // S-box: multiplicative inverse in GF(2^8) followed by the affine map.
    var p = 1, q = 1;
    do {
      p = p ^ ((p << 1) & 0xff) ^ ((p & 0x80) != 0 ? 0x1b : 0); // p *= 3
      q ^= q << 1; // q /= 3
      q ^= q << 2;
      q ^= q << 4;
      q &= 0xff;
      if ((q & 0x80) != 0) q ^= 0x09;
      final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
      sbox[p] = (x ^ 0x63) & 0xff;
    } while (p != 1);
    sbox[0] = 0x63;
    for (var i = 0; i < 256; i++) {
      inv[sbox[i]] = i;
    }
    for (var i = 0; i < 256; i++) {
      final s = sbox[i];
      final t = _gmul(s, 2) | (s << 8) | (s << 16) | (_gmul(s, 3) << 24);
      e0[i] = t;
      e1[i] = _rotl32(t, 8);
      e2[i] = _rotl32(t, 16);
      e3[i] = _rotl32(t, 24);
      final v = inv[i];
      final u = _gmul(v, 14) | (_gmul(v, 9) << 8) | (_gmul(v, 13) << 16) | (_gmul(v, 11) << 24);
      d0[i] = u;
      d1[i] = _rotl32(u, 8);
      d2[i] = _rotl32(u, 16);
      d3[i] = _rotl32(u, 24);
    }
  }

  static int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xff;
  static int _rotl32(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;

  static int _gmul(int a, int b) {
    var r = 0;
    while (b != 0) {
      if ((b & 1) != 0) r ^= a;
      a = (a << 1) ^ ((a & 0x80) != 0 ? 0x11b : 0);
      b >>= 1;
    }
    return r & 0xff;
  }
}

/// One AESENC round on columns s[o..o+3] with key k[ko..ko+3], in place.
void aesEncRound(Uint32List s, int o, List<int> k, int ko) {
  final t = AesTables.instance;
  final x0 = s[o], x1 = s[o + 1], x2 = s[o + 2], x3 = s[o + 3];
  s[o] = t.e0[x0 & 0xff] ^ t.e1[(x1 >> 8) & 0xff] ^ t.e2[(x2 >> 16) & 0xff] ^ t.e3[x3 >>> 24] ^ k[ko];
  s[o + 1] = t.e0[x1 & 0xff] ^ t.e1[(x2 >> 8) & 0xff] ^ t.e2[(x3 >> 16) & 0xff] ^ t.e3[x0 >>> 24] ^ k[ko + 1];
  s[o + 2] = t.e0[x2 & 0xff] ^ t.e1[(x3 >> 8) & 0xff] ^ t.e2[(x0 >> 16) & 0xff] ^ t.e3[x1 >>> 24] ^ k[ko + 2];
  s[o + 3] = t.e0[x3 & 0xff] ^ t.e1[(x0 >> 8) & 0xff] ^ t.e2[(x1 >> 16) & 0xff] ^ t.e3[x2 >>> 24] ^ k[ko + 3];
}

/// One AESDEC round on columns s[o..o+3] with key k[ko..ko+3], in place.
void aesDecRound(Uint32List s, int o, List<int> k, int ko) {
  final t = AesTables.instance;
  final x0 = s[o], x1 = s[o + 1], x2 = s[o + 2], x3 = s[o + 3];
  s[o] = t.d0[x0 & 0xff] ^ t.d1[(x3 >> 8) & 0xff] ^ t.d2[(x2 >> 16) & 0xff] ^ t.d3[x1 >>> 24] ^ k[ko];
  s[o + 1] = t.d0[x1 & 0xff] ^ t.d1[(x0 >> 8) & 0xff] ^ t.d2[(x3 >> 16) & 0xff] ^ t.d3[x2 >>> 24] ^ k[ko + 1];
  s[o + 2] = t.d0[x2 & 0xff] ^ t.d1[(x1 >> 8) & 0xff] ^ t.d2[(x0 >> 16) & 0xff] ^ t.d3[x3 >>> 24] ^ k[ko + 2];
  s[o + 3] = t.d0[x3 & 0xff] ^ t.d1[(x2 >> 8) & 0xff] ^ t.d2[(x1 >> 16) & 0xff] ^ t.d3[x0 >>> 24] ^ k[ko + 3];
}
