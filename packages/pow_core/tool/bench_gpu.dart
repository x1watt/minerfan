import 'dart:typed_data';

import 'package:gpu_core/gpu_core.dart';
import 'package:pow_core/pow_core.dart';

/// scrypt(1024,1,1) hashes per second on the first GPU, per batch size.
void main(List<String> args) {
  final dev = OpenCl.devices().first;
  print(dev);
  final header = Uint8List(80);
  final sizes = args.isEmpty ? [null, 8192, 16384] : args.map(int.parse).toList();
  for (final size in sizes) {
    final gpu = ScryptGpu(dev, batch: size);
    gpu.search(header, BigInt.zero, 0); // warm up (build, first launch)
    final sw = Stopwatch()..start();
    var n = 0, nonce = 0;
    while (sw.elapsedMilliseconds < 5000) {
      gpu.search(header, BigInt.zero, nonce);
      nonce += gpu.batch;
      n += gpu.batch;
    }
    final rate = n * 1000 / sw.elapsedMilliseconds;
    print('batch ${gpu.batch}: ${(rate / 1000).toStringAsFixed(1)} kH/s, ${(sw.elapsedMilliseconds * gpu.batch / n).toStringAsFixed(0)} ms per launch');
    gpu.dispose();
  }
}
