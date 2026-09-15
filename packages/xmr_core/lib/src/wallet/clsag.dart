import 'dart:convert';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../util/bytes.dart';
import 'transaction.dart';

/// CLSAG ring signatures (src/ringct/rctSigs.cpp CLSAG_Gen and
/// verRctCLSAGSimple, BSD-3): one per input, proving knowledge of one ring
/// member's key and that its amount commitment minus the pseudo output
/// commits to zero, with key image I = p * Hp(P).

Uint8List _domain(String s) => Uint8List(32)..setRange(0, s.length, utf8.encode(s));
final Uint8List _agg0 = _domain('CLSAG_agg_0');
final Uint8List _agg1 = _domain('CLSAG_agg_1');
final Uint8List _round = _domain('CLSAG_round');
final Uint8List _invEight = scInvert(scFromInt(8));

Uint8List _hash(List<List<int>> keys) => hashToScalarBytes([for (final k in keys) ...k]);

/// A ring member: output key and amount commitment.
typedef RingMember = ({Uint8List key, Uint8List commitment});

/// Signs [message] for the ring [ring] whose member [index] has secret key
/// [p] and commitment mask [mask]; [pseudoOut] with mask [pseudoMask] is
/// the input's pseudo output commitment.
(Clsag, Uint8List) clsagSign(
  Uint8List message,
  List<RingMember> ring,
  int index,
  Uint8List p,
  Uint8List mask,
  Uint8List pseudoOut,
  Uint8List pseudoMask,
) {
  final n = ring.length;
  final pOff = decodePoint(pseudoOut);
  final cDiff = [for (final m in ring) pointDiff(decodePoint(m.commitment), pOff)];
  final z = scSub(mask, pseudoMask); // C[index] - pseudoOut = z * G
  final h = hashToEc(ring[index].key);
  final a = randomScalar();
  final aG = scalarMultBase(a).encode();
  final aH = scalarMult(a, h).encode();
  final keyImage = scalarMult(p, h).encode();
  final dFull = scalarMult(z, h);
  final d = scalarMult(_invEight, dFull).encode();

  final ps = [for (final m in ring) m.key];
  final cs = [for (final m in ring) m.commitment];
  final muP = _hash([_agg0, ...ps, ...cs, keyImage, d, pseudoOut]);
  final muC = _hash([_agg1, ...ps, ...cs, keyImage, d, pseudoOut]);
  final prefix = [_round, ...ps, ...cs, pseudoOut, message];

  final s = List<Uint8List>.filled(n, Uint8List(32));
  var c = _hash([...prefix, aG, aH]);
  var i = (index + 1) % n;
  Uint8List c1 = c;
  final iPt = decodePoint(keyImage);
  while (i != index) {
    if (i == 0) c1 = c;
    s[i] = randomScalar();
    final cp = scMul(muP, c), cc = scMul(muC, c);
    final l = multiScalarMult([s[i], cp, cc], [basePoint, decodePoint(ps[i]), cDiff[i]]).encode();
    final r = multiScalarMult([s[i], cp, cc], [hashToEc(ps[i]), iPt, dFull]).encode();
    c = _hash([...prefix, l, r]);
    i = (i + 1) % n;
  }
  if (index == 0) c1 = c;
  // s = a - c * (muP * p + muC * z)
  s[index] = scMulSub(c, scMulAdd(muC, z, scMul(muP, p)), a);
  return (Clsag(s, c1, d), keyImage);
}

/// Checks a CLSAG over [ring] with key image [keyImage] and pseudo output
/// [pseudoOut].
bool clsagVerify(Uint8List message, Clsag sig, List<RingMember> ring, Uint8List keyImage, Uint8List pseudoOut) {
  final n = ring.length;
  if (sig.s.length != n || n == 0) return false;
  if (!sig.s.every(scCheck) || !scCheck(sig.c1)) return false;
  final iPt = Point.decode(keyImage);
  final dPt = Point.decode(sig.d);
  final pOff = Point.decode(pseudoOut);
  if (iPt == null || dPt == null || pOff == null || pointIsIdentity(iPt)) return false;
  final d8 = pointMul8(dPt);
  if (pointIsIdentity(d8)) return false;
  final ps = [for (final m in ring) m.key];
  final cs = [for (final m in ring) m.commitment];
  final muP = _hash([_agg0, ...ps, ...cs, keyImage, sig.d, pseudoOut]);
  final muC = _hash([_agg1, ...ps, ...cs, keyImage, sig.d, pseudoOut]);
  final prefix = [_round, ...ps, ...cs, pseudoOut, message];
  var c = sig.c1;
  for (var i = 0; i < n; i++) {
    final pk = Point.decode(ps[i]), ck = Point.decode(cs[i]);
    if (pk == null || ck == null) return false;
    final cp = scMul(muP, c), cc = scMul(muC, c);
    final l = multiScalarMult([sig.s[i], cp, cc], [basePoint, pk, pointDiff(ck, pOff)]).encode();
    final r = multiScalarMult([sig.s[i], cp, cc], [hashToEc(ps[i]), iPt, d8]).encode();
    c = _hash([...prefix, l, r]);
  }
  return bytesEqual(c, sig.c1);
}
