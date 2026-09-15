import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:xmr_core/src/p2pool/consensus.dart';
import 'package:xmr_core/src/p2pool/p2p_peer.dart';
import 'package:xmr_core/src/p2pool/pool_block.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Live check against real P2Pool peers: handshake, tip request, and a walk
/// down a few parents, verifying template ids and parent links.
///   dart run tool/p2pool_probe.dart [nano|mini|main] [blocks]
Future<void> main(List<String> args) async {
  final consensus = P2PoolConsensus.byName(args.isNotEmpty ? args[0] : 'nano');
  final want = args.length > 1 ? int.parse(args[1]) : 5;
  final addrs = <InternetAddress>[];
  for (final seed in consensus.seedNodes) {
    try {
      addrs.addAll(await InternetAddress.lookup(seed, type: InternetAddressType.IPv4));
    } catch (e) {
      stdout.writeln('lookup $seed failed: $e');
    }
  }
  addrs.shuffle();
  stdout.writeln('${consensus.name}: ${addrs.length} seed addresses');
  for (final a in addrs.take(6)) {
    if (await _probe(a, consensus, want)) exit(0);
  }
  exit(1);
}

Future<bool> _probe(InternetAddress addr, P2PoolConsensus consensus, int want) async {
  stdout.writeln('connecting to ${addr.address}:${consensus.defaultPort}');
  Socket sock;
  try {
    sock = await Socket.connect(addr, consensus.defaultPort, timeout: const Duration(seconds: 8));
  } catch (e) {
    stdout.writeln('  connect failed: $e');
    return false;
  }
  final rng = Random.secure();
  final peer = P2PoolPeer(consensus, rng.nextInt(1 << 32) << 16 | rng.nextInt(1 << 16) | 1);
  final done = Completer<bool>();
  var got = 0;
  Uint8List? expectedNext;

  void flush() {
    if (peer.hasOutgoing) sock.add(peer.takeOutgoing());
  }

  peer.start(DateTime.now().millisecondsSinceEpoch);
  flush();
  final timer = Timer(const Duration(seconds: 40), () {
    if (!done.isCompleted) done.complete(false);
  });
  sock.listen((data) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in peer.receive(Uint8List.fromList(data), now)) {
      switch (e) {
        case PeerHandshakeDone(:final peerId):
          stdout.writeln('  handshake ok, peer id $peerId');
        case PeerVersion(:final protocol, :final softwareVersion, :final softwareId):
          stdout.writeln('  version: protocol ${protocol >> 16}.${protocol & 0xffff}, software '
              '${softwareId.toRadixString(16)} ${softwareVersion >> 16}.${(softwareVersion >> 8) & 0xff}.${softwareVersion & 0xff}');
        case PeerAddresses(:final peers):
          stdout.writeln('  peer list: ${peers.length} entries, e.g. ${peers.take(3).toList()}');
        case PeerBlock(:final data, :final requestedId, :final broadcast):
          if (broadcast) {
            stdout.writeln('  (broadcast of ${data.length} bytes)');
            break;
          }
          try {
            final b = PoolBlock.parse(data, consensus);
            final id = b.templateId(consensus);
            final okId = requestedId == null || isZeroHash(requestedId) || bytesEqual(id, requestedId);
            final okLink = expectedNext == null || bytesEqual(id, expectedNext!);
            stdout.writeln('  share side height ${b.side.height}, Monero height ${b.main.genHeight}, '
                'outputs ${b.main.outputs.length}, diff ${b.side.difficulty}, id ${toHex(id).substring(0, 16)} '
                'idMatch=$okId linkMatch=$okLink v=${b.shareVersion.name}');
            got++;
            expectedNext = b.side.parent;
            if (got >= want) {
              done.complete(okId && okLink);
            } else {
              peer.requestBlock(b.side.parent);
            }
          } catch (err) {
            stdout.writeln('  parse error: $err');
            done.complete(false);
          }
        case PeerBlockMissing(:final requestedId):
          stdout.writeln('  peer lacks ${toHex(requestedId).substring(0, 16)}');
        case PeerBlockRequested():
          peer.sendBlockResponse(null);
        case PeerListRequested():
          peer.sendPeerList(const []);
        case PeerBlockNotify():
          break;
        case PeerFailure(:final reason):
          stdout.writeln('  failure: $reason');
          if (!done.isCompleted) done.complete(false);
      }
    }
    flush();
  }, onError: (Object e) {
    if (!done.isCompleted) done.complete(false);
  }, onDone: () {
    stdout.writeln('  connection closed');
    if (!done.isCompleted) done.complete(false);
  });
  final ok = await done.future;
  timer.cancel();
  sock.destroy();
  return ok;
}
