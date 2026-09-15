import 'dart:async';
import 'dart:io';

import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/account.dart';
import 'package:xmr_core/src/wallet/node_rpc.dart';
import 'package:xmr_core/src/wallet/wallet_service.dart';

/// Runs the Monero wallet service: syncs the light chain over P2P and scans
/// blocks for a wallet.
///   dart run tool/wallet_service_probe.dart DATA_DIR [--seed HEX | --view ADDRESS VIEWKEY] [--from HEIGHT] [--seconds S]
Future<void> main(List<String> args) async {
  String? opt(String n, [int k = 1]) {
    final i = args.indexOf('--$n');
    return i >= 0 && i + k < args.length ? args[i + k] : null;
  }

  final h = await MoneroWalletHandle.spawn(MoneroWalletServiceConfig(dataDir: args[0], node: MoneroRpc.defaultNodes.first));
  h.log.listen((l) {
    if (!l.contains('connected') && !l.contains('closed')) stdout.writeln(l);
  });
  final from = int.tryParse(opt('from') ?? '') ?? 0;
  if (opt('view') != null) {
    await h.openWallet(MoneroWalletKeys.viewOnly('w', opt('view')!, fromHex(opt('view', 2)!), from));
  } else {
    final seed = opt('seed') != null ? fromHex(opt('seed')!) : MoneroAccount.generate().$2;
    await h.openWallet(MoneroWalletKeys.full('w', seed, from));
  }
  final secs = int.tryParse(opt('seconds') ?? '') ?? 120;
  for (var i = 0; i < secs ~/ 10; i++) {
    await Future<void>.delayed(const Duration(seconds: 10));
    final s = h.last;
    if (s == null) continue;
    final w = s.wallets['w'];
    stdout.writeln('status: tip ${s.tip} peers ${s.peers} synced ${s.synced}'
        '${w == null ? '' : ' | scanned ${w.scanned} balance ${w.balance / 1e12} unlocked ${w.unlocked / 1e12} txs ${w.history.length}'}');
  }
  await h.stop();
  exit(0);
}
