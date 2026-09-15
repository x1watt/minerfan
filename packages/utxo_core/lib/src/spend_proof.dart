import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

/// Proves that whoever spent a transaction's input vouches for [message]:
/// an ECDSA signature (RFC 6979, low S) over sha256([message]) by the key
/// of that input, whose public key is in the input's scriptSig for anyone
/// to check. minerfan uses it to tie a payment to a callsign: the message
/// names the callsign and the transaction, so it proves nothing for anyone
/// else. Returns 64 bytes, r then s.
Uint8List inputKeyProof(BigInt key, List<int> message) {
  final (r, s) = Secp256k1.sign(key, Sha256.hash(message));
  return Uint8List.fromList([...bigToBytes(r, 32), ...bigToBytes(s, 32)]);
}

/// Whether [proof] was made by the key of [publicKey] (SEC encoded) over
/// [message].
bool verifyInputKeyProof(List<int> publicKey, List<int> message, List<int> proof) {
  if (proof.length != 64) return false;
  final pub = EcPoint.decode(publicKey);
  if (pub == null) return false;
  BigInt big(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
  return Secp256k1.verify(pub, Sha256.hash(message), big(proof.sublist(0, 32)), big(proof.sublist(32)));
}

/// The public key a P2PKH scriptSig reveals (its last push, 33 or 65
/// bytes), or null.
Uint8List? scriptSigPublicKey(List<int> script) {
  Uint8List? last;
  var i = 0;
  while (i < script.length) {
    final op = script[i++];
    int len;
    if (op >= 1 && op <= 75) {
      len = op;
    } else if (op == 0x4c && i < script.length) {
      len = script[i++];
    } else if (op == 0x4d && i + 1 < script.length) {
      len = script[i] | (script[i + 1] << 8);
      i += 2;
    } else {
      continue;
    }
    if (i + len > script.length) return null;
    last = Uint8List.fromList(script.sublist(i, i + len));
    i += len;
  }
  return last != null && (last.length == 33 || last.length == 65) ? last : null;
}
