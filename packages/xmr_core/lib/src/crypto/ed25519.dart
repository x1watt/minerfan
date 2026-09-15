import 'dart:typed_data';

/// Ed25519 group arithmetic as Monero uses it (point compression, fixed- and
/// variable-base scalar multiplication, scalars modulo l). Nothing here
/// handles secret keys, so everything is variable-time.
///
/// Field elements use the ref10 layout: ten signed limbs alternating 26 and
/// 25 bits, value = sum(f[i] * 2^ceil(25.5 * i)).

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

/// Group order l = 2^252 + 27742317777372353535851937790883648493.
final BigInt groupOrder = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');

class Fe {
  final Int64List v;
  Fe() : v = Int64List(10);
  Fe._(this.v);

  factory Fe.fromBigInt(BigInt x) => Fe.fromBytes(_bigToBytes(x % _p));

  factory Fe.fromBytes(List<int> s, [int o = 0]) {
    int load3(int i) => s[o + i] | (s[o + i + 1] << 8) | (s[o + i + 2] << 16);
    int load4(int i) => load3(i) | (s[o + i + 3] << 24);
    var h0 = load4(0);
    var h1 = load3(4) << 6;
    var h2 = load3(7) << 5;
    var h3 = load3(10) << 3;
    var h4 = load3(13) << 2;
    var h5 = load4(16);
    var h6 = load3(20) << 7;
    var h7 = load3(23) << 5;
    var h8 = load3(26) << 4;
    var h9 = (load3(29) & 8388607) << 2;
    int c;
    c = (h9 + (1 << 24)) >> 25;
    h0 += c * 19;
    h9 -= c << 25;
    c = (h1 + (1 << 24)) >> 25;
    h2 += c;
    h1 -= c << 25;
    c = (h3 + (1 << 24)) >> 25;
    h4 += c;
    h3 -= c << 25;
    c = (h5 + (1 << 24)) >> 25;
    h6 += c;
    h5 -= c << 25;
    c = (h7 + (1 << 24)) >> 25;
    h8 += c;
    h7 -= c << 25;
    c = (h0 + (1 << 25)) >> 26;
    h1 += c;
    h0 -= c << 26;
    c = (h2 + (1 << 25)) >> 26;
    h3 += c;
    h2 -= c << 26;
    c = (h4 + (1 << 25)) >> 26;
    h5 += c;
    h4 -= c << 26;
    c = (h6 + (1 << 25)) >> 26;
    h7 += c;
    h6 -= c << 26;
    c = (h8 + (1 << 25)) >> 26;
    h9 += c;
    h8 -= c << 26;
    return Fe._(Int64List.fromList([h0, h1, h2, h3, h4, h5, h6, h7, h8, h9]));
  }

  Fe copy() => Fe._(Int64List.fromList(v));

