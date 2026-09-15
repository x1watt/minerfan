import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../util/varint.dart';
import 'scanner.dart' show pointH;
import 'transaction.dart';

/// Bulletproofs+ aggregated range proofs (src/ringct/bulletproofs_plus.cc,
/// BSD-3): each output amount is in [0, 2^64). Commitments enter the proof
/// as V = C / 8.

final BigInt _l = groupOrder;
BigInt _m(BigInt x) => x % _l;
Uint8List _b(BigInt x) => scFromBig(x);
BigInt _s(List<int> b) => scToBig(b);

final BigInt _inv8 = BigInt.from(8).modInverse(_l);
final Random _rng = Random.secure();

BigInt _random() => _s(randomScalar());

const _logN = 6, _n = 64, _maxM = 16;

final Uint8List _hBytes = pointH.encode();
final List<Point> _gi = [], _hi = [];

void _generators(int count) {
  final salt = utf8.encode('bulletproof_plus');
  while (_hi.length < count) {
    final i = _hi.length;
    _hi.add(hashToEc(Keccak.hash256([..._hBytes, ...salt, ...encodeVarint(i * 2)])));
    _gi.add(hashToEc(Keccak.hash256([..._hBytes, ...salt, ...encodeVarint(i * 2 + 1)])));
  }
}

final Uint8List _initialTranscript = hashToEc(Keccak.hash256(utf8.encode('bulletproof_plus_transcript'))).encode();

BigInt _hs(List<List<int>> parts) => _s(hashToScalarBytes([for (final p in parts) ...p]));

BigInt _update(List<Uint8List> t, List<Uint8List> items) {
  final v = _hs([t[0], ...items]);
  t[0] = _b(v);
  return v;
}

BigInt _pow(BigInt x, int e) => x.modPow(BigInt.from(e), _l);

int _logMFor(int outputs) {
  var logM = 0;
  while ((1 << logM) <= _maxM && (1 << logM) < outputs) {
    logM++;
  }
  return logM;
}

Point _msm(List<BigInt> scalars, List<Point> points) => multiScalarMult([for (final s in scalars) _b(s)], points);

BigInt _wip(List<BigInt> a, List<BigInt> b, BigInt y) {
  var res = BigInt.zero, yp = BigInt.one;
  for (var i = 0; i < a.length; i++) {
    yp = _m(yp * y);
    res = _m(res + a[i] * b[i] % _l * yp);
  }
  return res;
}

List<Point> _fold(List<Point> v, BigInt a, BigInt b) {
  final sz = v.length ~/ 2;
  return [for (var i = 0; i < sz; i++) _msm([a, b], [v[i], v[sz + i]])];
}

