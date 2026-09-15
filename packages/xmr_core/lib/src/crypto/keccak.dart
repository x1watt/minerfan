import 'dart:typed_data';

/// Original Keccak (padding byte 0x01, not SHA-3's 0x06), as Monero's
/// `cn_fast_hash` and P2Pool use it. Rate 136 bytes for the 256-bit digest.
class Keccak {
  static const List<int> _rc = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
  ];

  static const int rate = 136;

  final Int64List _s = Int64List(25);
  final Uint8List _buf = Uint8List(rate);
  int _bufLen = 0;

  void update(List<int> data, [int start = 0, int? end]) {
    end ??= data.length;
    for (var i = start; i < end; i++) {
      _buf[_bufLen++] = data[i];
      if (_bufLen == rate) {
        _absorb();
        _bufLen = 0;
      }
    }
  }

  /// Finishes the hash and returns the first [length] bytes of the state.
  Uint8List digest([int length = 32]) {
    for (var i = _bufLen; i < rate; i++) {
      _buf[i] = 0;
    }
    _buf[_bufLen] |= 0x01;
    _buf[rate - 1] |= 0x80;
    _absorb();
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = (_s[i >> 3] >>> (8 * (i & 7))) & 0xff;
    }
    return out;
  }

  /// Full 200-byte state after padding (used by the Monero tree hash helpers
  /// and `keccak1600`).
  Uint8List digestState() => digest(200);

  void _absorb() {
    final b = _buf;
    for (var i = 0; i < rate ~/ 8; i++) {
      final o = i * 8;
      _s[i] ^= b[o] |
          (b[o + 1] << 8) |
          (b[o + 2] << 16) |
          (b[o + 3] << 24) |
          (b[o + 4] << 32) |
          (b[o + 5] << 40) |
          (b[o + 6] << 48) |
          (b[o + 7] << 56);
    }
    keccakF1600(_s);
  }

  static int _rotl(int x, int n) => n == 0 ? x : (x << n) | (x >>> (64 - n));

  static void keccakF1600(Int64List a) {
    for (var round = 0; round < 24; round++) {
      // theta
      final c0 = a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20];
      final c1 = a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21];
      final c2 = a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22];
      final c3 = a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23];
      final c4 = a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24];
      final d0 = c4 ^ _rotl(c1, 1);
      final d1 = c0 ^ _rotl(c2, 1);
      final d2 = c1 ^ _rotl(c3, 1);
      final d3 = c2 ^ _rotl(c4, 1);
      final d4 = c3 ^ _rotl(c0, 1);
      for (var i = 0; i < 25; i += 5) {
        a[i] ^= d0;
        a[i + 1] ^= d1;
        a[i + 2] ^= d2;
        a[i + 3] ^= d3;
        a[i + 4] ^= d4;
      }
      // rho and pi
      final b00 = a[0];
      final b10 = _rotl(a[1], 1);
      final b20 = _rotl(a[2], 62);
      final b05 = _rotl(a[3], 28);
      final b15 = _rotl(a[4], 27);
      final b16 = _rotl(a[5], 36);
      final b01 = _rotl(a[6], 44);
      final b11 = _rotl(a[7], 6);
      final b21 = _rotl(a[8], 55);
      final b06 = _rotl(a[9], 20);
      final b07 = _rotl(a[10], 3);
      final b17 = _rotl(a[11], 10);
      final b02 = _rotl(a[12], 43);
      final b12 = _rotl(a[13], 25);
      final b22 = _rotl(a[14], 39);
      final b23 = _rotl(a[15], 41);
      final b08 = _rotl(a[16], 45);
      final b18 = _rotl(a[17], 15);
      final b03 = _rotl(a[18], 21);
      final b13 = _rotl(a[19], 8);
      final b14 = _rotl(a[20], 18);
      final b24 = _rotl(a[21], 2);
      final b09 = _rotl(a[22], 61);
      final b19 = _rotl(a[23], 56);
      final b04 = _rotl(a[24], 14);
      // chi
      a[0] = b00 ^ (~b01 & b02);
      a[1] = b01 ^ (~b02 & b03);
      a[2] = b02 ^ (~b03 & b04);
      a[3] = b03 ^ (~b04 & b00);
      a[4] = b04 ^ (~b00 & b01);
      a[5] = b05 ^ (~b06 & b07);
      a[6] = b06 ^ (~b07 & b08);
      a[7] = b07 ^ (~b08 & b09);
      a[8] = b08 ^ (~b09 & b05);
      a[9] = b09 ^ (~b05 & b06);
      a[10] = b10 ^ (~b11 & b12);
      a[11] = b11 ^ (~b12 & b13);
      a[12] = b12 ^ (~b13 & b14);
      a[13] = b13 ^ (~b14 & b10);
      a[14] = b14 ^ (~b10 & b11);
      a[15] = b15 ^ (~b16 & b17);
      a[16] = b16 ^ (~b17 & b18);
      a[17] = b17 ^ (~b18 & b19);
      a[18] = b18 ^ (~b19 & b15);
      a[19] = b19 ^ (~b15 & b16);
      a[20] = b20 ^ (~b21 & b22);
      a[21] = b21 ^ (~b22 & b23);
      a[22] = b22 ^ (~b23 & b24);
      a[23] = b23 ^ (~b24 & b20);
      a[24] = b24 ^ (~b20 & b21);
      // iota
      a[0] ^= _rc[round];
    }
  }

  /// Keccak-256 of [data] (`cn_fast_hash`).
  static Uint8List hash256(List<int> data) => (Keccak()..update(data)).digest(32);
}
