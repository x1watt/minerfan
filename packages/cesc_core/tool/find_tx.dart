import 'dart:io';

import 'package:cesc_core/cesc_core.dart';
import 'package:net_core/net_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Prints the first non-coinbase transaction (raw hex) found in the blocks
/// after the checkpoint, for test fixtures.
Future<void> main() async {
  final p = Cryptoescudo.params;
  final (host, port) = splitHostPort(p.fixedPeers.first, p.port);
  final peer = await Peer.connect(IoTransport(), p, host, port, startHeight: 0);
  final cp = cryptoescudoCheckpoint();
  final reply = await peer.request('getheaders', Msg.getHeaders(p.protocolVersion, [cp.hash]), (m) => m.command == 'headers');
  final headers = Msg.parseHeaders(reply.payload);
  for (var i = 0; i < headers.length; i += 50) {
    final batch = headers.skip(i).take(50).toList();
    final blocks = peer.messages.where((m) => m.command == 'block').take(batch.length).toList();
    peer.send('getdata', Msg.inv([for (final h in batch) InvItem(InvType.block, h.hash)]));
    for (final m in await blocks.timeout(const Duration(seconds: 60))) {
      final b = Block.read(ByteReader(m.payload));
      for (final t in b.transactions.where((t) => !t.isCoinbase)) {
        stdout.writeln('${t.id} ${toHex(t.serialize())}');
        await peer.close();
        exit(0);
      }
    }
  }
  stderr.writeln('none found');
  await peer.close();
}
