import 'dart:convert';
import 'dart:io';

import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/clsag.dart';
import 'package:xmr_core/src/wallet/node_rpc.dart';
import 'package:xmr_core/src/wallet/transaction.dart';

/// Live checks against a public node: the CLSAGs of real transactions
/// (test/fixtures/monero_blocks.json) verify with their rings from get_outs,
/// and the full output distribution downloads.
///   dart run tool/wallet_node_probe.dart [NODE_URL]
Future<void> main(List<String> args) async {
  final rpc = MoneroRpc(args.isNotEmpty ? args[0] : MoneroRpc.defaultNodes.first);
  final blocks = (jsonDecode(File('test/fixtures/monero_blocks.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
  var ok = 0, bad = 0;
  for (final t in (blocks.first['txs'] as List).take(8)) {
    final tx = MoneroTx.parse(fromHex(t as String));
    final msg = tx.clsagMessage;
    for (var i = 0; i < tx.inputs.length; i++) {
      final input = tx.inputs[i] as TxInToKey;
      final outs = await rpc.outputs(input.ringIndices);
      final ring = [for (final o in outs) (key: o.key, commitment: o.mask)];
      final good = clsagVerify(msg, tx.clsags![i], ring, input.keyImage, tx.pseudoOuts![i]);
      good ? ok++ : bad++;
    }
  }
  stdout.writeln('real CLSAGs: $ok verified, $bad failed');
  final sw = Stopwatch()..start();
  final d = await OutputDistribution.update(rpc, null);
  stdout.writeln('output distribution: ${d.height} blocks, ${d.cumulative.last} RingCT outputs, ${sw.elapsedMilliseconds} ms');
  final (fees, mask) = await rpc.feeEstimate();
  stdout.writeln('fees per byte $fees, quantization $mask, height ${await rpc.height()}');
  rpc.close();
  exit(bad == 0 && ok > 0 ? 0 : 1);
}
