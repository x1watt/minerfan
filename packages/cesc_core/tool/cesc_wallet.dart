import 'dart:async';
import 'dart:io';

import 'package:cesc_core/cesc_core.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:net_core/net_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// SPV wallet check: syncs, scans from the checkpoint and prints the
/// balance of the mnemonic in MNEMONIC_FILE (BIP44 account 0).
///   dart run tool/cesc_wallet.dart MNEMONIC_FILE DATA_DIR
Future<void> main(List<String> args) async {
  final p = Cryptoescudo.params;
  final mnemonic = File(args[0]).readAsStringSync().trim();
  final account = HdKey.master(Bip39.seed(mnemonic)).derive("m/44'/111'/0'").neutered();
  void log(String s) => stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)} $s');
  final cp = cryptoescudoCheckpoint();
  final node = UtxoNode(params: p, transport: IoTransport(), checkpoint: cp, dataDir: args[1], log: log);
  await node.start();
  final wallet = SpvWallet(node: node, account: account, birthday: cp.height + 1, file: '${args[1]}/wallet.json', log: log);
  await wallet.start();
  log('receive address ${wallet.receiveAddress.encode(p)}');
  for (var i = 0; i < 24; i++) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final b = wallet.balance;
    log('tip ${node.chain.tipHeight} scanned ${wallet.scanned} | confirmed ${b.confirmed / 1e8} immature ${b.immature / 1e8} pending ${b.pending / 1e8} CESC | coins ${wallet.coins.length}');
    if (node.synced && wallet.scanned >= node.chain.tipHeight && i > 3) break;
  }
  for (final t in wallet.history.values) {
    log('history: ${t.txid} height ${t.height} ${t.net / 1e8} CESC${t.coinbase ? ' (mined)' : ''}');
  }
  await wallet.stop();
  await node.stop();
  exit(0);
}
