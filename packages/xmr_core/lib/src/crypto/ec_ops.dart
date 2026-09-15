import 'dart:math';
import 'dart:typed_data';

import 'ed25519.dart';
import 'keccak.dart';

/// Curve and scalar operations the wallet needs beyond one-time keys: hash
/// to point (key images), scalar arithmetic modulo l and point helpers.
/// Ported from Monero's src/crypto/crypto-ops.c and crypto.cpp (BSD-3).

// ---- scalars modulo l (32-byte little endian) --------------------------------

final BigInt _l = groupOrder;

Uint8List scFromBig(BigInt x) {
  var t = x % _l;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (t & BigInt.from(0xff)).toInt();
    t >>= 8;
  }
  return out;
}

BigInt scToBig(List<int> s) => bytesToBigLE(s);

Uint8List scAdd(List<int> a, List<int> b) => scFromBig(scToBig(a) + scToBig(b));
Uint8List scSub(List<int> a, List<int> b) => scFromBig(scToBig(a) - scToBig(b));
Uint8List scMul(List<int> a, List<int> b) => scFromBig(scToBig(a) * scToBig(b));

/// a * b + c
Uint8List scMulAdd(List<int> a, List<int> b, List<int> c) => scFromBig(scToBig(a) * scToBig(b) + scToBig(c));

/// c - a * b
Uint8List scMulSub(List<int> a, List<int> b, List<int> c) => scFromBig(scToBig(c) - scToBig(a) * scToBig(b));

Uint8List scNeg(List<int> a) => scFromBig(-scToBig(a));
Uint8List scInvert(List<int> a) => scFromBig(scToBig(a).modInverse(_l));
Uint8List scFromInt(int v) => scFromBig(BigInt.from(v));

final Random _rng = Random.secure();

/// A uniformly random nonzero scalar (64 random bytes reduced, as Monero's
/// `random_scalar`).
Uint8List randomScalar() {
  while (true) {
    final b = Uint8List.fromList(List.generate(64, (_) => _rng.nextInt(256)));
    final s = scReduce64(b);
    if (!scIsZero(s)) return s;
  }
}

/// Keccak-256 of [data] reduced modulo l (`hash_to_scalar`).
Uint8List hashToScalarBytes(List<int> data) => scReduce32(Keccak.hash256(data));

// ---- points -----------------------------------------------------------------

Point pointNeg(Point p) {
  final r = p.copy();
  feNeg(r.x, r.x);
  feNeg(r.t, r.t);
  return r;
}

Point pointSum(Point a, Point b) {
  final r = Point.identity();
  pointAdd(r, a, b);
  return r;
}

Point pointDiff(Point a, Point b) => pointSum(a, pointNeg(b));

bool pointIsIdentity(Point p) {
  final e = p.encode();
  if (e[0] != 1) return false;
  for (var i = 1; i < 32; i++) {
    if (e[i] != 0) return false;
  }
  return true;
}

/// Decodes a point or throws (for data that must be valid).
Point decodePoint(List<int> b) => Point.decode(b) ?? (throw FormatException('not a curve point'));

/// sum of scalars[i] * points[i] (Straus, 4-bit windows): much faster than
/// separate multiplications for the proofs' long sums.
Point multiScalarMult(List<List<int>> scalars, List<Point> points) {
  final n = points.length;
  final tables = List<List<Point>>.generate(n, (k) {
    final t = List<Point>.filled(16, Point.identity());
    t[1] = points[k].copy();
    for (var i = 2; i < 16; i++) {
      t[i] = pointSum(t[i - 1], points[k]);
    }
    return t;
  });
  final r = Point.identity();
  for (var i = 63; i >= 0; i--) {
    pointDouble(r, r);
    pointDouble(r, r);
    pointDouble(r, r);
    pointDouble(r, r);
    for (var k = 0; k < n; k++) {
      final nib = (scalars[k][i >> 1] >> ((i & 1) * 4)) & 0xf;
      if (nib != 0) pointAdd(r, r, tables[k][nib]);
    }
  }
  return r;
}

