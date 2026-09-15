import 'dart:async';
import 'dart:io';

import 'package:cesc_core/cesc_core.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Runs the chain service (the app's isolate host) for a while: opens the
/// wallet of MNEMONIC_FILE and, with --mine, mines to its first address.
///   dart run tool/service_probe.dart MNEMONIC_FILE|ACCOUNT_XPUB DATA_DIR [--mine] [--cpu N] [--seconds S]
///     [--send-to ADDRESS|self --amount CESC]  (self: the wallet's next receive address)
Future<void> main(List<String> args) async {
  String? opt(String n) {
    final i = args.indexOf('--$n');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final p = Cryptoescudo.params;
  // A phrase file (can mine and send) or an account xpub (watch only).
  final account = args[0].startsWith('xpub')
      ? HdKey.parse(args[0])!
      : HdKey.master(Bip39.seed(File(args[0]).readAsStringSync().trim())).derive("m/44'/111'/0'");
  final first = Address.fromPublicKey(account.child(0).child(0).publicKey).encode(p);
  final h = await ChainHandle.spawn(
      ChainServiceConfig(params: p, checkpoint: cryptoescudoCheckpoint(), dataDir: args[1]));
  h.log.listen(stdout.writeln);
  await h.openWallet('w1', account.neutered().serialize(), 0);
  if (args.contains('--mine')) {
    await h.startMining(MiningConfig(
        payTo: first, effort: 0.25, gpuDevice: args.contains('--no-gpu') ? null : 0, cpuThreads: int.tryParse(opt('cpu') ?? '') ?? 0));
  }
  final seconds = int.tryParse(opt('seconds') ?? '') ?? 60;
  for (var i = 0; i < seconds ~/ 10; i++) {
    await Future<void>.delayed(const Duration(seconds: 10));
    final s = h.last;
    if (s == null) continue;
    final m = s.mining;
    final w = s.wallets['w1'];
    stdout.writeln('status: tip ${s.tip} peers ${s.peers} synced ${s.synced} net ${(s.networkHashrate / 1000).toStringAsFixed(1)} kH/s'
        '${m == null ? '' : ' | mining ${m.mining} ${(m.hashrate / 1000).toStringAsFixed(1)} of ${(m.fullSpeed / 1000).toStringAsFixed(1)} kH/s duty ${(m.duty * 100).toStringAsFixed(1)}% on ${m.devices}'}'
        '${w == null ? '' : ' | wallet scanned ${w.history.map((t) => '${t.txid.substring(0, 8)}@${t.height}:${t.net}').join(',')} ${w.scanned} confirmed ${w.balance.confirmed / 1e8} immature ${w.balance.immature / 1e8} receive ${w.receiveAddress}'}'
        ' | found ${s.found.length}');
  }
  final sendTo = opt('send-to');
  if (sendTo != null) {
    final to = sendTo == 'self' ? h.last!.wallets['w1']!.receiveAddress : sendTo;
    final amount = (double.parse(opt('amount')!) * Cryptoescudo.coin).round();
    final (fee, change) = await h.preview('w1', amount);
    stdout.writeln('sending $amount to $to, fee $fee, change $change');
    final txid = await h.send('w1', to, amount, account.serialize());
    stdout.writeln('sent $txid');
    for (var i = 0; i < 90; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final w = h.last!.wallets['w1']!;
      final t = w.history.where((t) => t.txid == txid).firstOrNull;
      stdout.writeln('tip ${h.last!.tip} tx height ${t?.height} | confirmed ${w.balance.confirmed / 1e8} '
          'immature ${w.balance.immature / 1e8} pending ${w.balance.pending / 1e8}');
      if (t?.height != null) break;
    }
  }
  if (args.contains('--mine')) {
    try {
      final (fee, change) = await h.preview('w1', 100000000);
      stdout.writeln('preview 1 CESC: fee $fee change $change');
    } catch (e) {
      stdout.writeln('preview: $e');
    }
  }
  await h.stop();
  exit(0);
}
