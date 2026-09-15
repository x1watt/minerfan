import 'dart:math' show max;
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:gpu_core/gpu_core.dart';

import '../gpu/scrypt_gpu.dart';
import '../header_pow.dart';
import '../target.dart';
import 'header_miner.dart';

/// The OpenCL devices of this machine (empty without OpenCL). Loads the
/// driver, so call it off the UI isolate.
List<String> gpuDeviceNames() {
  try {
    return [for (final d in OpenCl.devices()) d.name];
  } catch (_) {
    return const [];
  }
}

/// One GPU after its self-test: whether its scrypt matches the Dart one,
/// and its speed at full duty.
class GpuCheck {
  final String name;
  final bool ok;
  final double hashrate;
  final String? error;
  const GpuCheck(this.name, this.ok, this.hashrate, [this.error]);

  @override
  String toString() => ok ? '$name: ${(hashrate / 1000).toStringAsFixed(1)} kH/s' : '$name: failed (${error ?? 'wrong hashes'})';
}

/// Runs the scrypt kernel on every OpenCL device: 32 hashes must equal the
/// Dart scrypt, then one timed batch gives the speed. Loads the driver and
/// takes a few seconds, so call it off the UI isolate.
List<GpuCheck> gpuSelfTest() {
  List<GpuDevice> devices;
  try {
    devices = OpenCl.devices();
  } catch (e) {
    return [GpuCheck('OpenCL', false, 0, '$e')];
  }
  if (devices.isEmpty) {
    String why;
    try {
      why = OpenCl.diagnose();
    } catch (e) {
      why = '$e';
    }
    return [GpuCheck('OpenCL', false, 0, why)];
  }
  final out = <GpuCheck>[];
  final cpu = ScryptPow();
  for (final d in devices) {
    ScryptGpu? gpu;
    try {
      gpu = ScryptGpu(d);
      final header = Uint8List.fromList(List.generate(80, (i) => (i * 37 + 11) & 0xff));
      final got = gpu.hashes(header, 1000, 32);
      var ok = true;
      for (var i = 0; i < 32 && ok; i++) {
        final h = Uint8List.fromList(header);
        ByteData.sublistView(h).setUint32(76, 1000 + i, Endian.little);
        final want = cpu.hash(h);
        for (var k = 0; k < 32; k++) {
          if (want[k] != got[i][k]) {
            ok = false;
            break;
          }
        }
      }
      final sw = Stopwatch()..start();
      gpu.search(header, BigInt.zero, 0);
      final ms = max(1, sw.elapsedMilliseconds);
      out.add(GpuCheck(d.name, ok, gpu.batch * 1000 / ms));
    } catch (e) {
      out.add(GpuCheck(d.name, false, 0, '$e'));
    } finally {
      gpu?.dispose();
    }
  }
  return out;
}

/// Mines scrypt headers on one GPU in its own isolate. Found nonces are
/// verified with the Dart scrypt before they are reported, so a faulty
/// kernel or driver can only cost time, never produce a bad block.
class GpuScryptMiner implements HeaderMiner {
  final int deviceIndex;
  final int? batch;
  late final SendPort _commands;
  late final Isolate _isolate;
  final ReceivePort _inbox = ReceivePort();
  final StreamController<FoundNonce> _found = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final Completer<void> _ready = Completer();
  @override
  MinerStats stats = const MinerStats('', 0, 0, 1, 0);
  @override
  String device = '';
  bool _started = false;

  GpuScryptMiner({this.deviceIndex = 0, this.batch});

