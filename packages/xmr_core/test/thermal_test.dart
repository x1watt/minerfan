import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/node/thermal.dart';
import 'package:xmr_core/src/randomx/hash_pool.dart';
import 'package:xmr_core/src/randomx/memory.dart';

void main() {
  group('ThermalGovernor', () {
    test('unknown readings leave all threads on', () {
      final g = ThermalGovernor(8);
      expect(g.update(const ThermalReading(), 0), 8);
      expect(g.update(const ThermalReading(), 120000), 8);
    });

    test('hot steps down one thread per reading, never below one', () {
      final g = ThermalGovernor(4);
      const hot = ThermalReading(headroom: 0.9);
      expect(g.update(hot, 0), 3);
      expect(g.update(hot, 10000), 2);
      expect(g.update(hot, 20000), 1);
      expect(g.update(hot, 30000), 1);
    });

    test('very hot cuts about 40% at once; critical pauses; recovery is slow', () {
      final g = ThermalGovernor(8);
      expect(g.update(const ThermalReading(status: 3), 0), 4);
      expect(g.update(const ThermalReading(batteryC: 49), 10000), 0);
      // Out of critical but warm: resume on one thread and hold.
      expect(g.update(const ThermalReading(batteryC: 40), 20000), 1);
      expect(g.update(const ThermalReading(batteryC: 40), 90000), 1);
      // Cool: one more thread per minute of cool readings.
      const cool = ThermalReading(status: 0, headroom: 0.4, batteryC: 33);
      expect(g.update(cool, 100000), 1);
      expect(g.update(cool, 130000), 1);
      expect(g.update(cool, 160000), 2);
      expect(g.update(cool, 220000), 3);
      // Any warm reading restarts the cool timer.
      expect(g.update(const ThermalReading(headroom: 0.75), 230000), 3);
      expect(g.update(cool, 240000), 3);
      expect(g.update(cool, 290000), 3);
      expect(g.update(cool, 300000), 4);
    });

    test('levels', () {
      expect(ThermalGovernor.level(const ThermalReading(status: 0, headroom: 0.5, batteryC: 30)), 0);
      expect(ThermalGovernor.level(const ThermalReading(status: 1)), 1);
      expect(ThermalGovernor.level(const ThermalReading(batteryC: 42.5)), 2);
      expect(ThermalGovernor.level(const ThermalReading(headroom: 0.96)), 3);
      expect(ThermalGovernor.level(const ThermalReading(status: 4)), 4);
      expect(ThermalGovernor.level(const ThermalReading(headroom: -1, batteryC: double.nan)), 0);
    });
  });

  test('hash pool: changing active workers keeps nonces disjoint and stops idle workers', () async {
    final pool = HashPool(workers: 3, memory: RxMemoryKind.shared);
    await pool.start();
    final seed = Uint8List.fromList(utf8.encode('test key 000'));
    await pool.setSeed(seed);
    final found = <FoundResult>[];
    final sub = pool.found.listen(found.add);
    pool.mine(MiningJob(1, Uint8List(76), 39, targetForDifficulty(BigInt.two), seed));
    while (found.length < 6) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    pool.setActiveWorkers(1);
    found.clear();
    while (found.length < 6) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // One active worker: nonces 0, 1, 2, ... (step 1 from worker 0).
    expect(found.map((f) => f.nonce).toSet().length, found.length);
    expect(pool.activeWorkers, 1);
    pool.setActiveWorkers(0);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final before = pool.stats.hashes;
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(pool.stats.hashes - before, lessThan(20)); // at most in-flight slices
    await sub.cancel();
    await pool.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
