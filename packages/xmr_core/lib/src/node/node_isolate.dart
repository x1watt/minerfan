import 'dart:async';
import 'dart:isolate';

import 'node.dart';

/// Runs an [XmrNode] in its own isolate so the UI isolate never does node or
/// crypto work. The UI talks to it through [NodeHandle].
class NodeHandle {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _inbox;
  final StreamController<NodeStatus> _status = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final Completer<void> _stopped = Completer();

  NodeHandle._(this._isolate, this._commands, this._inbox);

  Stream<NodeStatus> get status => _status.stream;
  Stream<String> get errors => _errors.stream;

  /// Spawns the node isolate and starts the node with [config].
  static Future<NodeHandle> spawn(NodeConfig config) async {
    final inbox = ReceivePort();
    final iso = await Isolate.spawn(_main, [inbox.sendPort, config.toJson()], debugName: 'xmr-node');
    final broadcast = inbox.asBroadcastStream();
    final first = await broadcast.first;
    final ports = first as List<Object?>;
    final handle = NodeHandle._(iso, ports[1]! as SendPort, inbox);
    broadcast.listen((m) {
      final msg = m! as List<Object?>;
      switch (msg[0]) {
        case 'status':
          handle._status.add(NodeStatus.fromJson((msg[1]! as Map).cast<String, Object?>()));
        case 'error':
          handle._errors.add(msg[1]! as String);
        case 'stopped':
          if (!handle._stopped.isCompleted) handle._stopped.complete();
      }
    });
    return handle;
  }

  void setMining(bool on) => _commands.send(['mine', on]);

  /// Mining threads to use now (at most the configured count); thermal
  /// control lowers and raises it while the node runs.
  void setActiveThreads(int n) => _commands.send(['threads', n]);

  /// Stops mining and the node, letting it save its state first.
  Future<void> stop() async {
    _commands.send(['stop']);
    await _stopped.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    _isolate.kill(priority: Isolate.immediate);
    _inbox.close();
    await _status.close();
    await _errors.close();
  }
}

/// Errors nobody awaited (a socket failing mid-write, say) are reported
/// instead of ending the node.
void _main(List<Object?> args) {
  final out = args[0]! as SendPort;
  runZonedGuarded(() => _run(out, args), (e, st) => out.send(['error', 'unexpected: $e']));
}

Future<void> _run(SendPort out, List<Object?> args) async {
  final commands = ReceivePort();
  out.send(['ready', commands.sendPort]);
  final config = NodeConfig.fromJson((args[1]! as Map).cast<String, Object?>());
  final node = XmrNode(config);
  try {
    await node.start();
  } catch (e) {
    out.send(['error', '$e']);
    return;
  }
  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    try {
      out.send(['status', node.status().toJson()]);
    } catch (e) {
      out.send(['error', 'status: $e']);
    }
  });
  await for (final m in commands) {
    final msg = m! as List<Object?>;
    switch (msg[0]) {
      case 'mine':
        node.setMining(msg[1]! as bool);
      case 'threads':
        node.setActiveThreads(msg[1]! as int);
      case 'stop':
        timer.cancel();
        await node.stop();
        out.send(['stopped']);
        commands.close();
    }
  }
}
