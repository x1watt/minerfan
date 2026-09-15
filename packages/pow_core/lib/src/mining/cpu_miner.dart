import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../header_pow.dart';
import '../target.dart';
import 'header_miner.dart';

/// Hashes per second of [pow] on one thread of this device (a short timed
/// run). Call off the UI isolate.
double cpuHashrate(HeaderPow Function() pow, {int hashes = 24}) {
  final p = pow();
  final header = Uint8List(80);
  p.hash(header); // warm up
  final sw = Stopwatch()..start();
  for (var i = 0; i < hashes; i++) {
    header[76] = i;
    p.hash(header);
  }
  return hashes * 1e6 / sw.elapsedMicroseconds;
}

/// Mines headers with the Dart hash on CPU threads (one isolate each), for
/// devices without a usable GPU. Each thread searches its own part of the
/// nonce space.
class CpuHeaderMiner implements HeaderMiner {
  /// A new hash function for each worker (it may keep scratch memory).
  final HeaderPow Function() pow;
  final int threads;

  final List<SendPort> _workers = [];
  final List<Isolate> _isolates = [];
  final ReceivePort _inbox = ReceivePort();
  final StreamController<FoundNonce> _found = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final List<(double, double)> _perWorker = []; // (hashrate, full speed)
  int _hashes = 0;
  double _duty = 1;

  CpuHeaderMiner({required this.pow, required this.threads});

  @override
  String get device => 'CPU, $threads thread${threads == 1 ? '' : 's'}';

  @override
  MinerStats get stats => MinerStats(device, _perWorker.fold(0.0, (a, w) => a + w.$1),
      _perWorker.fold(0.0, (a, w) => a + w.$2), _duty, _hashes);

  @override
  Stream<FoundNonce> get found => _found.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start() async {
    if (threads < 1) throw ArgumentError('at least one thread');
    final ready = Completer<void>();
    _inbox.listen((m) {
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'ready':
          _workers.add(msg[1]! as SendPort);
          _perWorker.add((0, 0));
          if (_workers.length == threads && !ready.isCompleted) ready.complete();
        case 'found':
          _found.add(FoundNonce(msg[1]! as int, msg[2]! as int, msg[3]! as Uint8List));
        case 'stats':
          final i = msg[1]! as int;
          if (i < _perWorker.length) _perWorker[i] = (msg[2]! as double, msg[3]! as double);
          _hashes += msg[4]! as int;
      }
    });
    final span = 0x100000000 ~/ threads;
    for (var i = 0; i < threads; i++) {
      _isolates.add(await Isolate.spawn(_worker, [_inbox.sendPort, pow, i, i * span, span], debugName: 'cpu-miner-$i'));
    }
    await ready.future;
  }

  void _all(List<Object?> msg) {
    for (final w in _workers) {
      w.send(msg);
    }
  }

  @override
  void work(MiningWork w) => _all(['work', w.id, w.header, w.target]);

  @override
  void setDuty(double d) {
    _duty = d.clamp(0.0, 1.0);
    _all(['duty', _duty]);
  }

  @override
  void pause() => _all(['pause']);

  @override
  Future<void> stop() async {
    final exits = <Future<Object?>>[];
    for (final iso in _isolates) {
      final p = ReceivePort();
      iso.addOnExitListener(p.sendPort);
      exits.add(p.first.whenComplete(p.close));
    }
    _all(['stop']);
    await Future.wait(exits).timeout(const Duration(seconds: 10), onTimeout: () => const []);
    _workers.clear();
    _isolates.clear();
    _inbox.close();
    await _found.close();
    await _errors.close();
  }
}

Future<void> _worker(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final pow = (args[1]! as HeaderPow Function())();
  final index = args[2]! as int;
  final first = args[3]! as int;
  final span = args[4]! as int;
  final inbox = ReceivePort();
  out.send(['ready', inbox.sendPort]);

  int? workId;
  Uint8List? header;
  var target = BigInt.zero;
  var nonce = first;
  var duty = 1.0;
  var running = true;
  var wake = Completer<void>();
  const batch = 32;
  final window = Stopwatch()..start();
  var windowHashes = 0, busyUs = 0;

  // As in the GPU miner: messages never shorten a rest.
  final stopped = Completer<void>();
  var dutyRaised = Completer<void>();
  inbox.listen((m) {
    final msg = m as List<Object?>;
    switch (msg[0]) {
      case 'work':
        workId = msg[1]! as int;
        header = Uint8List.fromList(msg[2]! as Uint8List);
        target = msg[3]! as BigInt;
        nonce = first;
      case 'duty':
        final d = msg[1]! as double;
        if (d > duty && !dutyRaised.isCompleted) dutyRaised.complete();
        duty = d;
      case 'pause':
        header = null;
      case 'stop':
        running = false;
        if (!stopped.isCompleted) stopped.complete();
        inbox.close();
    }
    if (!wake.isCompleted) wake.complete();
  });

  while (running) {
    final h = header;
    if (h == null || duty <= 0) {
      wake = Completer<void>();
      await wake.future;
      continue;
    }
    final id = workId!;
    final nd = ByteData.sublistView(h);
    final sw = Stopwatch()..start();
    for (var i = 0; i < batch; i++, nonce++) {
      nd.setUint32(76, nonce, Endian.little);
      final hash = pow.hash(h);
      if (CompactTarget.meets(hash, target)) out.send(['found', id, nonce, hash]);
    }
    final us = sw.elapsedMicroseconds;
    if (nonce - first > span - batch) header = null; // our part is used up
    windowHashes += batch;
    busyUs += us;
    if (window.elapsedMilliseconds >= 2000) {
      out.send([
        'stats',
        index,
        windowHashes * 1000 / window.elapsedMilliseconds,
        busyUs > 0 ? windowHashes * 1e6 / busyUs : 0.0,
        windowHashes,
      ]);
      window.reset();
      windowHashes = 0;
      busyUs = 0;
    }
    final restMs = duty >= 1 ? 0 : (us / 1000 * (1 - duty) / duty).round();
    dutyRaised = Completer<void>();
    await Future.any([stopped.future, dutyRaised.future, Future<void>.delayed(Duration(milliseconds: restMs))]);
  }
}
