import 'dart:math';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../monero/address.dart';
import '../util/bytes.dart';
import 'bulletproofs_plus.dart';
import 'clsag.dart';
import 'decoys.dart';
import 'outputs.dart';
import 'scanner.dart';
import 'transaction.dart';

/// An output we spend: its secret key, amount, mask and ring.
class SpendInput {
  final OwnedOutput output;
  final Uint8List secret;
  final Ring ring;
  SpendInput(this.output, this.secret, this.ring);
}

class Destination {
  final MoneroAddress address;
  final int amount;
  Destination(this.address, this.amount);
}

class BuiltTx {
  final Uint8List blob;
  final String hash;
  final int fee;
  final int change;
  final List<Uint8List> keyImages;

  /// The transaction private key r (R = rG is in its extra): what a
  /// tx-key proof signs with (tx_key_proof.dart). Keep it secret.
  final Uint8List txKey;
  BuiltTx(this.blob, this.hash, this.fee, this.change, this.keyImages, this.txKey);
}

/// Weight for fees (src/cryptonote_basic/cryptonote_format_utils.cpp): the
/// blob size plus the Bulletproofs+ clawback above 2 outputs.
int txWeight(int blobSize, int outputs) {
  var padded = 1;
  while (padded < outputs) {
    padded <<= 1;
  }
  if (padded <= 2) return blobSize;
  var nlr = 0;
  while ((1 << nlr) < padded) {
    nlr++;
  }
  nlr += 6;
  const bpBase = (32 * (6 + 7 * 2)) ~/ 2;
  final bpSize = 32 * (6 + 2 * nlr);
  return blobSize + (bpBase * padded - bpSize) * 4 ~/ 5;
}

/// Builds and signs a RingCT (type 6) transaction: CLSAG rings of 16,
/// Bulletproofs+, view tags. The fee is [feePerByte] times the weight,
/// rounded up to [quantization]; the rest goes to [change] (always an
/// output, as Monero requires at least two).
BuiltTx buildTransaction({
  required List<SpendInput> inputs,
  required List<Destination> destinations,
  required MoneroAddress change,
  required int feePerByte,
  required int quantization,
}) {
  final rng = Random.secure();
  final totalIn = inputs.fold<int>(0, (a, i) => a + i.output.amount);
  final totalOut = destinations.fold<int>(0, (a, d) => a + d.amount);
  // Inputs sorted by key image, descending (consensus).
  final ins = [...inputs]..sort((a, b) {
      final ka = a.output.keyImage!, kb = b.output.keyImage!;
      for (var i = 0; i < 32; i++) {
        if (ka[i] != kb[i]) return kb[i].compareTo(ka[i]);
      }
      return 0;
    });
  final useAdditional = destinations.any((d) => d.address.kind == AddressKind.subaddress);
  final r = randomScalar();
  final order = [for (var i = 0; i <= destinations.length; i++) i]..shuffle(rng);
  final addSecrets = [for (var i = 0; i <= destinations.length; i++) randomScalar()];

  // A 2-input, 2-output transaction is about 1.5 kB; the loop settles the
  // exact weight.
  var fee = feePerByte * 1500;
  for (var round = 0; round < 8; round++) {
    final changeAmount = totalIn - totalOut - fee;
    if (changeAmount < 0) throw StateError('not enough funds for the amount and a fee of $fee');
    final targets = [...destinations, Destination(change, changeAmount)];
    final outs = <NewOutput>[];
    for (var pos = 0; pos < order.length; pos++) {
      final t = targets[order[pos]];
      outs.add(makeOutput(t.address, t.amount, pos, r, additional: useAdditional ? addSecrets[pos] : null));
    }
    final extra = txExtra(scalarMultBase(r).encode(), useAdditional ? [for (final o in outs) o.additionalKey!] : const []);
    final txInputs = [for (final i in ins) TxInToKey(0, i.ring.keyOffsets, i.output.keyImage!)];
    final prefix = TxWriter.prefix(unlockTime: 0, inputs: txInputs, outputs: [for (final o in outs) o.out], extra: extra);
    final base = TxWriter.base(fee: fee, ecdhAmounts: [for (final o in outs) o.ecdhAmount], outPk: [for (final o in outs) o.commitment]);
    final proof = bulletproofPlusProve([for (final o in outs) o.amount], [for (final o in outs) o.mask]);

    // Pseudo outputs: random masks that sum to the output masks.
    final pseudoMasks = <Uint8List>[];
    var acc = scFromInt(0);
    for (var i = 0; i < ins.length - 1; i++) {
      final m = randomScalar();
      pseudoMasks.add(m);
      acc = scAdd(acc, m);
    }
    final outMaskSum = outs.fold<Uint8List>(scFromInt(0), (a, o) => scAdd(a, o.mask));
    pseudoMasks.add(scSub(outMaskSum, acc));
    final pseudoOuts = [for (var i = 0; i < ins.length; i++) commit(pseudoMasks[i], ins[i].output.amount).encode()];

    final message = MoneroTx.clsagMessageFor(Keccak.hash256(prefix), base, proof);
    final sigs = <Clsag>[];
    for (var i = 0; i < ins.length; i++) {
      final input = ins[i];
      final (sig, ki) = clsagSign(message, input.ring.members, input.ring.realPosition, input.secret, input.output.mask,
          pseudoOuts[i], pseudoMasks[i]);
      if (!bytesEqual(ki, input.output.keyImage!)) throw StateError('key image mismatch');
      sigs.add(sig);
    }
    final prunable = TxWriter.prunable(proof: proof, clsags: sigs, pseudoOuts: pseudoOuts);
    final blob = Uint8List.fromList([...prefix, ...base, ...prunable]);
    final needed = ((txWeight(blob.length, outs.length) * feePerByte + quantization - 1) ~/ quantization) * quantization;
    if (needed > fee || (round == 0 && needed < fee)) {
      fee = needed;
      continue;
    }
    // Self-check before anything leaves the device.
    final tx = MoneroTx.parse(blob);
    if (!bulletproofPlusVerify(tx.bulletproofsPlus!.single, tx.outPk)) throw StateError('range proof self-check failed');
    for (var i = 0; i < ins.length; i++) {
      if (!clsagVerify(tx.clsagMessage, tx.clsags![i], ins[i].ring.members, ins[i].output.keyImage!, tx.pseudoOuts![i])) {
        throw StateError('signature self-check failed');
      }
    }
    return BuiltTx(blob, toHex(tx.hash), fee, changeAmount, [for (final i in ins) i.output.keyImage!], r);
  }
  throw StateError('the fee did not settle');
}
