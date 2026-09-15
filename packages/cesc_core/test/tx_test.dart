import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cesc_core/cesc_core.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

/// Parses a DER signature (without the sighash byte) into (r, s).
(BigInt, BigInt) parseDer(List<int> d) {
  var i = 2;
  final rl = d[i + 1];
  final r = bytesToBig(d.sublist(i + 2, i + 2 + rl));
  i += 2 + rl;
  final sl = d[i + 1];
  final s = bytesToBig(d.sublist(i + 2, i + 2 + sl));
  return (r, s);
}

void main() {
  final p = Cryptoescudo.params;

  test('legacy sighash verifies a real Cryptoescudo signature', () {
    final f = jsonDecode(File('test/fixtures/tx_sighash.json').readAsStringSync()) as Map<String, Object?>;
    final tx = Transaction.parse(fromHex(f['tx']! as String));
    expect(tx.id, f['txid']);
    final prev = Transaction.parse(fromHex(f['prevTx']! as String));
    expect(prev.id, f['prevTxid']);
    final prevScript = prev.outputs[f['prevIndex']! as int].script;
    // scriptSig: <sig+hashtype> <pubkey>
    final ss = tx.inputs[0].script;
    final sig = ss.sublist(1, 1 + ss[0]);
    final pub = ss.sublist(2 + ss[0], 2 + ss[0] + ss[1 + ss[0]]);
    expect(sig.last, 1); // SIGHASH_ALL
    final (r, s) = parseDer(sig.sublist(0, sig.length - 1));
    final hash = TxBuilder.legacySighash(tx, 0, prevScript);
    expect(Secp256k1.verify(EcPoint.decode(pub)!, hash, r, s), isTrue);
    // And the pubkey hashes to the address the previous output paid.
    expect(Address.fromScript(prevScript), Address.fromPublicKey(pub));
  });

  test('builds, signs and verifies a payment with change and the CESC fee rule', () {
    final key = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    final me = Address.fromPublicKey(Secp256k1.publicKey(key).encode());
    final to = Address.parse('CSCiHCVaTb9181tjCvnrhmCxSjFruKX6YC', p)!;
    final coins = [
      Spendable(OutPoint(Uint8List(32)..[0] = 1, 0), 20 * Cryptoescudo.coin, me.script, key),
      Spendable(OutPoint(Uint8List(32)..[0] = 2, 1), 5 * Cryptoescudo.coin, me.script, key),
    ];
    final used = <Spendable>[];
    final tx = TxBuilder.pay(params: p, available: coins, toScript: to.script, amount: 3 * Cryptoescudo.coin,
        changeScript: me.script, chosenOut: used);
    expect(used.length, 1); // the 20 CESC output covers it
    expect(tx.outputs.first.value, 3 * Cryptoescudo.coin);
    final fee = 20 * Cryptoescudo.coin - tx.outputs.fold<int>(0, (a, o) => a + o.value);
    expect(fee, TxBuilder.minFee(p, TxBuilder.estimateSize(1, 2), tx.outputs.map((o) => o.value)));
    expect(fee, 100000); // one started kB, no output under 0.1 CESC
    // Each signature verifies against the sighash.
    final ss = tx.inputs[0].script;
    final sig = ss.sublist(1, 1 + ss[0]);
    final (r, s) = parseDer(sig.sublist(0, sig.length - 1));
    expect(Secp256k1.verify(Secp256k1.publicKey(key), TxBuilder.legacySighash(tx, 0, me.script), r, s), isTrue);
    expect(() => TxBuilder.pay(params: p, available: coins, toScript: to.script, amount: 30 * Cryptoescudo.coin, changeScript: me.script),
        throwsA(isA<InsufficientFunds>()));
    // A small payment pays one more base fee (DUST_SOFT_LIMIT).
    final small = TxBuilder.pay(params: p, available: coins, toScript: to.script, amount: 5000000, changeScript: me.script);
    final smallFee = 20 * Cryptoescudo.coin - small.outputs.fold<int>(0, (a, o) => a + o.value);
    expect(smallFee, 200000);
    // Change that ends up under 0.1 CESC is dust too: one more base fee.
    final plan = TxBuilder.plan(params: p, available: coins.sublist(0, 1), amount: 20 * Cryptoescudo.coin - 5000000);
    expect(plan.fee, 200000);
    expect(plan.change, 5000000 - 200000);
    // Change worth less than a base fee goes to the fee.
    final all = TxBuilder.plan(params: p, available: coins.sublist(0, 1), amount: 20 * Cryptoescudo.coin - 150000);
    expect(all.change, 0);
    expect(all.fee, 150000);
  });
}
