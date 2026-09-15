import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:xmr_core/src/levin/levin_peer.dart';
import 'package:xmr_core/src/levin/messages.dart';
import 'package:xmr_core/src/monero/hardforks.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Live check of the levin light peer against a real Monero mainnet node.
///
///   dart run tool/levin_probe.dart [host:port ...] [--blocks N] [--follow SECONDS]
///
/// Connects to the first seed node that answers (src/p2p/net_node.inl
/// get_seed_nodes), handshakes, prints the peer's CORE_SYNC_DATA, requests the
/// chain from the tip, then walks back N blocks from the tip with
/// REQUEST_GET_OBJECTS (prune=true), parsing each with MoneroBlock.parse and
/// checking that MoneroBlock.id() equals the id the peer listed.
const seedNodes = [
  '176.9.0.187:18080',
  '88.198.163.90:18080',
  '192.99.8.110:18080',
  '37.187.74.171:18080',
  '88.99.195.15:18080',
  '5.104.84.64:18080',
];

const timeout = Duration(seconds: 10);

Future<void> main(List<String> args) async {
  var nBlocks = 3;
  var followSeconds = 0;
  final hosts = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--blocks') {
      nBlocks = int.parse(args[++i]);
    } else if (args[i] == '--follow') {
      followSeconds = int.parse(args[++i]);
    } else {
      hosts.add(args[i]);
    }
  }
  if (hosts.isEmpty) hosts.addAll(seedNodes);

  for (final hp in hosts) {
    final idx = hp.lastIndexOf(':');
    final host = hp.substring(0, idx);
    final port = int.parse(hp.substring(idx + 1));
    stdout.writeln('connecting to $host:$port ...');
    _Conn? c;
    try {
      c = await _Conn.open(host, port);
      final ok = await _probe(c, nBlocks, followSeconds);
      c.close();
      if (ok) {
        exitCode = 0;
        return;
      }
      exitCode = 2;
      return;
    } on Object catch (e) {
      stdout.writeln('  failed: $e');
      c?.close();
    }
  }
  stdout.writeln('no node answered');
  exitCode = 1;
}

Future<bool> _probe(_Conn c, int nBlocks, int followSeconds) async {
  final hs = await c.waitFor<HandshakeDone>(timeout);
  final sync = hs.coreSync;
  final tipHeight = sync.currentHeight - 1;
  stdout
    ..writeln(
      'handshake ok: peer_id=${_hex64(hs.nodeData.peerId)} '
      'my_port=${hs.nodeData.myPort} rpc_port=${hs.nodeData.rpcPort} support_flags=${hs.nodeData.supportFlags}',
    )
    ..writeln('  CORE_SYNC_DATA: current_height=${sync.currentHeight} (tip height $tipHeight)')
    ..writeln(
      '  top_id=${toHex(sync.topId)} top_version=${sync.topVersion} '
      '(expected ${majorVersionAt(tipHeight)}) pruning_seed=0x${sync.pruningSeed.toRadixString(16)}',
    )
    ..writeln('  cumulative_difficulty=${sync.cumulativeDifficulty}')
    ..writeln(
      '  peer list: ${hs.peers.length} entries'
      '${hs.peers.isEmpty ? '' : ', e.g. ${hs.peers.take(3).join(', ')}'}'
      ' (ipv6: ${hs.peers.where((p) => p.isIpv6).length})',
    );

  // Chain from the tip: the peer returns ids starting at the newest id of
  // ours it knows.
  c.peer.requestChain([sync.topId, mainnetGenesisId]);
  c.flush();
  final ce = (await c.waitFor<ChainEntry>(timeout)).entry;
  stdout.writeln(
    'chain entry from tip: start_height=${ce.startHeight} total_height=${ce.totalHeight} '
    'ids=${ce.blockIds.length} weights=${ce.blockWeights.length} first_block=${ce.firstBlock?.length ?? 0} bytes '
    'cumdiff=${ce.cumulativeDifficulty}',
  );
  if (ce.blockIds.isNotEmpty) {
    stdout.writeln('  ids[0]=${toHex(ce.blockIds[0])} matches top_id: ${bytesEqual(ce.blockIds[0], sync.topId)}');
  }

  // Chain from genesis: the first 10000 ids.
  c.peer.requestChain([mainnetGenesisId]);
  c.flush();
  final g = (await c.waitFor<ChainEntry>(timeout)).entry;
  stdout.writeln(
    'chain entry from genesis: start_height=${g.startHeight} ids=${g.blockIds.length} '
    'ids[0]=genesis: ${g.blockIds.isNotEmpty && bytesEqual(g.blockIds[0], mainnetGenesisId)}',
  );

  // Walk back from the tip one block at a time, following prev_id.
  var allOk = true;
  var want = sync.topId;
  var wantHeight = tipHeight;
  final walked = <Uint8List>[];
  for (var i = 0; i < nBlocks; i++) {
    c.peer.requestObjects([want]);
    c.flush();
    final r = await c.waitFor<ObjectsResponse>(timeout);
    if (r.blocks.isEmpty) {
      stdout.writeln('  no block returned for ${toHex(want)} (missed ${r.response.missedIds.length})');
      return false;
    }
    final rb = r.blocks.first;
    final ok = _report(rb, want, wantHeight);
    allOk &= ok;
    if (rb.block == null) return false;
    walked.add(want);
    want = rb.block!.header.prevId;
    wantHeight--;
  }

  // Same blocks again in one request.
  c.peer.requestObjects(walked);
  c.flush();
  final multi = await c.waitFor<ObjectsResponse>(timeout);
  var multiOk = multi.blocks.length == walked.length;
  for (var i = 0; i < multi.blocks.length && i < walked.length; i++) {
    final b = multi.blocks[i].block;
    multiOk &= b != null && bytesEqual(b.id(), walked[i]);
  }
  stdout.writeln(
    'batch request of ${walked.length} ids: ${multi.blocks.length} blocks, all ids match: $multiOk, '
    'peer height ${multi.response.currentBlockchainHeight}',
  );
  allOk &= multiOk;

  if (followSeconds > 0) {
    stdout.writeln('following for $followSeconds s ...');
    final end = DateTime.now().add(Duration(seconds: followSeconds));
    while (DateTime.now().isBefore(end)) {
      final left = end.difference(DateTime.now());
      final ev = await c.poll<LevinEvent>(left);
      if (ev == null) break;
      if (ev is LevinClosed) {
        stdout.writeln('  closed: ${ev.reason}');
        allOk = false;
        break;
      }
      switch (ev) {
        case NewBlock(:final block, :final currentBlockchainHeight):
          final b = block.block;
          stdout.writeln(
            '  NEW_${ev.fluffy ? 'FLUFFY_' : ''}BLOCK height=${b?.height} id=${b == null ? '?' : toHex(b.id())} '
            'txs=${block.entry.txs.length} peer_height=$currentBlockchainHeight',
          );
          if (b != null) allOk &= bytesEqual(b.serialize(), block.blob);
        case CoreSyncUpdate(:final coreSync):
          stdout.writeln('  timed sync: height=${coreSync.currentHeight} top=${toHex(coreSync.topId)}');
        case NewTransactions(:final txs):
          stdout.writeln('  NEW_TRANSACTIONS: ${txs.length} txs');
        case LevinWarning(:final message):
          stdout.writeln('  warning: $message');
        case UnhandledNotify(:final command):
          stdout.writeln('  unhandled notify $command');
        default:
          stdout.writeln('  event ${ev.runtimeType}');
      }
    }
    stdout.writeln('connection still open: ${!c.peer.isClosed}');
  }

  stdout.writeln(allOk ? 'RESULT: all block ids match' : 'RESULT: MISMATCH');
  return allOk;
}

