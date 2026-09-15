import 'dart:convert';
import 'dart:typed_data';

import '../util/bytes.dart';
import '../util/varint.dart';
import 'ed25519.dart';
import 'keccak.dart';

/// Monero one-time key primitives (src/crypto/crypto.cpp, BSD-3-Clause).

/// Keccak-256 reduced modulo l.
Uint8List hashToScalar(List<int> data) => scReduce32(Keccak.hash256(data));

/// Public key of a canonical secret scalar, or null when not canonical.
Uint8List? secretKeyToPublicKey(List<int> secret) {
  if (!scCheck(secret)) return null;
  return scalarMultBase(secret).encode();
}

/// True if [key] decodes to a curve point.
bool checkKey(List<int> key) => Point.decode(key) != null;

/// D = 8 * (secret * public), or null if [public] is not a valid point.
Uint8List? generateKeyDerivation(List<int> public, List<int> secret) {
  final p = Point.decode(public);
  if (p == null) return null;
  return pointMul8(scalarMult(secret, p)).encode();
}

/// Hs(D || varint(outputIndex)).
Uint8List derivationToScalar(List<int> derivation, int outputIndex) =>
    hashToScalar(concatBytes([derivation, encodeVarint(outputIndex)]));

/// P = Hs(D || i) * G + base, or null if [base] is not a valid point.
Uint8List? derivePublicKey(List<int> derivation, int outputIndex, List<int> base) {
  final b = Point.decode(base);
  if (b == null) return null;
  final s = derivationToScalar(derivation, outputIndex);
  final r = scalarMultBase(s);
  pointAdd(r, r, b);
  return r.encode();
}

final List<int> _viewTagSalt = utf8.encode('view_tag');

/// First byte of Keccak("view_tag" || D || varint(i)).
int deriveViewTag(List<int> derivation, int outputIndex) =>
    Keccak.hash256(concatBytes([_viewTagSalt, derivation, encodeVarint(outputIndex)]))[0];
