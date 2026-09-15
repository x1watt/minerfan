import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/crypto/keccak.dart';
import 'package:xmr_core/src/monero/address.dart';
import 'package:xmr_core/src/node/node.dart';
import 'package:xmr_core/src/randomx/memory.dart';

/// Headless node.
///   dart run tool/node_cli.dart --wallet 4... [--sidechain nano] [--threads N]
///       [--memory dart|shared] [--fast|--light] [--engine auto|jit|interpreter]
///       [--data DIR] [--no-mine] [--no-flexible] [--minutes M]
/// Without --wallet a throwaway test address (fixed test keys) is used.
void main(List<String> args) {
  runZonedGuarded(() => _main(args), (e, st) => stderr.writeln('unexpected: $e\n$st'));
}

Future<void> _main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final wallet = opt('wallet') ?? _testAddress();
  final defaults = NodeConfig.defaults(wallet: wallet, dataDir: opt('data') ?? '${Directory.systemTemp.path}/xmr_dart_node');
  final config = NodeConfig(
    wallet: wallet,
    sidechain: opt('sidechain') ?? 'mini',
    threads: int.tryParse(opt('threads') ?? '') ?? defaults.threads,
    memory: opt('memory') == 'dart' ? RxMemoryKind.dart : (opt('memory') == 'shared' ? RxMemoryKind.shared : defaults.memory),
    fastMode: args.contains('--fast') || (defaults.fastMode && !args.contains('--light')),
    dataDir: defaults.dataDir,
    mine: !args.contains('--no-mine'),
    engine: opt('engine') ?? 'auto',
    flexible: !args.contains('--no-flexible'),
  );
  stdout.writeln('config: ${jsonEncode(config.toJson())}');
  final node = XmrNode(config);
  await node.start();
  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('stopping, saving state');
    await node.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => shutdown());
  final minutes = int.tryParse(opt('minutes') ?? '');
  var shownLog = 0;
  final timer = Timer.periodic(const Duration(seconds: 10), (_) {
    final s = node.status();
    stdout.writeln('[${s.phase}] monero ${s.moneroHeight} (${s.moneroPeers} peers, synced=${s.moneroSynced}) | '
        'p2pool ${s.sideHeight}/${s.sidePeerHeight} (${s.sidePeers} peers, synced=${s.sideSynced}, diff ${s.sideDifficulty}) | '
        '${s.mining ? 'mining ${s.hashrate.toStringAsFixed(1)} H/s' : 'not mining'} | shares ${s.sharesFound} | ${s.engine}');
    final log = s.log;
    for (final l in log.skip(shownLog > log.length ? 0 : shownLog)) {
      stdout.writeln('   $l');
    }
    shownLog = log.length;
  });
  if (minutes != null) {
    await Future<void>.delayed(Duration(minutes: minutes));
    timer.cancel();
    await node.stop();
    exit(0);
  }
}

String _testAddress() {
  final spend = scalarMultBase(scReduce32(Keccak.hash256(utf8.encode('xmr-dart test spend key')))).encode();
  final view = scalarMultBase(scReduce32(Keccak.hash256(utf8.encode('xmr-dart test view key')))).encode();
  return MoneroAddress(MoneroNetwork.mainnet, AddressKind.standard, spend, view).encode();
}