String _hex64(int v) =>
    (v >>> 32).toRadixString(16).padLeft(8, '0') + (v & 0xffffffff).toRadixString(16).padLeft(8, '0');

bool _report(ReceivedBlock rb, Uint8List wantId, int wantHeight) {
  final b = rb.block;
  if (b == null) {
    stdout.writeln('  block ${toHex(wantId)}: parse failed: ${rb.parseError}');
    return false;
  }
  final id = b.id();
  final idOk = bytesEqual(id, wantId);
  final reser = bytesEqual(b.serialize(), rb.blob);
  final hOk = b.height == wantHeight;
  stdout.writeln(
    '  height=${b.height}${hOk ? '' : ' (expected $wantHeight)'} v${b.header.majorVersion}.${b.header.minorVersion} '
    'txs=${b.txHashes.length} weight=${rb.entry.blockWeight} blob=${rb.blob.length}B',
  );
  stdout.writeln('    id computed=${toHex(id)}');
  stdout.writeln('    id listed  =${toHex(wantId)}  match=$idOk  reserialize_identical=$reser');
  return idOk && reser && hOk;
}

/// dart:io glue around the sans-IO peer.
class _Conn {
  final Socket socket;
  final LevinPeer peer = LevinPeer();
  final List<LevinEvent> _backlog = [];
  Completer<void>? _signal;
  late final StreamSubscription<Uint8List> _sub;
  late final Timer _ticker;
  final Stopwatch _clock = Stopwatch()..start();

  _Conn(this.socket);

  static Future<_Conn> open(String host, int port) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    final c = _Conn(s);
    c._sub = s.listen(
      (data) => c._push(c.peer.receive(data, c._clock.elapsedMilliseconds)),
      onError: (Object e) => c._push([LevinClosed('socket error: $e')]),
      onDone: () => c._push([const LevinClosed('socket closed by peer')]),
    );
    c._ticker = Timer.periodic(const Duration(seconds: 1), (_) => c._push(c.peer.tick(c._clock.elapsedMilliseconds)));
    s.add(c.peer.startHandshake(c._clock.elapsedMilliseconds));
    return c;
  }

  void _push(List<LevinEvent> events) {
    flush();
    if (events.isEmpty) return;
    _backlog.addAll(events);
    _signal?.complete();
    _signal = null;
  }

  void flush() {
    if (peer.hasOutgoing) socket.add(peer.takeOutgoing());
  }

  Future<T> waitFor<T extends LevinEvent>(Duration limit) async =>
      (await poll<T>(limit)) ?? (throw TimeoutException('waiting for $T'));

  /// Next event of type [T], or null after [limit].
  Future<T?> poll<T extends LevinEvent>(Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (true) {
      for (var i = 0; i < _backlog.length; i++) {
        final e = _backlog[i];
        if (e is T) {
          _backlog.removeAt(i);
          return e;
        }
        if (e is LevinClosed) throw StateError('closed: ${e.reason}');
      }
      // Drop events nobody waits for (e.g. new transactions) to bound memory.
      if (T != LevinEvent) _backlog.removeWhere((e) => e is NewTransactions || e is LevinWarning);
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      _signal ??= Completer<void>();
      await _signal!.future.timeout(left, onTimeout: () {});
    }
  }

  void close() {
    _ticker.cancel();
    unawaited(_sub.cancel());
    socket.destroy();
  }
}
