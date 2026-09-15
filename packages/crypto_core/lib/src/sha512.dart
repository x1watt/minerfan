import 'dart:typed_data';

/// SHA-512 (FIPS 180-4). Uses 64-bit integer arithmetic, so native
/// platforms only (not the web).
class Sha512 {
  static const List<int> _k = [
    0x428a2f98d728ae22, 0x7137449123ef65cd, -0x4a3f043013b2c4d1, -0x164a245a7e762444,
    0x3956c25bf348b538, 0x59f111f1b605d019, -0x6dc07d5b50e6b065, -0x54e3a12a25927ee8,
    -0x27f855675cfcfdbe, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f, -0x7f214e01c4e9694f, -0x6423f958da38edcb, -0x3e640e8b3096d96c,
    -0x1b64963e610eb52e, -0x1041b879c7b0da1d, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
    0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
    -0x67c1aead11992055, -0x57ce3992d24bcdf0, -0x4ffcd8376704dec1, -0x40a680384110f11c,
    -0x391ff40cc257703e, -0x2a586eb86cf558db, 0x06ca6351e003826f, 0x142929670a0e6e70,
    0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
    0x650a73548baf63de, 0x766a0abb3c77b2a8, -0x7e3d36d1b812511a, -0x6d8dd37aeb7dcac5,
    -0x5d40175eb30efc9c, -0x57e599b443bdcfff, -0x3db4748f2f07686f, -0x3893ae5cf9ab41d0,
    -0x2e6d17e62910ade8, -0x2966f9dbaa9a56f0, -0x0bf1ca7aa88edfd6, 0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc, 0x78a5636f43172f60, -0x7b3787eb5e0f548e, -0x7338fdf7e59bc614,
    -0x6f410005dc9ce1d8, -0x5baf9314217d4217, -0x41065c084d3986eb, -0x398e870d1c8dacd5,
    -0x35d8c13115d99e64, -0x2e794738de3f3df9, -0x15258229321f14e2, -0x0a82b08011912e88,
    0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
    0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
  ];

  final Int64List _h = Int64List.fromList([
    0x6a09e667f3bcc908, -0x4498517a7b3558c5, 0x3c6ef372fe94f82b, -0x5ab00ac5a0e2c90f,
    0x510e527fade682d1, -0x64fa9773d4c193e1, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
  ]);
  final Uint8List _buf = Uint8List(128);
  final Int64List _w = Int64List(80);
  int _bufLen = 0;
  int _total = 0;

  static Uint8List hash(List<int> data) => (Sha512()..update(data)).digest();

  void update(List<int> data) {
    for (var i = 0; i < data.length; i++) {
      _buf[_bufLen++] = data[i];
      if (_bufLen == 128) {
        _block();
        _bufLen = 0;
      }
    }
    _total += data.length;
  }

  Uint8List digest() {
    final bits = _total * 8;
    update(const [0x80]);
    while (_bufLen != 112) {
      update(const [0]);
    }
    final len = ByteData(16)..setUint64(8, bits);
    update(len.buffer.asUint8List());
    final out = ByteData(64);
    for (var i = 0; i < 8; i++) {
      out.setInt64(i * 8, _h[i]);
    }
    return out.buffer.asUint8List();
  }

  static int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

  void _block() {
    final w = _w;
    final bd = ByteData.sublistView(_buf);
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getInt64(i * 8);
    }
    for (var i = 16; i < 80; i++) {
      final a = w[i - 15], b = w[i - 2];
      final s0 = _rotr(a, 1) ^ _rotr(a, 8) ^ (a >>> 7);
      final s1 = _rotr(b, 19) ^ _rotr(b, 61) ^ (b >>> 6);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3], e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var i = 0; i < 80; i++) {
      final s1 = _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41);
      final ch = (e & f) ^ (~e & g);
      final t1 = h + s1 + ch + _k[i] + w[i];
      final s0 = _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = s0 + maj;
      h = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }
}
