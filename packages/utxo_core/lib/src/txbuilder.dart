import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'block.dart';
import 'bytes.dart';
import 'params.dart';

/// An output the wallet can spend, with its key.
class Spendable {
  final OutPoint outpoint;
  final int value;
  final Uint8List script; // the P2PKH script it pays
  final BigInt key;
  final bool compressed;
  const Spendable(this.outpoint, this.value, this.script, this.key, {this.compressed = true});
}

class InsufficientFunds implements Exception {
  final int needed, available;
  const InsufficientFunds(this.needed, this.available);
  @override
  String toString() => 'insufficient funds: need $needed, have $available';
}

/// Builds and signs legacy P2PKH transactions.
/// The coins a payment spends, its fee and its change (0 for none).
class TxPlan {
  final List<Spendable> coins;
  final int fee;
  final int change;
  const TxPlan(this.coins, this.fee, this.change);
}

abstract final class TxBuilder {
  /// Size estimate of a P2PKH transaction with compressed keys.
  static int estimateSize(int inputs, int outputs) => 10 + inputs * 148 + outputs * 34;

  /// The Bitcoin 0.8 `GetMinFee` rule: per started kB, plus one base fee
  /// per output below the chain's soft dust limit.
  static int minFee(ChainParams p, int bytes, Iterable<int> outputValues) =>
      (1 + bytes ~/ 1000) * p.minFeePerKb + outputValues.where((v) => v < p.softDustLimit).length * p.minFeePerKb;

  /// Chooses the coins for paying [amount]: the largest first. Change too
  /// small to be worth its fee goes to the fee instead.
  static TxPlan plan({required ChainParams params, required List<Spendable> available, required int amount}) {
    if (amount <= 0) throw ArgumentError('the amount must be positive');
    final coins = [...available]..sort((a, b) => b.value.compareTo(a.value));
    final picked = <Spendable>[];
    var sum = 0;
    for (final c in coins) {
      picked.add(c);
      sum += c.value;
      if (_withChange(params, picked.length, sum, amount) != null) break;
    }
    final withChange = _withChange(params, picked.length, sum, amount);
    if (withChange != null) return TxPlan(picked, withChange.$1, withChange.$2);
    final feeNoChange = minFee(params, estimateSize(picked.length, 1), [amount]);
    if (sum < amount + feeNoChange) throw InsufficientFunds(amount + feeNoChange, sum);
    return TxPlan(picked, sum - amount, 0);
  }

  /// (fee, change) with a change output worth having, or null.
  static (int, int)? _withChange(ChainParams params, int inputs, int sum, int amount) {
    final size = estimateSize(inputs, 2);
    var fee = minFee(params, size, [amount]);
    var change = sum - amount - fee;
    if (change < params.softDustLimit) {
      fee = minFee(params, size, [amount, 0]); // the change output is dust too
      change = sum - amount - fee;
    }
    return change >= params.minFeePerKb ? (fee, change) : null;
  }

  /// Pays [amount] to [toScript], sending the change to [changeScript].
  static Transaction pay({
    required ChainParams params,
    required List<Spendable> available,
    required Uint8List toScript,
    required int amount,
    required Uint8List changeScript,
    List<Spendable>? chosenOut,
  }) {
    final p = plan(params: params, available: available, amount: amount);
    chosenOut?.addAll(p.coins);
    final unsigned = Transaction(
      inputs: [for (final c in p.coins) TxIn(c.outpoint, Uint8List(0))],
      outputs: [TxOut(amount, toScript), if (p.change > 0) TxOut(p.change, changeScript)],
    );
    return sign(unsigned, p.coins);
  }

  /// Signs every input (SIGHASH_ALL) with the matching [coins] key.
  static Transaction sign(Transaction tx, List<Spendable> coins) {
    final signed = <TxIn>[];
    for (var i = 0; i < tx.inputs.length; i++) {
      final c = coins[i];
      final hash = legacySighash(tx, i, c.script);
      final (r, s) = Secp256k1.sign(c.key, hash);
      final sig = [...Secp256k1.der(r, s), 0x01];
      final pub = Secp256k1.publicKey(c.key).encode(compressed: c.compressed);
      final script = Uint8List.fromList([sig.length, ...sig, pub.length, ...pub]);
      signed.add(TxIn(tx.inputs[i].prevout, script, tx.inputs[i].sequence));
    }
    return Transaction(version: tx.version, inputs: signed, outputs: tx.outputs, lockTime: tx.lockTime);
  }

  /// The pre-SegWit signature hash of input [index] with SIGHASH_ALL.
  static Uint8List legacySighash(Transaction tx, int index, Uint8List prevScript, {int hashType = 1}) {
    final copy = Transaction(
      version: tx.version,
      inputs: [
        for (var i = 0; i < tx.inputs.length; i++)
          TxIn(tx.inputs[i].prevout, i == index ? prevScript : Uint8List(0), tx.inputs[i].sequence),
      ],
      outputs: tx.outputs,
      lockTime: tx.lockTime,
    );
    final w = ByteWriter();
    copy.write(w);
    w.u32(hashType);
    return sha256d(w.take());
  }
}
