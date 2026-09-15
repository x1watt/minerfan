import 'dart:io';

import 'package:cesc_core/cesc_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Prints block times and difficulty from a saved header chain.
///   dart run tool/chain_times.dart HEADERS_BIN FROM [TO]
void main(List<String> args) {
  final chain = HeaderChain.restore(Cryptoescudo.params, cryptoescudoCheckpoint(), File(args[0]).readAsBytesSync())!;
  final from = int.parse(args[1]);
  final to = args.length > 2 ? int.parse(args[2]) : chain.tipHeight;
  for (var h = from; h <= to; h++) {
    final dt = chain.timeAt(h) - chain.timeAt(h - 1);
    final net = CompactTarget.hashrate(chain.bitsAt(h), 120);
    stdout.writeln('$h +${dt}s diff ${CompactTarget.difficulty(chain.bitsAt(h)).toStringAsFixed(5)} implied ${(net / 1000).toStringAsFixed(1)} kH/s');
  }
}
