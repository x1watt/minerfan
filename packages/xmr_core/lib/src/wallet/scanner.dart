import 'dart:convert';
import 'dart:typed_data';

import '../crypto/ec_ops.dart';
import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../crypto/monero_keys.dart';
import '../util/bytes.dart';
import 'account.dart';
import 'transaction.dart';

/// The second RingCT generator H (src/ringct/rctTypes.h).
final Point pointH = Point.decode(fromHex('8b655970153799af2aeadc9ff1add0ea6c7251d54154cfa92c173a0dd39c1f94'))!;

/// C = mask * G + amount * H.
Point commit(List<int> mask, int amount) => pointSum(scalarMultBase(mask), scalarMult(scFromInt(amount), pointH));

final List<int> _amountSalt = utf8.encode('amount');
final List<int> _maskSalt = utf8.encode('commitment_mask');

/// 8-byte amount encryption factor for output secret [s] = Hs(D || i).
Uint8List amountFactor(List<int> s) => Keccak.hash256([..._amountSalt, ...s]);

/// Commitment mask of an output from its secret [s].
Uint8List commitmentMask(List<int> s) => hashToScalarBytes([..._maskSalt, ...s]);

/// An output of ours, found while scanning.
class OwnedOutput {
  final String txHash;
  final int index;
  final int amount;
  final Uint8List mask;
  final Uint8List key;
  final Uint8List commitment;

  /// Hs(D || i), with which the spend key gives the output's secret.
  final Uint8List secretOffset;
  final int major, minor;
  final Uint8List? keyImage;
  final int height;
  final int unlockTime;
  final bool coinbase;

  /// Position among the RingCT outputs of its block (coinbase first, then
  /// the transactions in order): with the output distribution it gives the
  /// global index spending needs.
  int? blockOffset;

  /// Global output index (needed to spend).
  int? globalIndex;
  String? spentIn;
  int? spentHeight;

  OwnedOutput({
    required this.txHash,
    required this.index,
    required this.amount,
    required this.mask,
    required this.key,
    required this.commitment,
    required this.secretOffset,
    required this.major,
    required this.minor,
    required this.keyImage,
    required this.height,
    required this.unlockTime,
    required this.coinbase,
    this.blockOffset,
    this.globalIndex,
    this.spentIn,
    this.spentHeight,
  });

  String get id => '$txHash:$index';

  Map<String, Object?> toJson() => {
        'tx': txHash,
        'i': index,
        'a': amount,
        'm': toHex(mask),
        'k': toHex(key),
        'c': toHex(commitment),
        's': toHex(secretOffset),
        'sub': [major, minor],
        'ki': keyImage == null ? null : toHex(keyImage!),
        'h': height,
        'u': unlockTime,
        'cb': coinbase,
        'bo': blockOffset,
        'g': globalIndex,
        'sp': spentIn,
        'sph': spentHeight,
      };

  static OwnedOutput fromJson(Map<String, Object?> j) => OwnedOutput(
        txHash: j['tx']! as String,
        index: j['i']! as int,
        amount: j['a']! as int,
        mask: fromHex(j['m']! as String),
        key: fromHex(j['k']! as String),
        commitment: fromHex(j['c']! as String),
        secretOffset: fromHex(j['s']! as String),
        major: (j['sub']! as List)[0] as int,
        minor: (j['sub']! as List)[1] as int,
        keyImage: j['ki'] == null ? null : fromHex(j['ki']! as String),
        height: j['h']! as int,
        unlockTime: j['u']! as int,
        coinbase: j['cb']! as bool,
        blockOffset: j['bo'] as int?,
        globalIndex: j['g'] as int?,
        spentIn: j['sp'] as String?,
        spentHeight: j['sph'] as int?,
      );
}

/// Finds a wallet's outputs in transactions. The view key finds them
/// (the one-byte view tag skips almost all others after one scalar
/// multiplication per transaction); the spend key gives their key images.
class MoneroScanner {
  final MoneroAccount account;
  final Map<String, (int, int)> _subaddresses;