  Uint8List toBytes() {
    final h = v;
    var h0 = h[0], h1 = h[1], h2 = h[2], h3 = h[3], h4 = h[4];
    var h5 = h[5], h6 = h[6], h7 = h[7], h8 = h[8], h9 = h[9];
    var q = (19 * h9 + (1 << 24)) >> 25;
    q = (h0 + q) >> 26;
    q = (h1 + q) >> 25;
    q = (h2 + q) >> 26;
    q = (h3 + q) >> 25;
    q = (h4 + q) >> 26;
    q = (h5 + q) >> 25;
    q = (h6 + q) >> 26;
    q = (h7 + q) >> 25;
    q = (h8 + q) >> 26;
    q = (h9 + q) >> 25;
    h0 += 19 * q;
    int c;
    c = h0 >> 26;
    h1 += c;
    h0 -= c << 26;
    c = h1 >> 25;
    h2 += c;
    h1 -= c << 25;
    c = h2 >> 26;
    h3 += c;
    h2 -= c << 26;
    c = h3 >> 25;
    h4 += c;
    h3 -= c << 25;
    c = h4 >> 26;
    h5 += c;
    h4 -= c << 26;
    c = h5 >> 25;
    h6 += c;
    h5 -= c << 25;
    c = h6 >> 26;
    h7 += c;
    h6 -= c << 26;
    c = h7 >> 25;
    h8 += c;
    h7 -= c << 25;
    c = h8 >> 26;
    h9 += c;
    h8 -= c << 26;
    c = h9 >> 25;
    h9 -= c << 25;
    final s = Uint8List(32);
    s[0] = h0;
    s[1] = h0 >> 8;
    s[2] = h0 >> 16;
    s[3] = (h0 >> 24) | (h1 << 2);
    s[4] = h1 >> 6;
    s[5] = h1 >> 14;
    s[6] = (h1 >> 22) | (h2 << 3);
    s[7] = h2 >> 5;
    s[8] = h2 >> 13;
    s[9] = (h2 >> 21) | (h3 << 5);
    s[10] = h3 >> 3;
    s[11] = h3 >> 11;
    s[12] = (h3 >> 19) | (h4 << 6);
    s[13] = h4 >> 2;
    s[14] = h4 >> 10;
    s[15] = h4 >> 18;
    s[16] = h5;
    s[17] = h5 >> 8;
    s[18] = h5 >> 16;
    s[19] = (h5 >> 24) | (h6 << 1);
    s[20] = h6 >> 7;
    s[21] = h6 >> 15;
    s[22] = (h6 >> 23) | (h7 << 3);
    s[23] = h7 >> 5;
    s[24] = h7 >> 13;
    s[25] = (h7 >> 21) | (h8 << 4);
    s[26] = h8 >> 4;
    s[27] = h8 >> 12;
    s[28] = (h8 >> 20) | (h9 << 6);
    s[29] = h9 >> 2;
    s[30] = h9 >> 10;
    s[31] = h9 >> 18;
    return s;
  }

  bool get isNegative => (toBytes()[0] & 1) != 0;

  bool get isZero {
    final b = toBytes();
    var acc = 0;
    for (final x in b) {
      acc |= x;
    }
    return acc == 0;
  }

  static final Fe zero = Fe();
  static final Fe one = Fe()..v[0] = 1;
}

Uint8List _bigToBytes(BigInt x) {
  final out = Uint8List(32);
  var t = x;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    out[i] = (t & mask).toInt();
    t >>= 8;
  }
  return out;
}

BigInt bytesToBigLE(List<int> b) {
  var x = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    x = (x << 8) | BigInt.from(b[i]);
  }
  return x;
}

// ---- field operations (out may alias inputs) ----------------------------

void feAdd(Fe out, Fe f, Fe g) {
  final o = out.v, a = f.v, b = g.v;
  for (var i = 0; i < 10; i++) {
    o[i] = a[i] + b[i];
  }
  _carry(o);
}

void feSub(Fe out, Fe f, Fe g) {
  final o = out.v, a = f.v, b = g.v;
  for (var i = 0; i < 10; i++) {
    o[i] = a[i] - b[i];
  }
  _carry(o);
}

void feNeg(Fe out, Fe f) {
  final o = out.v, a = f.v;
  for (var i = 0; i < 10; i++) {
    o[i] = -a[i];
  }
  _carry(o);
}

/// Brings every limb back to about 26/25 bits so products stay in 64 bits.
@pragma('vm:unsafe:no-bounds-checks')
void _carry(Int64List h) {
  int c;
  c = (h[0] + (1 << 25)) >> 26;
  h[1] += c;
  h[0] -= c << 26;
  c = (h[4] + (1 << 25)) >> 26;
  h[5] += c;
  h[4] -= c << 26;
  c = (h[1] + (1 << 24)) >> 25;
  h[2] += c;
  h[1] -= c << 25;
  c = (h[5] + (1 << 24)) >> 25;
  h[6] += c;
  h[5] -= c << 25;
  c = (h[2] + (1 << 25)) >> 26;
  h[3] += c;
  h[2] -= c << 26;
  c = (h[6] + (1 << 25)) >> 26;
  h[7] += c;
  h[6] -= c << 26;
  c = (h[3] + (1 << 24)) >> 25;
  h[4] += c;
  h[3] -= c << 25;
  c = (h[7] + (1 << 24)) >> 25;
  h[8] += c;
  h[7] -= c << 25;
  c = (h[4] + (1 << 25)) >> 26;
  h[5] += c;
  h[4] -= c << 26;
  c = (h[8] + (1 << 25)) >> 26;
  h[9] += c;
  h[8] -= c << 26;
  c = (h[9] + (1 << 24)) >> 25;
  h[0] += c * 19;
  h[9] -= c << 25;
  c = (h[0] + (1 << 25)) >> 26;
  h[1] += c;
  h[0] -= c << 26;
}

