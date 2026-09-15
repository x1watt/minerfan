import 'dart:typed_data';

import 'mac.dart';

/// The secp256k1 curve (y^2 = x^3 + 7 over p) and ECDSA on it, as used by
/// Bitcoin-family coins. BigInt based: fine for wallet work (keys,
/// signatures), not meant for bulk verification.
abstract final class Secp256k1 {
  static final BigInt p = BigInt.parse('fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
  static final BigInt n = BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);
  static final EcPoint g = EcPoint(
    BigInt.parse('79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798', radix: 16),
    BigInt.parse('483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8', radix: 16),
  );

  static bool validPrivateKey(BigInt k) => k > BigInt.zero && k < n;

  /// Public key point of private key [k].
  static EcPoint publicKey(BigInt k) => _baseMul(k);

  /// ECDSA signature of a 32-byte [hash] with deterministic k (RFC 6979,
  /// HMAC-SHA256) and low S (BIP 62), as (r, s).
  static (BigInt, BigInt) sign(BigInt key, List<int> hash) {
    final z = _bits2int(hash);
    for (final k in _rfc6979(key, hash)) {
      final r = publicKey(k).x % n;
      if (r == BigInt.zero) continue;
      var s = (k.modInverse(n) * (z + r * key)) % n;
      if (s == BigInt.zero) continue;
      if (s > n >> 1) s = n - s;
      return (r, s);
    }
    throw StateError('unreachable');
  }

  static bool verify(EcPoint pub, List<int> hash, BigInt r, BigInt s) {
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
    final z = _bits2int(hash);
    final w = s.modInverse(n);
    final q = _add(_baseMulJ(z * w % n), _mulJ(pub, r * w % n)).toAffine();
    return q != null && q.x % n == r;
  }

  /// DER encoding of a signature (as in Bitcoin scripts, without the
  /// sighash byte).
  static Uint8List der(BigInt r, BigInt s) {
    List<int> intBytes(BigInt v) {
      var b = bigToBytes(v, 32).toList();
      while (b.length > 1 && b[0] == 0 && b[1] < 0x80) {
        b = b.sublist(1);
      }
      if (b[0] >= 0x80) b = [0, ...b];
      return [0x02, b.length, ...b];
    }

    final body = [...intBytes(r), ...intBytes(s)];
    return Uint8List.fromList([0x30, body.length, ...body]);
  }

  // ---- RFC 6979 ----

  static Iterable<BigInt> _rfc6979(BigInt key, List<int> hash) sync* {
    final x = bigToBytes(key, 32);
    final h1 = bigToBytes(_bits2int(hash) % n, 32);
    var v = Uint8List(32)..fillRange(0, 32, 1);
    var k = Uint8List(32);
    k = hmacSha256(k, [...v, 0, ...x, ...h1]);
    v = hmacSha256(k, v);
    k = hmacSha256(k, [...v, 1, ...x, ...h1]);
    v = hmacSha256(k, v);
    while (true) {
      v = hmacSha256(k, v);
      final t = bytesToBig(v);
      if (t > BigInt.zero && t < n) yield t;
      k = hmacSha256(k, [...v, 0]);
      v = hmacSha256(k, v);
    }
  }

  static BigInt _bits2int(List<int> hash) => bytesToBig(hash.length > 32 ? hash.sublist(0, 32) : hash);

  // ---- group arithmetic (Jacobian coordinates) ----

  static _Jac _double(_Jac a) {
    if (a.z == BigInt.zero || a.y == BigInt.zero) return _Jac.infinity;
    final y2 = a.y * a.y % p;
    final s = BigInt.from(4) * a.x * y2 % p;
    final m = BigInt.from(3) * a.x * a.x % p;
    final x3 = (m * m - BigInt.two * s) % p;
    final y3 = (m * (s - x3) - BigInt.from(8) * y2 * y2) % p;
    final z3 = BigInt.two * a.y * a.z % p;
    return _Jac(x3, y3, z3);
  }