  MoneroScanner(this.account, {int minors = 50}) : _subaddresses = account.subaddressTable(minors: minors);

  /// Our outputs in [tx] (id [txHash], at [height]). [firstOffset] is the
  /// block position of the transaction's first output.
  List<OwnedOutput> scan(MoneroTx tx, String txHash, int height, {int? firstOffset}) {
    final (main, additional) = tx.txPublicKeys;
    final derivations = <Uint8List?>[
      if (main != null) generateKeyDerivation(main, account.viewSecret),
    ];
    final extra = [for (final k in additional) generateKeyDerivation(k, account.viewSecret)];
    final found = <OwnedOutput>[];
    for (var i = 0; i < tx.outputs.length; i++) {
      final o = tx.outputs[i];
      for (final d in [...derivations, if (i < extra.length) extra[i]]) {
        if (d == null) continue;
        if (o.viewTag != null && deriveViewTag(d, i) != o.viewTag) continue;
        final s = derivationToScalar(d, i);
        // B' = P - Hs(D||i)G must be one of our spend keys.
        final spend = pointDiff(decodePoint(o.key), scalarMultBase(s)).encode();
        final sub = _subaddresses[toHex(spend)];
        if (sub == null) continue;
        final out = _own(tx, txHash, height, i, s, sub);
        if (out != null) {
          if (firstOffset != null) out.blockOffset = firstOffset + i;
          found.add(out);
        }
        break;
      }
    }
    return found;
  }

  OwnedOutput? _own(MoneroTx tx, String txHash, int height, int i, Uint8List s, (int, int) sub) {
    final o = tx.outputs[i];
    int amount;
    Uint8List mask, commitment;
    if (tx.rctType == RctTypes.nullType) {
      // Coinbase (or pre-RingCT): plain amount, mask 1.
      amount = o.amount;
      mask = scFromInt(1);
      commitment = commit(mask, amount).encode();
    } else {
      final f = amountFactor(s);
      final enc = tx.ecdhAmounts[i];
      var a = 0;
      for (var k = 7; k >= 0; k--) {
        a = (a << 8) | (enc[k] ^ f[k]);
      }
      amount = a;
      mask = commitmentMask(s);
      commitment = tx.outPk[i];
      // A sender could put a wrong amount: it must open the commitment.
      if (!bytesEqual(commit(mask, amount).encode(), commitment)) return null;
    }
    Uint8List? keyImage;
    final b = account.spendSecret;
    if (b != null) {
      var x = scAdd(s, b);
      if (sub != (0, 0)) x = scAdd(x, account.subaddressScalar(sub.$1, sub.$2));
      keyImage = generateKeyImage(o.key, x);
    }
    return OwnedOutput(
      txHash: txHash,
      index: i,
      amount: amount,
      mask: mask,
      key: o.key,
      commitment: commitment,
      secretOffset: s,
      major: sub.$1,
      minor: sub.$2,
      keyImage: keyImage,
      height: height,
      unlockTime: tx.unlockTime,
      coinbase: tx.isCoinbase,
    );
  }

  /// The one-time secret key of an owned output (spending needs it).
  Uint8List outputSecret(OwnedOutput o) {
    var x = scAdd(o.secretOffset, account.spendSecret!);
    if (o.major != 0 || o.minor != 0) x = scAdd(x, account.subaddressScalar(o.major, o.minor));
    return x;
  }
}

/// Spendable at chain height [chainHeight] (number of blocks): 10 blocks
/// after inclusion, coinbase outputs at their unlock height (60 blocks).
bool isUnlocked(OwnedOutput o, int chainHeight) {
  if (chainHeight < o.height + 10) return false;
  if (o.unlockTime == 0) return true;
  if (o.unlockTime < 500000000) return chainHeight >= o.unlockTime;
  return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= o.unlockTime;
}