/// Proves that [amounts] (with commitment masks [masks]) are 64-bit.
BulletproofPlus bulletproofPlusProve(List<int> amounts, List<Uint8List> masks) {
  if (amounts.isEmpty || amounts.length != masks.length || amounts.length > _maxM) {
    throw ArgumentError('1 to $_maxM amounts with one mask each');
  }
  final logM = _logMFor(amounts.length);
  final m = 1 << logM, mn = m * _n;
  _generators(mn);
  final gamma = [for (final k in masks) _s(k)];
  final v = [
    for (var j = 0; j < amounts.length; j++)
      _msm([_m(gamma[j] * _inv8), _m(BigInt.from(amounts[j]) * _inv8)], [basePoint, pointH]).encode()
  ];
  final aL = List<BigInt>.filled(mn, BigInt.zero), aR = List<BigInt>.filled(mn, BigInt.zero);
  for (var j = 0; j < m; j++) {
    for (var i = 0; i < _n; i++) {
      final bit = j < amounts.length && ((BigInt.from(amounts[j]) >> i) & BigInt.one) == BigInt.one;
      aL[j * _n + i] = bit ? BigInt.one : BigInt.zero;
      aR[j * _n + i] = bit ? BigInt.zero : _l - BigInt.one;
    }
  }
  while (true) {
    final t = [Uint8List.fromList(_initialTranscript)];
    _update(t, [_b(_hs(v))]);
    final alpha = _random();
    final a = pointSum(
      _msm([for (var i = 0; i < mn; i++) ...[_m(aL[i] * _inv8), _m(aR[i] * _inv8)]],
          [for (var i = 0; i < mn; i++) ...[_gi[i], _hi[i]]]),
      scalarMultBase(_b(_m(alpha * _inv8))),
    ).encode();
    final y = _update(t, [a]);
    if (y == BigInt.zero) continue;
    final z = _hs([_b(y)]);
    t[0] = _b(z);
    if (z == BigInt.zero) continue;
    final z2 = _m(z * z);
    final d = List<BigInt>.filled(mn, BigInt.zero);
    d[0] = z2;
    for (var i = 1; i < _n; i++) {
      d[i] = _m(d[i - 1] * BigInt.two);
    }
    for (var j = 1; j < m; j++) {
      for (var i = 0; i < _n; i++) {
        d[j * _n + i] = _m(d[(j - 1) * _n + i] * z2);
      }
    }
    final yPow = <BigInt>[BigInt.one];
    for (var i = 1; i < mn + 2; i++) {
      yPow.add(_m(yPow[i - 1] * y));
    }
    var ap = [for (var i = 0; i < mn; i++) _m(aL[i] - z)];
    var bp = [for (var i = 0; i < mn; i++) _m(aR[i] + z + d[i] * yPow[mn - i])];
    var alpha1 = alpha;
    var zp = BigInt.one;
    for (var j = 0; j < amounts.length; j++) {
      zp = _m(zp * z2);
      alpha1 = _m(alpha1 + yPow[mn + 1] * zp % _l * gamma[j]);
    }
    final yInv = y.modInverse(_l);
    final yInvPow = <BigInt>[BigInt.one];
    for (var i = 1; i < mn; i++) {
      yInvPow.add(_m(yInvPow[i - 1] * yInv));
    }
    var gp = List<Point>.of(_gi.take(mn)), hp = List<Point>.of(_hi.take(mn));
    final ls = <Uint8List>[], rs = <Uint8List>[];
    var np = mn;
    var retry = false;
    while (np > 1) {
      np ~/= 2;
      final cL = _wip(ap.sublist(0, np), bp.sublist(np), y);
      final cR = _wip([for (final x in ap.sublist(np)) _m(x * yPow[np])], bp.sublist(0, np), y);
      final dL = _random(), dR = _random();
      Point lr(BigInt yy, List<Point> g, int g0, List<Point> h, int h0, List<BigInt> av, int a0, List<BigInt> bv, int b0,
          BigInt c, BigInt dd) {
        final sc = <BigInt>[], pts = <Point>[];
        for (var i = 0; i < np; i++) {
          sc.add(_m(av[a0 + i] * yy % _l * _inv8));
          pts.add(g[g0 + i]);
          sc.add(_m(bv[b0 + i] * _inv8));
          pts.add(h[h0 + i]);
        }
        sc
          ..add(_m(c * _inv8))
          ..add(_m(dd * _inv8));
        pts
          ..add(pointH)
          ..add(basePoint);
        return _msm(sc, pts);
      }

      final l = lr(yInvPow[np], gp, np, hp, 0, ap, 0, bp, np, cL, dL).encode();
      final r = lr(yPow[np], gp, 0, hp, np, ap, np, bp, 0, cR, dR).encode();
      ls.add(l);
      rs.add(r);
      final x = _update(t, [l, r]);
      if (x == BigInt.zero) {
        retry = true;
        break;
      }
      final xInv = x.modInverse(_l);
      gp = _fold(gp, xInv, _m(yInvPow[np] * x));
      hp = _fold(hp, x, xInv);
      final k = _m(xInv * yPow[np]);
      ap = [for (var i = 0; i < np; i++) _m(ap[i] * x + ap[np + i] * k)];
      bp = [for (var i = 0; i < np; i++) _m(bp[i] * xInv + bp[np + i] * x)];
      alpha1 = _m(alpha1 + dL * x % _l * x + dR * xInv % _l * xInv);
    }
    if (retry) continue;
    final r = _random(), s = _random(), dd = _random(), eta = _random();
    final a1 = _msm([
      _m(r * _inv8),
      _m(s * _inv8),
      _m(dd * _inv8),
      _m((r * y % _l * bp[0] + s * y % _l * ap[0]) * _inv8),
    ], [gp[0], hp[0], basePoint, pointH]).encode();
    final b = _msm([_m(eta * _inv8), _m(r * y % _l * s % _l * _inv8)], [basePoint, pointH]).encode();
    final e = _update(t, [a1, b]);
    if (e == BigInt.zero) continue;
    final r1 = _m(r + ap[0] * e), s1 = _m(s + bp[0] * e);
    final d1 = _m(eta + dd * e + alpha1 * e % _l * e);
    return BulletproofPlus(a, a1, b, _b(r1), _b(s1), _b(d1), ls, rs);
  }
}

