import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/jit/vm_jit.dart';
import 'package:xmr_core/src/randomx/memory.dart';
import 'package:xmr_core/src/randomx/vm.dart';

/// RandomX benchmark.
///   dart run tool/bench.dart [light|fast|vmonly] [dart|shared] [hashes] [v2] [jit] [softaes] [threads=N]
/// `jit` uses the JIT VM (shared memory). With threads=N, N isolates hash
/// concurrently and the total rate is reported.
Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args[0] : 'light';
  final jit = args.contains('jit');
  final kind = (jit || (args.length > 1 && args[1] == 'shared')) ? RxMemoryKind.shared : RxMemoryKind.dart;
  final n = args.length > 2 ? int.tryParse(args[2]) ?? 5 : 5;
  final v2 = args.contains('v2');
  final softAes = args.contains('softaes');
  final threads = int.tryParse(args.firstWhere((a) => a.startsWith('threads='), orElse: () => 'threads=1').substring(8)) ?? 1;

  var sw = Stopwatch()..start();
  final cache = RandomXCache.create(utf8.encode('bench key'), kind: kind);
  stdout.writeln('cache: ${sw.elapsedMilliseconds} ms');

  RandomXDataset? ds;
  if (mode == 'vmonly') {
    // Dataset allocated but not initialised: times the VM without SSH work.
    ds = RandomXDataset.allocate(RxMemoryKind.shared);
  } else if (mode == 'fast') {
    sw = Stopwatch()..start();
    ds = RandomXDataset.allocate(kind);
    if (jit) {
      final init = JitDatasetInit.build(cache);
      const items = 34078719;
      final lanes = Platform.numberOfProcessors;
      final per = (items + lanes - 1) ~/ lanes;
      final addr = init.initAddress, slot = init.cacheSlot, dsAddr = ds.buffer.address;
      await Future.wait([
        for (var l = 0; l < lanes; l++)
          Isolate.run(() => JitDatasetInit.initRange(
              addr, slot, dsAddr, l * per, (l + 1) * per > items ? items : (l + 1) * per)),
      ]);
    } else {
      ds.init(cache, 0, 34078719);
    }
    stdout.writeln('dataset: ${sw.elapsedMilliseconds} ms');
  }

  final label = '$mode ${kind.name}${v2 ? ' v2' : ''}${jit ? ' jit' : ''}${softAes ? ' softaes' : ''}';
  if (threads > 1) {
    final cacheAddr = cache.buffer.address, key = cache.key, dsAddr = ds?.buffer.address;
    sw = Stopwatch()..start();
    await Future.wait([
      for (var t = 0; t < threads; t++)
        Isolate.run(() {
          final c = RandomXCache.attach(key, cacheAddr);
          final vm = jit
              ? (dsAddr != null ? RandomXJitVM.fast(RandomXDataset.attach(dsAddr), v2: v2, index: t) : RandomXJitVM.light(c, v2: v2, index: t))
              : null;
          final ivm = jit ? null : (dsAddr != null ? RandomXVM.fast(RandomXDataset.attach(dsAddr), v2: v2) : RandomXVM.light(c, v2: v2));
          final input = Uint8List(76);
          final out = Uint8List(32);
          for (var i = 0; i < n; i++) {
            input[39] = i;
            input[40] = t;
            vm != null ? vm.hashInto(input, out, 0) : ivm!.hash(input);
          }
        }),
    ]);
    final s = sw.elapsedMilliseconds / 1000;
    stdout.writeln('$label x$threads: ${(n * threads / s).toStringAsFixed(1)} H/s total');
    return;
  }

  final input = Uint8List(76);
  final Uint8List Function(List<int>) hash;
  if (jit) {
    final vm = ds != null
        ? RandomXJitVM.fast(ds, v2: v2, hardwareAes: !softAes)
        : RandomXJitVM.light(cache, v2: v2, hardwareAes: !softAes);
    hash = vm.hash;
  } else {
    final vm = ds != null ? RandomXVM.fast(ds, v2: v2) : RandomXVM.light(cache, v2: v2);
    hash = vm.hash;
  }
  hash(input); // warm up
  sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    input[39] = i;
    hash(input);
  }
  final ms = sw.elapsedMicroseconds / 1000 / n;
  stdout.writeln('$label: ${ms.toStringAsFixed(2)} ms/hash, ${(1000 / ms).toStringAsFixed(1)} H/s');
}
