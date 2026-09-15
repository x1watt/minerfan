import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ec_ops.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/bulletproofs_plus.dart';
import 'package:xmr_core/src/wallet/clsag.dart';
import 'package:xmr_core/src/wallet/scanner.dart';

import 'package:xmr_core/src/wallet/transaction.dart';

void main() {
  final blocks = (jsonDecode(File('test/fixtures/monero_blocks.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('Bulletproofs+ of real mainnet transactions verify; a changed commitment does not', () {
    final txs = [for (final t in (blocks.first['txs'] as List).take(6)) MoneroTx.parse(fromHex(t as String))];
    final sw = Stopwatch()..start();
    for (final tx in txs) {
      expect(bulletproofPlusVerify(tx.bulletproofsPlus!.single, tx.outPk), isTrue);
    }
    print('verified ${txs.length} real proofs in ${sw.elapsedMilliseconds} ms');
    final tx = txs.first;
    final wrong = [...tx.outPk]..[0] = scalarMultBase(randomScalar()).encode();
    expect(bulletproofPlusVerify(tx.bulletproofsPlus!.single, wrong), isFalse);
  });

  test('our Bulletproofs+ proofs verify (1, 2 and 3 outputs)', () {
    for (final amounts in [
      [12345],
      [1, 0x7fffffffffffffff],
      [5, 6, 7],
    ]) {
      final masks = [for (final _ in amounts) randomScalar()];
      final sw = Stopwatch()..start();
      final proof = bulletproofPlusProve(amounts, masks);
      final ms = sw.elapsedMilliseconds;
      final commitments = [for (var i = 0; i < amounts.length; i++) commit(masks[i], amounts[i]).encode()];
      expect(bulletproofPlusVerify(proof, commitments), isTrue);
      expect(bulletproofPlusVerify(proof, [...commitments]..[0] = commit(masks[0], amounts[0] + 1).encode()), isFalse);
      print('${amounts.length} outputs: proved in $ms ms');
    }
  });

  test('CLSAG signs and verifies; the key image is p * Hp(P)', () {
    final message = Uint8List.fromList(List.generate(32, (i) => i));
    final ring = <RingMember>[];
    const real = 5;
    final p = randomScalar(), mask = randomScalar();
    const amount = 1000;
    for (var i = 0; i < 16; i++) {
      ring.add(i == real
          ? (key: scalarMultBase(p).encode(), commitment: commit(mask, amount).encode())
          : (key: scalarMultBase(randomScalar()).encode(), commitment: scalarMultBase(randomScalar()).encode()));
    }
    final pseudoMask = randomScalar();
    final pseudo = commit(pseudoMask, amount).encode();
    final sw = Stopwatch()..start();
    final (sig, ki) = clsagSign(message, ring, real, p, mask, pseudo, pseudoMask);
    print('CLSAG ring 16 signed in ${sw.elapsedMilliseconds} ms');
    expect(bytesEqual(ki, generateKeyImage(ring[real].key, p)), isTrue);
    expect(clsagVerify(message, sig, ring, ki, pseudo), isTrue);
    expect(clsagVerify(Uint8List(32), sig, ring, ki, pseudo), isFalse);
    // A pseudo output with another amount breaks it.
    expect(clsagVerify(message, sig, ring, ki, commit(pseudoMask, amount + 1).encode()), isFalse);
  });
}
