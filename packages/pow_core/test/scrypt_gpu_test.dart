import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import 'package:gpu_core/gpu_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:test/test.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// Needs an OpenCL GPU: MINERFAN_GPU_TEST=1 dart test test/scrypt_gpu_test.dart
void main() {
  final skip = Platform.environment['MINERFAN_GPU_TEST'] == null || OpenCl.devices().isEmpty
      ? 'set MINERFAN_GPU_TEST=1 on a machine with an OpenCL GPU'
      : null;

  test('GPU scrypt hashes equal the Dart scrypt; search finds exactly the nonces under the target', () {
    final gpu = ScryptGpu(OpenCl.devices().first, batch: 4096);
    try {
      final rnd = Random(7);
      final header = Uint8List.fromList(List.generate(80, (_) => rnd.nextInt(256)));
      const nonce0 = 123456;
      final hashes = gpu.hashes(header, nonce0, 64);
      final cpu = ScryptHasher();
      for (var i = 0; i < 64; i++) {
        final h = Uint8List.fromList(header);
        ByteData.sublistView(h).setUint32(76, nonce0 + i, Endian.little);
        expect(hex(hashes[i]), hex(scryptPow(h, cpu)), reason: 'nonce ${nonce0 + i}');
      }
      // A target that about 1 in 256 hashes meet: compare with the CPU.
      final target = (BigInt.one << 248) - BigInt.one;
      final found = gpu.search(header, target, nonce0)..sort();
      final want = <int>[];
      for (var i = 0; i < gpu.batch; i++) {
        final h = Uint8List.fromList(header);
        ByteData.sublistView(h).setUint32(76, nonce0 + i, Endian.little);
        if (CompactTarget.meets(scryptPow(h, cpu), target)) want.add(nonce0 + i);
      }
      expect(found, want);
      expect(found, isNotEmpty);
    } finally {
      gpu.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}
