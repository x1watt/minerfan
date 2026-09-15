import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:hex/hex.dart';
import 'package:xmr_core/xmr_core.dart' show txKeyProof;

import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';
import 'config.dart';

/// A request to hold a room's moderator rights, backed by a payment made
/// from this device's wallet and a proof that this device made it (the
/// Monero tx key, or the key of the Cryptoescudo input, signing the claim
/// message and txid). It holds no secret: the proof speaks for this callsign
/// and this payment only.
class ModClaim {
  final String room;
  final String coin;
  final String txid;
  final BigInt amount;
  final String proof;

  /// The input's public key (Cryptoescudo only).
  final String? pub;
  final int tsMs;
  ModClaim(this.room, this.coin, this.txid, this.amount, this.proof, this.pub, this.tsMs);

  Map<String, Object?> toJson() => {
        'v': 1,
        'room': room,
        'coin': coin,
        'txid': txid,
        'amount': '$amount',
        'proof': proof,
        if (pub != null) 'pub': pub,
        'ts': tsMs,
      };

  static ModClaim? fromJson(Map<String, Object?> m) {
    final amount = BigInt.tryParse('${m['amount']}');
    if (m['room'] is! String || m['coin'] is! String || m['txid'] is! String || m['proof'] is! String) return null;
    if (amount == null) return null;
    return ModClaim(m['room']! as String, m['coin']! as String, m['txid']! as String, amount, m['proof']! as String,
        m['pub'] as String?, (m['ts'] as num?)?.toInt() ?? 0);
  }
}

/// This device's open claims for one room (`claims.json` in the room's
/// folder): resent until a grant answers them or they grow too old.
class ClaimBook {
  final String file;
  final List<ModClaim> claims = [];
  ClaimBook(String roomDir) : file = '$roomDir/claims.json';

  Future<void> load() async {
    try {
      final f = File(file);
      if (!await f.exists()) return;
      for (final e in jsonDecode(await f.readAsString()) as List) {
        final c = e is Map ? ModClaim.fromJson(e.cast<String, Object?>()) : null;
        if (c != null) claims.add(c);
      }
    } catch (_) {}
  }

  Future<void> add(ModClaim c) async {
    claims.add(c);
    await _save();
  }

  Future<void> removeWhere(bool Function(ModClaim) test) async {
    final before = claims.length;
    claims.removeWhere(test);
    if (claims.length != before) await _save();
  }

  Future<void> _save() async {
    try {
      await File(file).parent.create(recursive: true);
      final tmp = File('$file.tmp');
      await tmp.writeAsString(jsonEncode([for (final c in claims) c.toJson()]), flush: true);
      await tmp.rename(file);
    } catch (_) {}
  }
}

// Top-level, so the isolate's closure holds only these values.
Future<String> _moneroProof(String txKeyHex, String message) =>
    Isolate.run(() => HEX.encode(txKeyProof(HEX.decode(txKeyHex), utf8.encode(message))));

/// Why a payment for the rights could not be made.
class ClaimError implements Exception {
  final String message;
  const ClaimError(this.message);
  @override
  String toString() => message;
}

/// Pays [amount] (the coin's smallest unit) from [wallet] to the room's
/// address and returns the claim for [callsign]. [password] unlocks a
/// wallet that has one.
Future<ModClaim> payForModeration(
    {required Wallet wallet, required String room, required String callsign, required BigInt amount, String? password}) async {
  final coin = wallet.chain;
  final to = ModerationConfig.address(coin) ?? (throw const ClaimError('This room has no moderator rights to buy.'));
  final message = ModerationConfig.claimMessage(room, callsign);
  final now = DateTime.now().millisecondsSinceEpoch;
  switch (wallet) {
    case MoneroWallet w when !w.viewOnly:
      final h = w.service.handle ?? (throw const ClaimError('The Monero wallet is not connected.'));
      if (w.hasPassword && await w.recoveryPhrase(password) == null) throw const ClaimError('Wrong password');
      final (txid, _, txKey) = await h.sendKeyed(w.id, to, amount.toInt());
      return ModClaim(room, coin, txid, amount, await _moneroProof(txKey, '$message$txid'), null, now);
    case UtxoWallet w:
      final h = w.service.handle ?? (throw const ClaimError('The wallet is not connected.'));
      final xprv = await w.unlock(w.hasPassword ? password : null) ?? (throw const ClaimError('Wrong password'));
      final (txid, pub, proof) = await h.sendProved(w.id, to, amount.toInt(), xprv, message);
      return ModClaim(room, coin, txid, amount, proof, pub, now);
    default:
      throw const ClaimError('This wallet cannot send.');
  }
}
