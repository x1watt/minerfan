import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xmr_core/src/levin/levin_peer.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Saves recent mainnet blocks with their transactions, full and pruned, as
/// test fixtures (test/fixtures/monero_blocks.json).
///   dart run tool/fetch_tx_fixtures.dart [--blocks N]
const seedNodes = ['176.9.0.187:18080', '88.198.163.90:18080', '192.99.8.110:18080', '37.187.74.171:18080'];
const timeout = Duration(seconds: 20);

Future<void> main(List<String> args) async {
  final n = args.contains('--blocks') ? int.parse(args[args.indexOf('--blocks') + 1]) : 3;
  for (final hp in seedNodes) {
    final i = hp.lastIndexOf(':');
    _Conn? c;
    try {
      c = await _Conn.open(hp.substring(0, i), int.parse(hp.substring(i + 1)));
      final hs = await c.waitFor<HandshakeDone>(timeout);
      var want = hs.coreSync.topId;
      final out = <Map<String, Object?>>[];
      for (var k = 0; k < n; k++) {
        c.peer.requestObjects([want], prune: false);
        c.flush();
        final full = (await c.waitFor<ObjectsResponse>(timeout)).blocks.first;
        c.peer.requestObjects([want], prune: true);
        c.flush();
        final pruned = (await c.waitFor<ObjectsResponse>(timeout)).blocks.first;
        final b = full.block!;
        out.add({
          'height': b.height,
          'id': toHex(want),
          'block': toHex(full.blob),
          'txHashes': [for (final h in b.txHashes) toHex(h)],
          'txs': [for (final t in full.entry.txs) toHex(t.blob)],
          'pruned': [for (final t in pruned.entry.txs) {'blob': toHex(t.blob), 'prunableHash': toHex(t.prunableHash ?? Uint8List(32))}],
        });
        stdout.writeln('block ${b.height}: ${b.txHashes.length} txs, full ${full.entry.txs.length}, pruned ${pruned.entry.txs.length}');
        want = b.header.prevId;
      }
      File('test/fixtures/monero_blocks.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
      c.close();
      exit(0);
    } on Object catch (e) {
      stdout.writeln('$hp failed: $e');
      c?.close();
    }
  }
  exit(1);
}

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