void feCopy(Fe out, Fe f) {
  for (var i = 0; i < 10; i++) {
    out.v[i] = f.v[i];
  }
}

@pragma('vm:unsafe:no-bounds-checks')
void feMul(Fe out, Fe fa, Fe ga) {
  final f = fa.v, g = ga.v;
  final f0 = f[0], f1 = f[1], f2 = f[2], f3 = f[3], f4 = f[4];
  final f5 = f[5], f6 = f[6], f7 = f[7], f8 = f[8], f9 = f[9];
  final g0 = g[0], g1 = g[1], g2 = g[2], g3 = g[3], g4 = g[4];
  final g5 = g[5], g6 = g[6], g7 = g[7], g8 = g[8], g9 = g[9];
  final g1_19 = 19 * g1, g2_19 = 19 * g2, g3_19 = 19 * g3, g4_19 = 19 * g4, g5_19 = 19 * g5;
  final g6_19 = 19 * g6, g7_19 = 19 * g7, g8_19 = 19 * g8, g9_19 = 19 * g9;
  final f1_2 = 2 * f1, f3_2 = 2 * f3, f5_2 = 2 * f5, f7_2 = 2 * f7, f9_2 = 2 * f9;

  var h0 = f0 * g0 + f1_2 * g9_19 + f2 * g8_19 + f3_2 * g7_19 + f4 * g6_19 +
      f5_2 * g5_19 + f6 * g4_19 + f7_2 * g3_19 + f8 * g2_19 + f9_2 * g1_19;
  var h1 = f0 * g1 + f1 * g0 + f2 * g9_19 + f3 * g8_19 + f4 * g7_19 +
      f5 * g6_19 + f6 * g5_19 + f7 * g4_19 + f8 * g3_19 + f9 * g2_19;
  var h2 = f0 * g2 + f1_2 * g1 + f2 * g0 + f3_2 * g9_19 + f4 * g8_19 +
      f5_2 * g7_19 + f6 * g6_19 + f7_2 * g5_19 + f8 * g4_19 + f9_2 * g3_19;
  var h3 = f0 * g3 + f1 * g2 + f2 * g1 + f3 * g0 + f4 * g9_19 +
      f5 * g8_19 + f6 * g7_19 + f7 * g6_19 + f8 * g5_19 + f9 * g4_19;
  var h4 = f0 * g4 + f1_2 * g3 + f2 * g2 + f3_2 * g1 + f4 * g0 +
      f5_2 * g9_19 + f6 * g8_19 + f7_2 * g7_19 + f8 * g6_19 + f9_2 * g5_19;
  var h5 = f0 * g5 + f1 * g4 + f2 * g3 + f3 * g2 + f4 * g1 +
      f5 * g0 + f6 * g9_19 + f7 * g8_19 + f8 * g7_19 + f9 * g6_19;
  var h6 = f0 * g6 + f1_2 * g5 + f2 * g4 + f3_2 * g3 + f4 * g2 +
      f5_2 * g1 + f6 * g0 + f7_2 * g9_19 + f8 * g8_19 + f9_2 * g7_19;
  var h7 = f0 * g7 + f1 * g6 + f2 * g5 + f3 * g4 + f4 * g3 +
      f5 * g2 + f6 * g1 + f7 * g0 + f8 * g9_19 + f9 * g8_19;
  var h8 = f0 * g8 + f1_2 * g7 + f2 * g6 + f3_2 * g5 + f4 * g4 +
      f5_2 * g3 + f6 * g2 + f7_2 * g1 + f8 * g0 + f9_2 * g9_19;
  var h9 = f0 * g9 + f1 * g8 + f2 * g7 + f3 * g6 + f4 * g5 +
      f5 * g4 + f6 * g3 + f7 * g2 + f8 * g1 + f9 * g0;

  int c;
  c = (h0 + (1 << 25)) >> 26;
  h1 += c;
  h0 -= c << 26;
  c = (h4 + (1 << 25)) >> 26;
  h5 += c;
  h4 -= c << 26;
  c = (h1 + (1 << 24)) >> 25;
  h2 += c;
  h1 -= c << 25;
  c = (h5 + (1 << 24)) >> 25;
  h6 += c;
  h5 -= c << 25;
  c = (h2 + (1 << 25)) >> 26;
  h3 += c;
  h2 -= c << 26;
  c = (h6 + (1 << 25)) >> 26;
  h7 += c;
  h6 -= c << 26;
  c = (h3 + (1 << 24)) >> 25;
  h4 += c;
  h3 -= c << 25;
  c = (h7 + (1 << 24)) >> 25;
  h8 += c;
  h7 -= c << 25;
  c = (h4 + (1 << 25)) >> 26;
  h5 += c;
  h4 -= c << 26;
  c = (h8 + (1 << 25)) >> 26;
  h9 += c;
  h8 -= c << 26;
  c = (h9 + (1 << 24)) >> 25;
  h0 += c * 19;
  h9 -= c << 25;
  c = (h0 + (1 << 25)) >> 26;
  h1 += c;
  h0 -= c << 26;

  final h = out.v;
  h[0] = h0;
  h[1] = h1;
  h[2] = h2;
  h[3] = h3;
  h[4] = h4;
  h[5] = h5;
  h[6] = h6;
  h[7] = h7;
  h[8] = h8;
  h[9] = h9;
}

