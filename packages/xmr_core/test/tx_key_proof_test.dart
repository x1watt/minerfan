import 'dart:convert';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ec_ops.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/xmr_core.dart';

void main() {
  test('a tx-key proof verifies against R and nothing else', () {
    final r = randomScalar();
    final pub = scalarMultBase(r).encode();
    final msg = utf8.encode('minerfan claim|MONERO|X1ABCD|txid');
    final proof = txKeyProof(r, msg);
    expect(verifyTxKeyProof(pub, msg, proof), isTrue);
    expect(verifyTxKeyProof(pub, utf8.encode('minerfan claim|MONERO|X1EVIL|txid'), proof), isFalse,
        reason: 'bound to the callsign');
    expect(verifyTxKeyProof(scalarMultBase(randomScalar()).encode(), msg, proof), isFalse,
        reason: 'another transaction\'s key');
    final bent = [...proof]..[40] ^= 1;
    expect(verifyTxKeyProof(pub, msg, bent), isFalse);
  });
}
