import 'dart:async';
import 'dart:io';

import 'package:cesc_core/cesc_core.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:net_core/net_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Solo mines Cryptoescudo on the first GPU.
///   dart run tool/cesc_cli.dart --data DIR [--address C...] [--effort 25] [--minutes M]
///     [--cpu THREADS] [--no-gpu]
/// Without --address it uses (or creates) DIR/wallet-mnemonic.txt and pays
/// m/44'/111'/0'/0/0 of it.
Future<void> main(List<String> args) async {
  String? opt(String n) {
    final i = args.indexOf('--$n');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final p = Cryptoescudo.params;
  final dir = opt('data') ?? '${Platform.environment['HOME']}/.local/share/minerfan/cryptoescudo';
  Directory(dir).createSync(recursive: true);
  Address payTo;
  if (opt('address') != null) {
    payTo = Address.parse(opt('address')!, p) ?? (throw ArgumentError('not a CESC address'));
  } else {
    final f = File('$dir/wallet-mnemonic.txt');
    if (!f.existsSync()) {
      f.writeAsStringSync('${Bip39.generate(words: 24)}\n');
      await Process.run('chmod', ['600', f.path]);
      stdout.writeln('created a new wallet mnemonic in ${f.path} (keep it safe)');
    }
    final key = HdKey.master(Bip39.seed(f.readAsStringSync().trim())).derive("m/44'/111'/0'/0/0");
    payTo = Address.fromPublicKey(key.publicKey);
  }
  final effort = (double.tryParse(opt('effort') ?? '') ?? 25) / 100;
  stdout.writeln('paying ${payTo.encode(p)}, effort ${(effort * 100).toStringAsFixed(0)}% of the network');
  void log(String s) => stdout.writeln('${DateTime.now().toIso8601String().substring(11, 19)} $s');
  final node = UtxoNode(params: p, transport: IoTransport(), checkpoint: cryptoescudoCheckpoint(), dataDir: dir, log: log);
  await node.start();
  final cpu = int.tryParse(opt('cpu') ?? '') ?? 0;
  final devices = <HeaderMiner>[
    if (!args.contains('--no-gpu')) GpuScryptMiner(),
    if (cpu > 0) CpuHeaderMiner(pow: p.pow, threads: cpu),
  ];
  final miner = SoloMiner(node: node, payTo: payTo, effort: EffortController(effort), miners: devices, log: log);
  await miner.start();
  final status = Timer.periodic(const Duration(seconds: 20), (_) {
    final net = miner.networkHashrate;
    log('tip ${node.chain.tipHeight} (peers ${node.peerCount}, best ${node.bestPeerHeight}${node.synced ? ', synced' : ''}) | '
        '${(miner.hashrate / 1000).toStringAsFixed(1)} kH/s of ${(miner.fullSpeed / 1000).toStringAsFixed(1)}, duty ${(miner.duty * 100).toStringAsFixed(1)}% | '
        'network ${(net / 1000).toStringAsFixed(1)} kH/s, difficulty ${CompactTarget.difficulty(node.chain.tipBits).toStringAsFixed(5)} | '
        'found ${miner.found.length} (${miner.found.where((b) => b.accepted == true).length} accepted) | '
        'our share of last 30 ${(miner.observedShare * 100).toStringAsFixed(0)}%, guard ${miner.guard.toStringAsFixed(2)}');
  });
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  ProcessSignal.sigterm.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  final minutes = int.tryParse(opt('minutes') ?? '');
  if (minutes != null) Timer(Duration(minutes: minutes), () => done.isCompleted ? null : done.complete());
  await done.future;
  status.cancel();
  await miner.stop();
  await node.stop();
  for (final b in miner.found) {
    stdout.writeln('found ${b.height} ${b.hash} accepted=${b.accepted}');
  }
  exit(0);
}