// ---- hash to point (ge_fromfe_frombytes_vartime) -----------------------------

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a = BigInt.from(486662);
final Fe _feMa2 = Fe.fromBigInt(-_a * _a);
final Fe _feMa = Fe.fromBigInt(-_a);
final Fe _fffb1 = _sqrtOf(-BigInt.two * _a * (_a + BigInt.two), _limbs([-31702527, -2466483, -26106795, -12203692, -12169197, -321052, 14850977, -10296299, -16929438, -407568]));
final Fe _fffb2 = _sqrtOf(BigInt.two * _a * (_a + BigInt.two), _limbs([8166131, -6741800, -17040804, 3154616, 21461005, 1466302, -30876704, -6368709, 10503587, -13363080]));
final Fe _fffb3 = _limbs([-13620103, 14639558, 4532995, 7679154, 16815101, -15883539, -22863840, -14813421, 13716513, -6477756]);
final Fe _fffb4 = _limbs([-21786234, -12173074, 21573800, 4524538, -4645904, 16204591, 8012863, -8444712, 3212926, 6885324]);

/// The constants as Monero writes them (limbs), checked against their
/// definition where it is a plain square root.
Fe _sqrtOf(BigInt square, Fe given) {
  final g = _toBig(given);
  if ((g * g - square) % _p != BigInt.zero) throw StateError('bad curve constant');
  return given;
}

Fe _limbs(List<int> v) {
  final f = Fe();
  for (var i = 0; i < 10; i++) {
    f.v[i] = v[i];
  }
  return f;
}

BigInt _toBig(Fe f) => bytesToBigLE(f.toBytes());

/// (u / v)^((p + 3) / 8), as Monero's `fe_divpowm1`.
void _divPowM1(Fe r, Fe u, Fe v) {
  final v3 = Fe(), uv7 = Fe();
  feSq(v3, v);
  feMul(v3, v3, v);
  feSq(uv7, v3);
  feMul(uv7, uv7, v);
  feMul(uv7, uv7, u);
  fePow22523(uv7, uv7);
  feMul(r, uv7, v3);
  feMul(r, r, u);
}

/// Monero's map from 32 bytes to a curve point (Elligator-style, not
/// multiplied by 8). All 256 bits are read, the top one included.
Point geFromFeFromBytes(List<int> s) {
  final u = Fe.fromBigInt(bytesToBigLE(s) % _p);
  final v = Fe(), w = Fe(), x = Fe(), y = Fe(), z = Fe(), rx = Fe();
  feSq(v, u);
  feAdd(v, v, v); // 2u^2
  feAdd(w, v, Fe.one); // w = 2u^2 + 1
  feSq(x, w);
  feMul(y, _feMa2, v);
  feAdd(x, x, y); // x = w^2 - 2A^2u^2
  _divPowM1(rx, w, x);
  feSq(y, rx);
  feMul(x, y, x);
  feSub(y, w, x);
  feCopy(z, _feMa);
  int sign;
  var negative = false;
  if (!y.isZero) {
    feAdd(y, w, x);
    if (!y.isZero) {
      negative = true;
    } else {
      feMul(rx, rx, _fffb1);
    }
  } else {
    feMul(rx, rx, _fffb2);
  }
  if (!negative) {
    feMul(rx, rx, u);
    feMul(z, z, v);
    sign = 0;
  } else {
    feMul(x, x, sqrtM1);
    feSub(y, w, x);
    if (!y.isZero) {
      feMul(rx, rx, _fffb3);
    } else {
      feMul(rx, rx, _fffb4);
    }
    sign = 1;
  }
  if ((rx.isNegative ? 1 : 0) != sign) feNeg(rx, rx);
  final rz = Fe(), ry = Fe();
  feAdd(rz, z, w);
  feSub(ry, z, w);
  feMul(rx, rx, rz);
  // Projective (X:Y:Z) to extended: (XZ : YZ : Z^2 : XY).
  final ex = Fe(), ey = Fe(), ez = Fe(), et = Fe();
  feMul(ex, rx, rz);
  feMul(ey, ry, rz);
  feSq(ez, rz);
  feMul(et, rx, ry);
  return Point(ex, ey, ez, et);
}

/// Hp(P) = 8 * map(Keccak(P)): the key image base of an output key.
Point hashToEc(List<int> publicKey) => pointMul8(geFromFeFromBytes(Keccak.hash256(publicKey)));

/// Key image x * Hp(P) of an output with one-time secret [secret].
Uint8List generateKeyImage(List<int> publicKey, List<int> secret) => scalarMult(secret, hashToEc(publicKey)).encode();
