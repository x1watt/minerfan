import 'dart:convert';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../util/bytes.dart';

/// Proves that whoever built a transaction vouches for [message], without
/// revealing anything: a Schnorr signature with the transaction's private
/// key r, checked against its public key R = rG (the key in tx extra that
/// every Monero transaction carries). Only the sender ever knows r.
///
/// minerfan uses it to tie a payment to a callsign: the message names the
/// callsign and the transaction, so the proof cannot be reused for anyone
/// else. Returns 64 bytes: the challenge c, then s = k - c*r.
Uint8List txKeyProof(List<int> r, List<int> message) {
  final pub = scalarMultBase(r).encode();
  final k = randomScalar();
  final c = _challenge(pub, scalarMultBase(k).encode(), message);
  return Uint8List.fromList([...c, ...scMulSub(c, r, k)]);
}

/// Whether [proof] was made with the private key of [txPub] over [message].
bool verifyTxKeyProof(List<int> txPub, List<int> message, List<int> proof) {
  if (proof.length != 64 || txPub.length != 32) return false;
  final c = proof.sublist(0, 32), s = proof.sublist(32);
  if (!scCheck(c) || !scCheck(s)) return false;
  final pub = Point.decode(txPub);
  if (pub == null) return false;
  // sG + cR = (k - cr)G + crG = kG
  final k = pointSum(scalarMultBase(s), scalarMult(c, pub)).encode();
  return bytesEqual(c, _challenge(txPub, k, message));
}

Uint8List _challenge(List<int> pub, List<int> commit, List<int> message) =>
    hashToScalarBytes([...utf8.encode('minerfan tx key proof'), ...pub, ...commit, ...Keccak.hash256(message)]);