void feSq(Fe out, Fe f) => feMul(out, f, f);

void _sqN(Fe out, Fe f, int n) {
  feSq(out, f);
  for (var i = 1; i < n; i++) {
    feSq(out, out);
  }
}

/// z^(p-2)
void feInvert(Fe out, Fe z) {
  final t0 = Fe(), t1 = Fe(), t2 = Fe(), t3 = Fe();
  feSq(t0, z);
  _sqN(t1, t0, 2);
  feMul(t1, z, t1);
  feMul(t0, t0, t1);
  feSq(t2, t0);
  feMul(t1, t1, t2);
  _sqN(t2, t1, 5);
  feMul(t1, t2, t1);
  _sqN(t2, t1, 10);
  feMul(t2, t2, t1);
  _sqN(t3, t2, 20);
  feMul(t2, t3, t2);
  _sqN(t2, t2, 10);
  feMul(t1, t2, t1);
  _sqN(t2, t1, 50);
  feMul(t2, t2, t1);
  _sqN(t3, t2, 100);
  feMul(t2, t3, t2);
  _sqN(t2, t2, 50);
  feMul(t1, t2, t1);
  _sqN(t1, t1, 5);
  feMul(out, t1, t0);
}

/// z^((p-5)/8) = z^(2^252 - 3)
void fePow22523(Fe out, Fe z) {
  final t0 = Fe(), t1 = Fe(), t2 = Fe();
  feSq(t0, z);
  _sqN(t1, t0, 2);
  feMul(t1, z, t1);
  feMul(t0, t0, t1);
  feSq(t0, t0);
  feMul(t0, t1, t0);
  _sqN(t1, t0, 5);
  feMul(t0, t1, t0);
  _sqN(t1, t0, 10);
  feMul(t1, t1, t0);
  _sqN(t2, t1, 20);
  feMul(t1, t2, t1);
  _sqN(t1, t1, 10);
  feMul(t0, t1, t0);
  _sqN(t1, t0, 50);
  feMul(t1, t1, t0);
  _sqN(t2, t1, 100);
  feMul(t1, t2, t1);
  _sqN(t1, t1, 50);
  feMul(t0, t1, t0);
  _sqN(t0, t0, 2);
  feMul(out, t0, z);
}

