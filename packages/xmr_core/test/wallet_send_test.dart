import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ec_ops.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/wallet/account.dart';
import 'package:xmr_core/src/wallet/decoys.dart';
import 'package:xmr_core/src/wallet/outputs.dart';
import 'package:xmr_core/src/wallet/scanner.dart';
import 'package:xmr_core/src/wallet/transaction.dart';
import 'package:xmr_core/src/wallet/tx_builder.dart';
import 'package:xmr_core/src/wallet/tx_key_proof.dart';

/// Receives two outputs, spends them to another wallet with change back,
/// and checks the result from both sides (offline: rings of random keys).
void main() {
  test('build, sign, self-verify and scan a payment', () {
    final (me, _) = MoneroAccount.generate();
    final (friend, _) = MoneroAccount.generate();
    final scanner = MoneroScanner(me);
    final owned = <OwnedOutput>[];
    for (final amount in [700000000, 400000000]) {
      final r = randomScalar();
      final o = makeOutput(me.address, amount, 0, r);
      final o2 = makeOutput(friend.address, 1, 1, r);
      final prefix = TxWriter.prefix(
          unlockTime: 0, inputs: [TxInToKey(0, [1], Uint8List(32))], outputs: [o.out, o2.out], extra: txExtra(txPublicKey(r, null), const []));
      final base = TxWriter.base(fee: 1, ecdhAmounts: [o.ecdhAmount, o2.ecdhAmount], outPk: [o.commitment, o2.commitment]);
      owned.addAll(scanner.scan(MoneroTx.parse(Uint8List.fromList([...prefix, ...base]), pruned: true, prunableHash: Uint8List(32)), 'x', 1));
    }
    expect(owned.map((o) => o.amount), [700000000, 400000000]);
    final inputs = <SpendInput>[];
    var g = 1000;
    for (final o in owned) {
      final members = [
        for (var i = 0; i < 16; i++)
          i == 3 ? (key: o.key, commitment: o.commitment) : (key: scalarMultBase(randomScalar()).encode(), commitment: scalarMultBase(randomScalar()).encode()),
      ];
      inputs.add(SpendInput(o, scanner.outputSecret(o), Ring([for (var i = 0; i < 16; i++) g + i * 7], members, 3)));
      g += 500;
    }
    final sw = Stopwatch()..start();
    final built = buildTransaction(
      inputs: inputs,
      destinations: [Destination(friend.subaddress(0, 2), 900000000)],
      change: me.address,
      feePerByte: 20000,
      quantization: 10000,
    );
    print('built ${built.blob.length} bytes, fee ${built.fee} in ${sw.elapsedMilliseconds} ms');
    expect(built.fee, txWeight(built.blob.length, 2) * 20000 ~/ 10000 * 10000 + (txWeight(built.blob.length, 2) * 20000 % 10000 == 0 ? 0 : 10000));
    expect(built.change, 1100000000 - 900000000 - built.fee);
    final tx = MoneroTx.parse(built.blob);
    expect(tx.inputs.length, 2);
    expect(tx.rctType, RctTypes.bulletproofPlus);
    // Key images descending.
    final k0 = (tx.inputs[0] as TxInToKey).keyImage, k1 = (tx.inputs[1] as TxInToKey).keyImage;
    var cmp = 0;
    for (var i = 0; i < 32 && cmp == 0; i++) {
      cmp = k0[i].compareTo(k1[i]);
    }
    expect(cmp, greaterThan(0));
    final got = MoneroScanner(friend).scan(tx, built.hash, 10).single;
    expect((got.amount, got.minor), (900000000, 2));
    expect(MoneroScanner(me).scan(tx, built.hash, 10).single.amount, built.change);
    // The kept tx key is the one behind R in the extra: a proof made with it
    // verifies against the transaction as the receiver sees it.
    final pub = tx.txPublicKeys.$1!;
    expect(scalarMultBase(built.txKey).encode(), pub);
    final msg = Uint8List.fromList('claim ${built.hash}'.codeUnits);
    expect(verifyTxKeyProof(pub, msg, txKeyProof(built.txKey, msg)), isTrue);
  });
}