  static _Jac _add(_Jac a, _Jac b) {
    if (a.z == BigInt.zero) return b;
    if (b.z == BigInt.zero) return a;
    final z1z1 = a.z * a.z % p, z2z2 = b.z * b.z % p;
    final u1 = a.x * z2z2 % p, u2 = b.x * z1z1 % p;
    final s1 = a.y * b.z * z2z2 % p, s2 = b.y * a.z * z1z1 % p;
    if (u1 == u2) return s1 == s2 ? _double(a) : _Jac.infinity;
    final h = (u2 - u1) % p, r = (s2 - s1) % p;
    final h2 = h * h % p, h3 = h * h2 % p;
    final x3 = (r * r - h3 - BigInt.two * u1 * h2) % p;
    final y3 = (r * (u1 * h2 - x3) - s1 * h3) % p;
    final z3 = h * a.z * b.z % p;
    return _Jac(x3, y3, z3);
  }

  static _Jac _mulJ(EcPoint pt, BigInt k) {
    var r = _Jac.infinity;
    final q = _Jac(pt.x, pt.y, BigInt.one);
    for (var i = k.bitLength - 1; i >= 0; i--) {
      r = _double(r);
      if ((k >> i) & BigInt.one == BigInt.one) r = _add(r, q);
    }
    return r;
  }

  // Fixed base: 64 windows of 4 bits, table[w][d] = d * 16^w * G.
  static List<List<_Jac>>? _table;

  static _Jac _baseMulJ(BigInt k) {
    final t = _table ??= _buildTable();
    var r = _Jac.infinity;
    for (var w = 0; w < 64; w++) {
      final d = ((k >> (4 * w)) & BigInt.from(15)).toInt();
      if (d != 0) r = _add(r, t[w][d]);
    }
    return r;
  }

  static EcPoint _baseMul(BigInt k) => _baseMulJ(k % n).toAffine()!;

  static List<List<_Jac>> _buildTable() {
    final table = <List<_Jac>>[];
    var base = _Jac(g.x, g.y, BigInt.one);
    for (var w = 0; w < 64; w++) {
      final row = <_Jac>[_Jac.infinity, base];
      for (var d = 2; d < 16; d++) {
        row.add(_add(row[d - 1], base));
      }
      // Normalized once so later additions stay cheap.
      table.add([for (final j in row) j.z == BigInt.zero ? j : _Jac.fromAffine(j.toAffine()!)]);
      base = _double(_double(_double(_double(base))));
    }
    return table;
  }

  static EcPoint add(EcPoint a, EcPoint b) =>
      _add(_Jac(a.x, a.y, BigInt.one), _Jac(b.x, b.y, BigInt.one)).toAffine()!;
}

/// An affine point on secp256k1.
class EcPoint {
  final BigInt x, y;
  const EcPoint(this.x, this.y);

  /// 33-byte compressed or 65-byte uncompressed SEC encoding.
  Uint8List encode({bool compressed = true}) => compressed
      ? Uint8List.fromList([y.isEven ? 2 : 3, ...bigToBytes(x, 32)])
      : Uint8List.fromList([4, ...bigToBytes(x, 32), ...bigToBytes(y, 32)]);

  static EcPoint? decode(List<int> b) {
    final p = Secp256k1.p;
    if (b.length == 65 && b[0] == 4) {
      final pt = EcPoint(bytesToBig(b.sublist(1, 33)), bytesToBig(b.sublist(33)));
      return (pt.y * pt.y - pt.x * pt.x * pt.x - BigInt.from(7)) % p == BigInt.zero ? pt : null;
    }
    if (b.length != 33 || (b[0] != 2 && b[0] != 3)) return null;
    final x = bytesToBig(b.sublist(1));
    final y2 = (x * x * x + BigInt.from(7)) % p;
    var y = y2.modPow((p + BigInt.one) >> 2, p);
    if (y * y % p != y2) return null;
    if (y.isEven != (b[0] == 2)) y = p - y;
    return EcPoint(x, y);
  }

  @override
  bool operator ==(Object other) => other is EcPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
}

class _Jac {
  final BigInt x, y, z;
  const _Jac(this.x, this.y, this.z);
  static final _Jac infinity = _Jac(BigInt.one, BigInt.one, BigInt.zero);
  factory _Jac.fromAffine(EcPoint p) => _Jac(p.x, p.y, BigInt.one);

  EcPoint? toAffine() {
    if (z == BigInt.zero) return null;
    final p = Secp256k1.p;
    final zi = z.modInverse(p);
    final zi2 = zi * zi % p;
    return EcPoint(x * zi2 % p, y * zi2 % p * zi % p);
  }
}

BigInt bytesToBig(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List bigToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var t = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (t & BigInt.from(0xff)).toInt();
    t >>= 8;
  }
  return out;
}