// ---- curve constants ------------------------------------------------------

final Fe curveD = Fe.fromBigInt((-BigInt.from(121665) * BigInt.from(121666).modInverse(_p)) % _p);
final Fe curveD2 = () {
  final r = Fe();
  feAdd(r, curveD, curveD);
  return Fe.fromBytes(r.toBytes());
}();
final Fe sqrtM1 = Fe.fromBigInt(BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p));

// ---- points in extended coordinates (X:Y:Z:T), x = X/Z, y = Y/Z, T = XY/Z ---

class Point {
  final Fe x, y, z, t;
  Point(this.x, this.y, this.z, this.t);

  factory Point.identity() => Point(Fe(), Fe.one.copy(), Fe.one.copy(), Fe());

  Point copy() => Point(x.copy(), y.copy(), z.copy(), t.copy());

  /// Decodes a compressed point. Returns null for encodings Monero's
  /// `ge_frombytes_vartime` rejects: non-canonical y, no square root, or
  /// x = 0 with the sign bit set.
  static Point? decode(List<int> s) {
    // Canonical y: reject 2^255-19 <= y < 2^255.
    if ((s[31] & 0x7f) == 0x7f && s[0] >= 0xed) {
      var allFF = true;
      for (var i = 1; i < 31; i++) {
        if (s[i] != 0xff) {
          allFF = false;
          break;
        }
      }
      if (allFF) return null;
    }
    final y = Fe.fromBytes(s);
    final z = Fe.one.copy();
    final u = Fe(), v = Fe(), v3 = Fe(), vxx = Fe(), check = Fe(), x = Fe();
    feSq(u, y);
    feMul(v, u, curveD);
    feSub(u, u, z); // u = y^2 - 1
    feAdd(v, v, z); // v = d*y^2 + 1
    feSq(v3, v);
    feMul(v3, v3, v); // v^3
    feSq(x, v3);
    feMul(x, x, v);
    feMul(x, x, u); // u*v^7
    fePow22523(x, x);
    feMul(x, x, v3);
    feMul(x, x, u); // x = u*v^3*(u*v^7)^((p-5)/8)
    feSq(vxx, x);
    feMul(vxx, vxx, v);
    feSub(check, vxx, u);
    if (!check.isZero) {
      feAdd(check, vxx, u);
      if (!check.isZero) return null;
      feMul(x, x, sqrtM1);
    }
    final sign = (s[31] >> 7) & 1;
    if (x.isNegative != (sign == 1)) {
      if (x.isZero) return null;
      feNeg(x, x);
    }
    final t = Fe();
    feMul(t, x, y);
    return Point(Fe.fromBytes(x.toBytes()), y, z, t);
  }

  Uint8List encode() {
    final recip = Fe(), ax = Fe(), ay = Fe();
    feInvert(recip, z);
    feMul(ax, x, recip);
    feMul(ay, y, recip);
    final s = ay.toBytes();
    if (ax.isNegative) s[31] |= 0x80;
    return s;
  }
}

/// r = p + q
void pointAdd(Point r, Point p, Point q) {
  final a = Fe(), b = Fe(), c = Fe(), d = Fe(), t = Fe();
  feSub(a, p.y, p.x);
  feSub(t, q.y, q.x);
  feMul(a, a, t);
  feAdd(b, p.y, p.x);
  feAdd(t, q.y, q.x);
  feMul(b, b, t);
  feMul(c, p.t, q.t);
  feMul(c, c, curveD2);
  feMul(d, p.z, q.z);
  feAdd(d, d, d);
  final e = Fe(), f = Fe(), g = Fe(), h = Fe();
  feSub(e, b, a);
  feSub(f, d, c);
  feAdd(g, d, c);
  feAdd(h, b, a);
  feMul(r.x, e, f);
  feMul(r.y, g, h);
  feMul(r.t, e, h);
  feMul(r.z, f, g);
}

