import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:hex/hex.dart';
import 'package:utxo_core/utxo_core.dart' show verifyInputKeyProof;
import 'package:xmr_core/xmr_core.dart' show verifyTxKeyProof;
import 'package:xprs_room/xprs_room.dart';

import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';
import 'claims.dart';
import 'config.dart';

// Top-level proof checks, so the isolate's closures hold only their values.
Future<bool> _checkMonero(String txPub, String message, String proof) => Isolate.run(() {
      try {
        return verifyTxKeyProof(HEX.decode(txPub), utf8.encode(message), HEX.decode(proof));
      } catch (_) {
        return false;
      }
    });

Future<bool> _checkInput(String pub, String message, String proof) => Isolate.run(() {
      try {
        return verifyInputKeyProof(HEX.decode(pub), utf8.encode(message), HEX.decode(proof));
      } catch (_) {
        return false;
      }
    });

/// The admin's side of the bought moderator terms. For each claim that
/// reaches the admin's app: find the payment in the room's moderation wallet
/// (the admin's own, whose address is the published one), check that it is
/// confirmed, recent and unused, that the proof was made by whoever paid,
/// and take the amount from the wallet, never from the claim. A payment that
/// beats the running term (or any payment when there is none) gets a new
/// 30-day grant.
class ModerationAdmin {
  final List<Wallet> Function() wallets;
  final String dataDir;
  final void Function(String line) log;
  final _used = <String>{};
  bool _loaded = false;
  ModerationAdmin({required this.wallets, required this.dataDir, required this.log});

  File get _file => File('$dataDir/rooms/admin-used-payments.json');

  /// The admin's wallet that receives [coin]'s room payments, or null.
  Wallet? walletFor(String coin) {
    final address = ModerationConfig.address(coin);
    if (address == null) return null;
    for (final w in wallets()) {
      if (w.chain != coin) continue;
      if (w is MoneroWallet && w.address == address) return w;
      if (w is UtxoWallet && w.firstAddress == address) return w;
    }
    return null;
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (await _file.exists()) _used.addAll([for (final t in jsonDecode(await _file.readAsString()) as List) '$t']);
    } catch (_) {}
  }

  Future<void> _saveUsed() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_used.toList()));
    } catch (_) {}
  }

  /// Decides on [claim] for [engine]'s room. Returns what happened, for the
  /// log; a claim whose payment is not confirmed yet is left for the
  /// buyer's next resend.
  Future<String> decide(RoomEngine engine, RoomClaim claim) async {
    await _load();
    final c = ModClaim.fromJson(claim.data);
    if (c == null || c.room != engine.room) return 'malformed claim from ${claim.callsign}';
    final w = walletFor(c.coin);
    if (w == null) return 'no moderation wallet for ${c.coin}';
    if (_used.contains(c.txid)) return 'payment ${c.txid.substring(0, 8)} already used';
    final message = '${ModerationConfig.claimMessage(engine.room, claim.callsign)}${c.txid}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final maxAge = ModerationConfig.claimLife.inSeconds;
    BigInt amount;
    switch (w) {
      case MoneroWallet():
        final e = w.status?.history.where((e) => e.txid == c.txid).firstOrNull;
        if (e == null || e.height == null) return 'payment ${c.txid.substring(0, 8)} not confirmed yet';
        if (e.received <= 0 || e.txPub == null) return 'payment ${c.txid.substring(0, 8)} did not pay the room';
        if (now - e.time > maxAge) return 'payment ${c.txid.substring(0, 8)} is too old';
        if (!await _checkMonero(e.txPub!, message, c.proof)) return 'bad proof from ${claim.callsign}';
        amount = BigInt.from(e.received);
      case UtxoWallet():
        final e = w.status?.history.where((e) => e.txid == c.txid).firstOrNull;
        if (e == null || e.height == null) return 'payment ${c.txid.substring(0, 8)} not confirmed yet';
        if (e.received <= 0 || c.pub == null || !e.inputKeys.contains(c.pub)) {
          return 'payment ${c.txid.substring(0, 8)} was not made by ${claim.callsign}';
        }
        if (now - e.time > maxAge) return 'payment ${c.txid.substring(0, 8)} is too old';
        if (!await _checkInput(c.pub!, message, c.proof)) return 'bad proof from ${claim.callsign}';
        amount = BigInt.from(e.received);
      default:
        return 'unsupported wallet';
    }
    final m = engine.moderation;
    if (m.term != null && amount <= m.toBeat) {
      _used.add(c.txid);
      await _saveUsed();
      return 'payment of $amount by ${claim.callsign} does not beat ${m.toBeat}';
    }
    final r = await engine.grantTerm(claim.callsign, amount);
    if (r != Moderated.done) return 'could not grant: ${r.name}';
    _used.add(c.txid);
    await _saveUsed();
    return 'granted a 30-day term to ${claim.callsign} for $amount';
  }
}
