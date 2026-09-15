import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:xmr_core/src/levin/levin_peer.dart';
import 'package:xmr_core/src/monero/difficulty.dart';
import 'package:xmr_core/src/monero/light_chain.dart';
import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/vm.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Live check of the light chain: sync from the checkpoint to a real peer's
/// tip, then compare our computed cumulative difficulty with the peer's and
/// verify the tip's RandomX PoW.
const _seeds = ['192.99.8.110', '37.187.74.171', '5.104.84.64', '88.99.195.15', '176.9.0.187', '88.198.163.90'];

Future<void> main() async {
  for (final host in _seeds) {
    if (await _run(host)) exit(0);
  }
  exit(1);
}

Future<bool> _run(String host) async {
  stdout.writeln('connecting to $host:18080');
  Socket sock;
  try {
    sock = await Socket.connect(host, 18080, timeout: const Duration(seconds: 8));
  } catch (e) {
    stdout.writeln('  $e');
    return false;
  }
  final chain = MoneroLightChain.fromCheckpoint();
  final peer = LevinPeer();
  final done = Completer<bool>();
  final sw = Stopwatch()..start();
  var fetching = false;

  void flush() {
    if (peer.hasOutgoing) sock.add(peer.takeOutgoing());
  }

  void requestMore() {
    final ids = chain.nextFetch();
    if (ids.isEmpty) {
      fetching = false;
      if (chain.tipHeight < chain.bestKnownHeight) {
        peer.requestChain(chain.sparseIds());
      }
      return;
    }
    fetching = true;
    peer.requestObjects(ids);
  }

  Future<void> finish() async {
    final tip = chain.tipHeader;
    final sync = peer.remoteSync!;
    stdout.writeln('  synced to ${chain.tipHeight} in ${sw.elapsedMilliseconds} ms');
    stdout.writeln('  our cumulative difficulty ${tip.cumulativeDifficulty}');
    stdout.writeln('  peer top ${sync.currentHeight - 1} cd ${sync.cumulativeDifficulty}');
    final agree = chain.crossCheck(1, sync);
    stdout.writeln('  cross-check: ${agree == null ? 'different tips' : agree ? 'AGREE' : 'DISAGREE'}');
    final checks = chain.takePowChecks();
    stdout.writeln('  ${checks.length} PoW checks queued; verifying the newest');
    final c = checks.last;
    final vm = RandomXVM.light(RandomXCache.create(c.seedId));
    final pow = vm.hash(c.hashingBlob);
    final ok = checkPow(pow, c.difficulty);
    stdout.writeln('  PoW of ${c.height}: ${toHex(pow).substring(0, 16)}... meets ${c.difficulty}: $ok');
    if (!done.isCompleted) done.complete(agree == true && ok);
  }

  sock.add(peer.startHandshake(DateTime.now().millisecondsSinceEpoch));
  sock.listen((data) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in peer.receive(Uint8List.fromList(data), now)) {
      switch (e) {
        case HandshakeDone(:final coreSync):
          stdout.writeln('  handshake: peer tip ${coreSync.currentHeight - 1}');
          chain.noteRemoteTip(coreSync);
          peer.requestChain(chain.sparseIds());
        case CoreSyncUpdate(:final coreSync):
          chain.noteRemoteTip(coreSync);
        case ChainEntry(:final entry):
          if (!chain.onChainEntry(entry)) stdout.writeln('  chain entry does not connect');
          stdout.writeln('  chain entry from ${entry.startHeight}: ${entry.blockIds.length} ids, '
              '${chain.pendingFetches} to fetch');
          if (!fetching) requestMore();
        case ObjectsResponse(:final blocks):
          for (final rb in blocks) {
            if (rb.block == null) continue;
            try {
              chain.addBlock(rb.block!);
            } catch (err) {
              stdout.writeln('  add failed: $err');
              done.complete(false);
              return;
            }
          }
          if (chain.tipHeight % 500 < 100) stdout.writeln('  at ${chain.tipHeight}');
          if (chain.pendingFetches == 0 && chain.tipHeight >= chain.bestKnownHeight) {
            unawaited(finish());
          } else {
            requestMore();
          }
        case NewBlock(:final block):
          if (block.block != null) {
            try {
              chain.addBlock(block.block!);
            } catch (_) {}
          }
        case LevinClosed(:final reason):
          stdout.writeln('  closed: $reason');
          if (!done.isCompleted) done.complete(false);
        default:
          break;
      }
    }
    flush();
  }, onDone: () {
    if (!done.isCompleted) done.complete(false);
  });
  final t = Timer.periodic(const Duration(seconds: 5), (_) {
    peer.tick(DateTime.now().millisecondsSinceEpoch);
    flush();
  });
  final ok = await done.future.timeout(const Duration(minutes: 5), onTimeout: () => false);
  t.cancel();
  sock.destroy();
  return ok;
}
