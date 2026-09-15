import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/monero_keys.dart';
import '../monero/address.dart';
import 'scanner.dart';
import 'transaction.dart';

/// One output a sender creates (src/cryptonote_core/cryptonote_tx_utils.cpp,
/// BSD-3): the one-time key, view tag, encrypted amount and commitment.
class NewOutput {
  final TxOut out;
  final Uint8List ecdhAmount;
  final Uint8List mask;
  final Uint8List commitment;
  final int amount;

  /// Its additional public key when the transaction uses them.
  final Uint8List? additionalKey;
  NewOutput(this.out, this.ecdhAmount, this.mask, this.commitment, this.amount, this.additionalKey);
}

/// Pays [amount] to [to] as output [index] of a transaction with secret key
/// [r]. With [additional] (a per-output secret, used when any destination
/// is a subaddress) the output gets its own public key.
NewOutput makeOutput(MoneroAddress to, int amount, int index, Uint8List r, {Uint8List? additional}) {
  final isSub = to.kind == AddressKind.subaddress;
  final secret = additional ?? r;
  // Derivation from the sender's side: 8 * r * (view key of the destination).
  final d = pointMul8(scalarMult(secret, decodePoint(to.viewKey))).encode();
  final s = derivationToScalar(d, index);
  final key = pointSum(scalarMultBase(s), decodePoint(to.spendKey)).encode();
  final f = amountFactor(s);
  final enc = Uint8List(8);
  var a = amount;
  for (var k = 0; k < 8; k++) {
    enc[k] = (a & 0xff) ^ f[k];
    a >>= 8;
  }
  final mask = commitmentMask(s);
  Uint8List? addKey;
  if (additional != null) {
    addKey = isSub ? scalarMult(additional, decodePoint(to.spendKey)).encode() : scalarMultBase(additional).encode();
  }
  return NewOutput(TxOut(0, key, deriveViewTag(d, index)), enc, mask, commit(mask, amount).encode(), amount, addKey);
}

/// The transaction public key: r * G, or r * (spend key) when the only
/// destination is one subaddress (no additional keys).
Uint8List txPublicKey(Uint8List r, MoneroAddress? singleSubaddress) =>
    singleSubaddress == null ? scalarMultBase(r).encode() : scalarMult(r, decodePoint(singleSubaddress.spendKey)).encode();

/// tx extra with the public key (tag 1) and additional keys (tag 4),
/// sorted as Monero writes them.
Uint8List txExtra(Uint8List txPub, List<Uint8List> additional) {
  final b = BytesBuilder(copy: false)
    ..addByte(0x01)
    ..add(txPub);
  if (additional.isNotEmpty) {
    b.addByte(0x04);
    b.addByte(additional.length); // varint, fewer than 128 outputs
    additional.forEach(b.add);
  }
  return b.takeBytes();
}