/// Checks [proof] for the output [commitments] (as in the transaction).
bool bulletproofPlusVerify(BulletproofPlus proof, List<Uint8List> commitments) {
  try {
    for (final x in [proof.r1, proof.s1, proof.d1]) {
      if (!scCheck(x)) return false;
    }
    if (commitments.isEmpty || commitments.length > _maxM || proof.l.length != proof.r.length) return false;
    final logM = _logMFor(commitments.length);
    if (proof.l.length != _logN + logM) return false;
    final m = 1 << logM, mn = m * _n;
    _generators(mn);
    final v = [for (final c in commitments) scalarMult(_b(_inv8), decodePoint(c)).encode()];
    final t = [Uint8List.fromList(_initialTranscript)];
    _update(t, [_b(_hs(v))]);
    final y = _update(t, [proof.a]);
    final z = _hs([_b(y)]);
    t[0] = _b(z);
    if (y == BigInt.zero || z == BigInt.zero) return false;
    final rounds = logM + _logN;
    final ch = [for (var j = 0; j < rounds; j++) _update(t, [proof.l[j], proof.r[j]])];
    final e = _update(t, [proof.a1, proof.b]);
    if (e == BigInt.zero || ch.contains(BigInt.zero)) return false;
    final chInv = [for (final c in ch) c.modInverse(_l)];
    final yInv = y.modInverse(_l);
    final r1 = _s(proof.r1), s1 = _s(proof.s1), d1 = _s(proof.d1);
    final weight = BigInt.one + BigInt.from(_rng.nextInt(1 << 30));

    final yMN = _pow(y, mn), yMN1 = _m(yMN * y);
    final e2 = _m(e * e), z2 = _m(z * z);
    final scalars = <BigInt>[], points = <Point>[];
    var tmp = _m(-e2 * yMN1 % _l * weight);
    for (final c in v) {
      tmp = _m(tmp * z2);
      scalars.add(tmp);
      points.add(pointMul8(decodePoint(c)));
    }
    final minusW = _m(-weight);
    scalars.add(minusW);
    points.add(pointMul8(decodePoint(proof.b)));
    final minusWE = _m(minusW * e);
    scalars.add(minusWE);
    points.add(pointMul8(decodePoint(proof.a1)));
    final minusWE2 = _m(minusWE * e);
    scalars.add(minusWE2);
    points.add(pointMul8(decodePoint(proof.a)));
    final gScalar = _m(weight * d1);

    final d = List<BigInt>.filled(mn, BigInt.zero);
    d[0] = z2;
    for (var i = 1; i < _n; i++) {
      d[i] = _m(d[i - 1] * BigInt.two);
    }
    for (var j = 1; j < m; j++) {
      for (var i = 0; i < _n; i++) {
        d[j * _n + i] = _m(d[(j - 1) * _n + i] * z2);
      }
    }
    var sumEven = BigInt.zero;
    for (var k = 1; k <= m; k++) {
      sumEven = _m(sumEven + _pow(z, 2 * k));
    }
    final sumD = _m(((BigInt.one << 64) - BigInt.one) * sumEven);
    var sumY = BigInt.zero, yp = BigInt.one;
    for (var i = 0; i < mn; i++) {
      yp = _m(yp * y);
      sumY = _m(sumY + yp);
    }
    final hScalar = _m(weight * (r1 * y % _l * s1 + e2 * (yMN1 * z % _l * sumD + (z2 - z) * sumY)));

    final cache = List<BigInt>.filled(1 << rounds, BigInt.zero);
    cache[0] = chInv[0];
    cache[1] = ch[0];
    for (var j = 1; j < rounds; j++) {
      final slots = 1 << (j + 1);
      for (var s = slots - 1; s > 0; s -= 2) {
        cache[s] = _m(cache[s ~/ 2] * ch[j]);
        cache[s - 1] = _m(cache[s ~/ 2] * chInv[j]);
      }
    }
    var eR1WY = _m(e * r1 % _l * weight);
    final eS1W = _m(e * s1 % _l * weight);
    final e2ZW = _m(e2 * z % _l * weight);
    var minusE2WY = _m(-e2 * weight % _l * yMN);
    for (var i = 0; i < mn; i++) {
      final g = _m(eR1WY * cache[i] + e2ZW);
      final h = _m(eS1W * cache[(~i) & (mn - 1)] - e2ZW + minusE2WY * d[i]);
      scalars
        ..add(g)
        ..add(h);
      points
        ..add(_gi[i])
        ..add(_hi[i]);
      eR1WY = _m(eR1WY * yInv);
      minusE2WY = _m(minusE2WY * yInv);
    }
    for (var j = 0; j < rounds; j++) {
      scalars.add(_m(ch[j] * ch[j] % _l * minusWE2));
      points.add(pointMul8(decodePoint(proof.l[j])));
      scalars.add(_m(chInv[j] * chInv[j] % _l * minusWE2));
      points.add(pointMul8(decodePoint(proof.r[j])));
    }
    scalars
      ..add(gScalar)
      ..add(hScalar);
    points
      ..add(basePoint)
      ..add(pointH);
    return pointIsIdentity(_msm(scalars, points));
  } on FormatException {
    return false;
  }
}
