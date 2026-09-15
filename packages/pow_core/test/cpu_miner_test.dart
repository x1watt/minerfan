import 'dart:async';
import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';
import 'package:test/test.dart';

void main() {
  test('CPU miner finds nonces that meet an easy target, on every thread', () async {
    final miner = CpuHeaderMiner(pow: ScryptPow.new, threads: 2);
    await miner.start();
    final header = Uint8List.fromList(List.generate(80, (i) => i * 7));
    final target = BigInt.one << 250; // about 1 in 64 hashes
    final found = <FoundNonce>[];
    final sub = miner.found.listen(found.add);
    miner.work(MiningWork(1, header, target));
    await Future<void>.delayed(const Duration(seconds: 3));
    await sub.cancel();
    expect(miner.stats.hashes, greaterThan(0));
    expect(found, isNotEmpty);
    final pow = ScryptPow();
    for (final f in found) {
      final h = Uint8List.fromList(header);
      ByteData.sublistView(h).setUint32(76, f.nonce, Endian.little);
      expect(pow.hash(h), f.powHash);
      expect(CompactTarget.meets(f.powHash, target), isTrue);
    }
    // Both halves of the nonce space were searched.
    expect(found.any((f) => f.nonce < 0x80000000), isTrue);
    expect(found.any((f) => f.nonce >= 0x80000000), isTrue);
    await miner.stop();
  });
}
