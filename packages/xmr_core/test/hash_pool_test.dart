import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/randomx/hash_pool.dart';
import 'package:xmr_core/src/randomx/jit/vm_jit.dart';
import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/memory.dart';
import 'package:xmr_core/src/util/bytes.dart';

void main() {
  for (final kind in [RxMemoryKind.dart, RxMemoryKind.shared]) {
    test('hash pool (${kind.name}): verify and mine', () async {
      final pool = HashPool(workers: 2, memory: kind);
      await pool.start();
      final seed = Uint8List.fromList(utf8.encode('test key 000'));
      await pool.setSeed(seed);
      final h = await pool.hash(seed, Uint8List.fromList(utf8.encode('This is a test')));
      expect(toHex(h), '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f');

      // Difficulty 2: about every second hash qualifies.
      final found = <FoundResult>[];
      final sub = pool.found.listen(found.add);
      pool.mine(MiningJob(7, Uint8List(76), 39, targetForDifficulty(BigInt.two), seed));
      while (found.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      pool.pause();
      await sub.cancel();
      expect(found.map((f) => f.jobId).toSet(), {7});
      expect(found.map((f) => f.nonce).toSet().length, found.length); // no duplicate nonces
      await pool.stop();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  final key000 = Uint8List.fromList(utf8.encode('test key 000'));
  final key001 = Uint8List.fromList(utf8.encode('test key 001'));
  final keyF = fromHex('7797373ea4633194640bf8d8c3b66724d6aa7bd2dc20e009df2f8f1710abe8');
  final input000 = Uint8List.fromList(utf8.encode('This is a test'));
  final input001 = Uint8List.fromList(utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'));
  const hash000 = '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f';
  const hash001 = 'e9ff4503201c0c2cca26d285c93ae883f9b1d30c9eb240b820756f2d5a7905fc';

  test('hash pool (shared): seed rotation keeps the mining seed and one more', () async {
    final pool = HashPool(workers: 2, memory: RxMemoryKind.shared);
    await pool.start();
    await pool.setSeed(key000);
    await pool.setSeed(key001);
    expect(toHex(await pool.hash(key000, input000)), hash000); // previous seed still verifies
    expect(toHex(await pool.hash(key001, input001)), hash001);
    await pool.addVerificationSeed(keyF); // evicts key000, never the mining seed
    expect(pool.hasSeed(key000), isFalse);
    expect(pool.hasSeed(key001), isTrue);
    expect(toHex(await pool.hash(key001, input001)), hash001);
    await pool.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('hash pool (shared): stop while mining waits for every worker to exit', () async {
    // A worker inside a native JIT hash cannot be killed; freeing the cache
    // under it crashed phones, where a light-mode hash takes about 100 ms
    // (longer than the old fixed 50 ms wait).
    for (var round = 0; round < 3; round++) {
      final pool = HashPool(workers: 3, memory: RxMemoryKind.shared, jit: RandomXJitVM.supported);
      await pool.start();
      final seed = Uint8List.fromList(utf8.encode('test key 000'));
      await pool.setSeed(seed);
      pool.mine(MiningJob(1, Uint8List(76), 39, targetForDifficulty(BigInt.from(1) << 62), seed));
      await Future<void>.delayed(Duration(milliseconds: 150 + 100 * round));
      await pool.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Needs about 2.6 GiB free and a minute or two: XMR_FAST_TEST=1 dart test.
  test('hash pool (shared, fast mode): dataset matches light mode', () async {
    final logs = <String>[];
    final pool = HashPool(workers: Platform.numberOfProcessors, memory: RxMemoryKind.shared, fastMode: true)
      ..log = logs.add;
    await pool.start();
    await pool.setSeed(key000);
    expect(toHex(await pool.hash(key000, input000)), hash000); // light, dataset still building
    while (!logs.any((l) => l.contains('dataset ready') || l.contains('light mode'))) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(logs.last, contains('dataset ready'));
    expect(toHex(await pool.hash(key000, input000)), hash000); // fast
    // Flexible mining gives the dataset back and rebuilds it; hashes stay right.
    await pool.setDatasetEnabled(false);
    expect(pool.hasDataset, isFalse);
    expect(logs.last, contains('given back'));
    expect(toHex(await pool.hash(key000, input000)), hash000);
    await pool.setDatasetEnabled(true);
    expect(pool.hasDataset, isTrue);
    expect(toHex(await pool.hash(key000, input000)), hash000);
    await pool.setSeed(key001); // drops key000's dataset, keeps its cache
    expect(toHex(await pool.hash(key000, input000)), hash000);
    await pool.stop();
  }, skip: Platform.environment['XMR_FAST_TEST'] == null ? 'set XMR_FAST_TEST=1' : null, timeout: const Timeout(Duration(minutes: 10)));

  test('hash pool (shared, JIT): self-test, verify and mine', () async {
    final tests = <(bool, String)>[];
    final pool = HashPool(workers: 2, memory: RxMemoryKind.shared, jit: true)..onJitSelfTest = (ok, d) => tests.add((ok, d));
    await pool.start();
    expect(pool.jitActive, isTrue);
    await pool.setSeed(key000);
    while (tests.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(tests.map((t) => t.$1), everyElement(isTrue));
    expect(tests.map((t) => t.$2), containsAll(['startup check matches the interpreter', 'light mode matches the interpreter']));
    expect(toHex(await pool.hash(key000, input000)), hash000);
    final found = <FoundResult>[];
    final sub = pool.found.listen(found.add);
    pool.mine(MiningJob(9, Uint8List(76), 39, targetForDifficulty(BigInt.two), key000));
    while (found.length < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    pool.pause();
    await sub.cancel();
    expect(found.map((f) => f.nonce).toSet().length, found.length);
    // Each found hash really meets the target.
    final vm = RandomXJitVM.light(RandomXCache.create(key000, kind: RxMemoryKind.shared));
    for (final f in found.take(5)) {
      final blob = Uint8List(76);
      blob[39] = f.nonce & 0xff;
      blob[40] = (f.nonce >> 8) & 0xff;
      blob[41] = (f.nonce >> 16) & 0xff;
      blob[42] = (f.nonce >> 24) & 0xff;
      expect(toHex(vm.hash(blob)), toHex(f.hash));
    }
    await pool.stop();
  }, skip: RandomXJitVM.supported ? null : 'no JIT', timeout: const Timeout(Duration(minutes: 3)));

  test('hash pool (shared, JIT, fast mode): dataset built with the JIT', () async {
    final logs = <String>[];
    final tests = <bool>[];
    final pool = HashPool(workers: 4, memory: RxMemoryKind.shared, fastMode: true, jit: true)
      ..log = logs.add
      ..onJitSelfTest = (ok, _) => tests.add(ok);
    await pool.start();
    await pool.setSeed(key000);
    while (!logs.any((l) => l.contains('dataset ready') || l.contains('light mode'))) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(logs.last, contains('dataset ready'));
    expect(tests, [true, true, true]); // startup check, light, fast
    expect(toHex(await pool.hash(key000, input000)), hash000);
    await pool.stop();
  }, skip: Platform.environment['XMR_FAST_TEST'] == null || !RandomXJitVM.supported ? 'set XMR_FAST_TEST=1' : null,
      timeout: const Timeout(Duration(minutes: 5)));
}