  @override
  Stream<FoundNonce> get found => _found.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start() async {
    _inbox.listen((m) {
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'ready':
          _commands = msg[1]! as SendPort;
          device = msg[2]! as String;
          if (!_ready.isCompleted) _ready.complete();
        case 'found':
          _found.add(FoundNonce(msg[1]! as int, msg[2]! as int, msg[3]! as Uint8List));
        case 'stats':
          stats = MinerStats(device, msg[1]! as double, msg[2]! as double, msg[3]! as double, msg[4]! as int);
        case 'error':
          _errors.add(msg[1]! as String);
          if (!_ready.isCompleted) _ready.completeError(StateError(msg[1]! as String));
      }
    });
    _isolate = await Isolate.spawn(_main, [_inbox.sendPort, deviceIndex, batch], debugName: 'gpu-miner');
    await _ready.future;
    _started = true;
  }

  @override
  void work(MiningWork w) => _commands.send(['work', w.id, w.header, w.target]);

  @override
  void setDuty(double d) => _commands.send(['duty', d]);

  @override
  void pause() => _commands.send(['pause']);

  @override
  Future<void> stop() async {
    if (!_started) {
      _inbox.close();
      return;
    }
    _started = false;
    final done = ReceivePort();
    _isolate.addOnExitListener(done.sendPort);
    _commands.send(['stop']);
    await done.first.timeout(const Duration(seconds: 10), onTimeout: () => null);
    done.close();
    _inbox.close();
    await _found.close();
    await _errors.close();
  }
}

Future<void> _main(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final inbox = ReceivePort();
  ScryptGpu gpu;
  try {
    final devices = OpenCl.devices();
    gpu = ScryptGpu(devices[args[1]! as int], batch: args[2] as int?);
  } catch (e) {
    out.send(['error', 'GPU unavailable: $e']);
    return;
  }
  out.send(['ready', inbox.sendPort, gpu.device.name]);
  final cpu = ScryptPow();
  int? workId;
  Uint8List? header;
  BigInt target = BigInt.zero;
  var nonce = 0;
  var duty = 1.0;
  var running = true;
  var wake = Completer<void>();
  var hashes = 0;
  final window = Stopwatch()..start();
  var windowHashes = 0, busyMs = 0;

  // Messages never shorten a rest (new work waits for the next batch), or
  // frequent new tips would keep the GPU at full speed whatever the duty;
  // only stopping, or a higher duty, ends it early.
  final stopped = Completer<void>();
  var dutyRaised = Completer<void>();
  inbox.listen((m) {
    final msg = m as List<Object?>;
    switch (msg[0]) {
      case 'work':
        workId = msg[1]! as int;
        header = Uint8List.fromList(msg[2]! as Uint8List);
        target = msg[3]! as BigInt;
        nonce = 0;
      case 'duty':
        final d = (msg[1]! as double).clamp(0.0, 1.0);
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
    final sw = Stopwatch()..start();
    final hits = gpu.search(h, target, nonce);
    final ms = sw.elapsedMilliseconds;
    for (final n in hits) {
      final hd = Uint8List.fromList(h);
      ByteData.sublistView(hd).setUint32(76, n, Endian.little);
      final pow = cpu.hash(hd);
      if (CompactTarget.meets(pow, target)) {
        out.send(['found', id, n, pow]);
      } else {
        out.send(['error', 'GPU result for nonce $n failed the CPU check']);
      }
    }
    nonce += gpu.batch;
    if (nonce > 0xffffffff - gpu.batch) {
      // Nonce space used up: wait for new work (new time or extra nonce).
      header = null;
    }
    hashes += gpu.batch;
    windowHashes += gpu.batch;
    busyMs += ms;
    if (window.elapsedMilliseconds >= 2000) {
      final el = window.elapsedMilliseconds;
      out.send(['stats', windowHashes * 1000 / el, busyMs > 0 ? windowHashes * 1000 / busyMs : 0.0, duty, hashes]);
      window.reset();
      windowHashes = 0;
      busyMs = 0;
    }
    // Duty cycle: rest so that busy time is `duty` of the total.
    final rest = duty >= 1 ? 0 : (max(ms, 1) * (1 - duty) / duty).round();
    if (rest > 0) {
      dutyRaised = Completer<void>();
      await Future.any([stopped.future, dutyRaised.future, Future<void>.delayed(Duration(milliseconds: rest))]);
    } else {
      await Future<void>.delayed(Duration.zero);
    }
  }
  gpu.dispose();
}
