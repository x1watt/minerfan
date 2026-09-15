import 'dart:typed_data';

/// RIPEMD-160 (Dobbertin, Bosselaers, Preneel). Bitcoin-family addresses
/// hash public keys with SHA-256 then RIPEMD-160 ([hash160]).
class Ripemd160 {
  static const List<int> _r = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
    3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
    1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
  ];
  static const List<int> _rr = [
    5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, //
    6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
    15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
    8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
  ];
  static const List<int> _s = [
    11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, //
    7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
    11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
    11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
  ];
  static const List<int> _ss = [
    8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, //
    9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
    9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
    15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
  ];
  static const List<int> _k = [0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e];
  static const List<int> _kk = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000];

  static Uint8List hash(List<int> data) {
    final len = data.length;
    final padded = Uint8List(((len + 8) ~/ 64 + 1) * 64);
    padded.setRange(0, len, data);
    padded[len] = 0x80;
    ByteData.sublistView(padded).setUint64(padded.length - 8, len * 8, Endian.little);
    final h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    final x = Uint32List(16);
    final bd = ByteData.sublistView(padded);
    for (var off = 0; off < padded.length; off += 64) {
      for (var i = 0; i < 16; i++) {
        x[i] = bd.getUint32(off + i * 4, Endian.little);
      }
      var al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4];
      var ar = h[0], br = h[1], cr = h[2], dr = h[3], er = h[4];
      for (var j = 0; j < 80; j++) {
        final round = j >> 4;
        var t = (al + _f(round, bl, cl, dl) + x[_r[j]] + _k[round]) & 0xffffffff;
        t = (_rotl(t, _s[j]) + el) & 0xffffffff;
        al = el;
        el = dl;
        dl = _rotl(cl, 10);
        cl = bl;
        bl = t;
        t = (ar + _f(4 - round, br, cr, dr) + x[_rr[j]] + _kk[round]) & 0xffffffff;
        t = (_rotl(t, _ss[j]) + er) & 0xffffffff;
        ar = er;
        er = dr;
        dr = _rotl(cr, 10);
        cr = br;
        br = t;
      }
      final t = (h[1] + cl + dr) & 0xffffffff;
      h[1] = (h[2] + dl + er) & 0xffffffff;
      h[2] = (h[3] + el + ar) & 0xffffffff;
      h[3] = (h[4] + al + br) & 0xffffffff;
      h[4] = (h[0] + bl + cr) & 0xffffffff;
      h[0] = t;
    }
    final out = ByteData(20);
    for (var i = 0; i < 5; i++) {
      out.setUint32(i * 4, h[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static int _f(int round, int x, int y, int z) => switch (round) {
        0 => x ^ y ^ z,
        1 => (x & y) | (~x & 0xffffffff & z),
        2 => ((x | (~y & 0xffffffff)) ^ z),
        3 => (x & z) | (y & ~z & 0xffffffff),
        _ => x ^ (y | (~z & 0xffffffff)),
      };

  static int _rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;
}