/// r = 2p
void pointDouble(Point r, Point p) {
  final a = Fe(), b = Fe(), c = Fe(), e = Fe(), g = Fe(), f = Fe(), h = Fe();
  feSq(a, p.x);
  feSq(b, p.y);
  feSq(c, p.z);
  feAdd(c, c, c);
  feAdd(e, p.x, p.y);
  feSq(e, e);
  feSub(e, e, a);
  feSub(e, e, b); // E = (X+Y)^2 - A - B = 2XY
  feSub(g, b, a); // G = -A + B
  feSub(f, g, c); // F = G - C
  feNeg(h, a);
  feSub(h, h, b); // H = -A - B
  feMul(r.x, e, f);
  feMul(r.y, g, h);
  feMul(r.t, e, h);
  feMul(r.z, f, g);
}

/// 8*p
Point pointMul8(Point p) {
  final r = p.copy();
  pointDouble(r, r);
  pointDouble(r, r);
  pointDouble(r, r);
  return r;
}

/// Variable-base scalar multiplication, 4-bit fixed window. [scalar] is 32
/// little-endian bytes (not required to be reduced).
Point scalarMult(List<int> scalar, Point p) {
  final table = List<Point>.filled(16, Point.identity());
  table[1] = p.copy();
  for (var i = 2; i < 16; i++) {
    final q = Point.identity();
    pointAdd(q, table[i - 1], p);
    table[i] = q;
  }
  final r = Point.identity();
  for (var i = 63; i >= 0; i--) {
    pointDouble(r, r);
    pointDouble(r, r);
    pointDouble(r, r);
    pointDouble(r, r);
    final nib = (scalar[i >> 1] >> ((i & 1) * 4)) & 0xf;
    if (nib != 0) pointAdd(r, r, table[nib]);
  }
  return r;
}

/// The standard base point.
final Point basePoint = Point.decode(List<int>.generate(32, (i) => i == 0 ? 0x58 : 0x66))!;

/// baseTable[i][j] = j * 16^i * B for 64 nibble positions.
final List<List<Point>> _baseTable = () {
  final rows = <List<Point>>[];
  var bi = basePoint.copy();
  for (var i = 0; i < 64; i++) {
    final row = List<Point>.filled(16, Point.identity());
    row[1] = bi.copy();
    for (var j = 2; j < 16; j++) {
      final q = Point.identity();
      pointAdd(q, row[j - 1], bi);
      row[j] = q;
    }
    rows.add(row);
    final next = row[15].copy();
    pointAdd(next, next, bi); // 16 * bi
    bi = next;
  }
  return rows;
}();

/// scalar * B using the precomputed table (64 additions, no doublings).
Point scalarMultBase(List<int> scalar) {
  final r = Point.identity();
  for (var i = 0; i < 64; i++) {
    final nib = (scalar[i >> 1] >> ((i & 1) * 4)) & 0xf;
    if (nib != 0) pointAdd(r, r, _baseTable[i][nib]);
  }
  return r;
}

// ---- scalars modulo l -----------------------------------------------------

/// Reduces a 32-byte little-endian integer modulo l (`sc_reduce32`).
Uint8List scReduce32(List<int> s) => _bigToBytes(bytesToBigLE(s) % groupOrder);

/// Reduces a 64-byte little-endian integer modulo l (`sc_reduce`).
Uint8List scReduce64(List<int> s) => _bigToBytes(bytesToBigLE(s) % groupOrder);

/// True if [s] is a canonical scalar (< l), Monero's `sc_check`.
bool scCheck(List<int> s) => bytesToBigLE(s) < groupOrder;

bool scIsZero(List<int> s) => s.every((b) => b == 0);
