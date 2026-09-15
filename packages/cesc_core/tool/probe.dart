import 'package:cesc_core/cesc_core.dart';
import 'package:net_core/net_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:utxo_core/utxo_core.dart';

/// Live check: handshake with a Cryptoescudo node and fetch headers after a
/// known block. Usage: `dart run tool/probe.dart BLOCK_HASH [HOST:PORT]`
Future<void> main(List<String> args) async {
  final p = Cryptoescudo.params;
  final t = IoTransport();
  final hosts = args.length > 1 ? [args[1]] : [...p.fixedPeers];
  for (final seed in p.dnsSeeds.take(3)) {
    final ips = await t.resolve(seed);
    print('$seed -> $ips');
  }
  for (final h in hosts) {
    final (host, port) = splitHostPort(h, p.port);
    try {
      final peer = await Peer.connect(t, p, host, port, startHeight: 0);
      print('connected: $peer version ${peer.version} services ${peer.services}');
      final reply = await peer.request('getheaders', Msg.getHeaders(p.protocolVersion, [hashFromHex(args[0])]),
          (m) => m.command == 'headers');
      final headers = Msg.parseHeaders(reply.payload);
      print('headers: ${headers.length}');
      final pow = p.pow();
      var prev = hashFromHex(args[0]);
      var ok = 0;
      for (final hd in headers) {
        if (!bytesEqual(hd.prevHash, prev)) throw StateError('chain break at ${hd.id}');
        final target = CompactTarget.decode(hd.bits);
        if (!CompactTarget.meets(pow.hash(hd.serialize()), target)) throw StateError('bad pow ${hd.id}');
        prev = hd.hash;
        ok++;
      }
      print('linked and PoW-valid: $ok; first ${headers.first.id} last ${headers.last.id} bits ${headers.last.bits.toRadixString(16)}');
      await peer.close();
      return;
    } catch (e) {
      print('$h: $e');
    }
  }
}
