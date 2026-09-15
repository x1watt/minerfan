import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/randomx/aes_gen.dart';
import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/jit/aes_native.dart';
import 'package:xmr_core/src/randomx/jit/asm_x64.dart';
import 'package:xmr_core/src/randomx/jit/cpu_features.dart';
import 'package:xmr_core/src/randomx/jit/exec_memory.dart';
import 'package:xmr_core/src/randomx/jit/jit_x64.dart';
import 'package:xmr_core/src/randomx/jit/x64_templates.dart';
import 'package:xmr_core/src/randomx/jit/vm_jit.dart';
import 'package:xmr_core/src/randomx/memory.dart';
import 'package:xmr_core/src/randomx/vm.dart';
import 'package:xmr_core/src/util/bytes.dart';

// Vectors from tevador/RandomX src/tests/tests.cpp; the interpreter
// (vm.dart) is the second reference for random inputs.

final key000 = utf8.encode('test key 000');
final key001 = utf8.encode('test key 001');

void main() {
  final skip = RandomXJitVM.supported ? null : 'JIT not supported on this CPU';

  group('native AES', () {
    final rng = Random(1);
    Uint8List random(int n) => Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

    test('fillAes1Rx4, fillAes4Rx4, hashAes1Rx4 match the Dart versions', () {
      final aes = AesNative.instance!;
      final buf = RxBuffer.allocate(4096 ~/ 8 + 16, RxMemoryKind.shared);
      final base = (buf.address + 63) & ~63;
      final mem = Pointer<Uint8>.fromAddress(base).asTypedList(4096);
      for (var round = 0; round < 20; round++) {
        final state = random(64);
        final input = random(2048);

        // fill1: state at 0, out at 1024 (1024 bytes)
        mem.setRange(0, 64, state);
        aes.fillAes1Rx4(Pointer.fromAddress(base), 1024, Pointer.fromAddress(base + 1024));
        final ds = Uint32List.fromList(Uint32List.view(Uint8List.fromList(state).buffer));
        final dout = Uint32List(256);
        fillAes1Rx4(ds, dout, 0, 256);
        expect(mem.sublist(1024, 2048), Uint8List.view(dout.buffer));
        expect(mem.sublist(0, 64), Uint8List.view(ds.buffer)); // state written back

        // fill4
        mem.setRange(0, 64, state);
        aes.fillAes4Rx4(Pointer.fromAddress(base), 3200, Pointer.fromAddress(base + 256));
        final d4 = Uint32List(800);
        fillAes4Rx4(Uint32List.view(Uint8List.fromList(state).buffer), d4, 800);
        expect(mem.sublist(256, 256 + 3200), Uint8List.view(d4.buffer));
        expect(mem.sublist(0, 64), state); // state not written back

        // hash
        mem.setRange(1024, 1024 + 2048, input);
        aes.hashAes1Rx4(Pointer.fromAddress(base + 1024), 2048, Pointer.fromAddress(base));
        final dh = Uint32List(16);
        hashAes1Rx4(Uint32List.view(input.buffer), dh, 0);
        expect(mem.sublist(0, 64), Uint8List.view(dh.buffer));
      }
      buf.free();
    });
  }, skip: skip);

  group('JIT with cache "test key 000"', () {
    late RandomXCache cache;
    setUpAll(() => cache = RandomXCache.create(key000, kind: RxMemoryKind.shared));
    tearDownAll(() => cache.free());

    test('dataset items through the compiled SuperscalarHash', () {
      final init = JitDatasetInit.build(cache);
      final ds = RxBuffer.allocate(8 * 64, RxMemoryKind.shared);
      final rl = Int64List(8), ref = Int64List(8);
      final rng = Random(2);
      final items = [0, 10000000, 20000000, 30000000, for (var i = 0; i < 200; i++) rng.nextInt(34078719)];
      for (final item in items) {
        // dataset base address chosen so that item lands at ds.address
        JitDatasetInit.initRange(init.initAddress, init.cacheSlot, ds.address - item * 64, item, item + 1);
        cache.initDatasetItem(ref, 0, item, rl);
        expect(ds.words.sublist(0, 8), ref, reason: 'item $item');
      }
      expect(ds.words[0], isNot(0));
      JitDatasetInit.initRange(init.initAddress, init.cacheSlot, ds.address, 0, 1);
      expect(ds.words[0], 0x680588a85ae222db);
      ds.free();
      init.free();
    });

    test('hash a/b/c v1 and v2 (light)', () {
      final vm = RandomXJitVM.light(cache);
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f');
      expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
          '300a0adb47603dedb42228ccb2b211104f4da45af709cd7547cd049e9489c969');
      expect(toHex(vm.hash(utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'))),
          'c36d4ed4191e617309867ed66a443be4075014e2b061bcdaf9ce7b721d2b77a8');
      vm.v2 = true;
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f');
      expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
          '9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf');
      expect(toHex(vm.hash(utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'))),
          '4d6b063a1a603751d525f18a171336a4002f2f06df6c17e4b25fe17e17796e42');
      vm.free();
    });

    test('random inputs match the interpreter (v1 and v2)', () {
      final jit = RandomXJitVM.light(cache);
      final interp = RandomXVM.light(cache);
      final rng = Random(3);
      for (var i = 0; i < 24; i++) {
        final input = Uint8List.fromList(List.generate(1 + rng.nextInt(100), (_) => rng.nextInt(256)));
        final v2 = i.isOdd;
        jit.v2 = v2;
        interp.v2 = v2;
        expect(toHex(jit.hash(input)), toHex(interp.hash(input)), reason: 'input ${toHex(input)} v2=$v2');
      }
      jit.free();
    });

    test('without hardware AES: soft AES around JIT programs (v1), interpreter for v2', () {
      final vm = RandomXJitVM.light(cache, hardwareAes: false);
      expect(vm.hardwareAes, isFalse);
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f');
      expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
          '300a0adb47603dedb42228ccb2b211104f4da45af709cd7547cd049e9489c969');
      vm.v2 = true;
      expect(toHex(vm.hash(utf8.encode('This is a test'))),
          '22ec6b861b3eb23686b2efbad69513c967ecfce80983df66c9c5b4fbfb4cdb6f');
      vm.free();
    });

    test('W^X fallback (no read-write-execute mapping) gives the same hashes', () {
      ExecMemory.allowRwx = false;
      try {
        final vm = RandomXJitVM.light(cache);
        expect(toHex(vm.hash(utf8.encode('This is a test'))),
            '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f');
        vm.v2 = true;
        expect(toHex(vm.hash(utf8.encode('Lorem ipsum dolor sit amet'))),
            '9e2c772c12fd48f93c14c97fdc89d556264d9100597023f44d9163e279012ecf');
        vm.free();
      } finally {
        ExecMemory.allowRwx = true;
      }
    });

    test('Dart floating point is unaffected by the programs\' rounding modes', () {
      final vm = RandomXJitVM.light(cache);
      for (var i = 0; i < 4; i++) {
        vm.hash(utf8.encode('rounding $i'));
        expect(0.1 + 0.2, 0.30000000000000004);
        expect(1.0 / 3.0, 0.3333333333333333);
        expect(2.0 / 3.0, 0.6666666666666666);
      }
      vm.free();
    });
  }, skip: skip);

  group('JIT with cache "test key 001"', () {
    late RandomXCache cache;
    setUpAll(() => cache = RandomXCache.create(key001, kind: RxMemoryKind.shared));
    tearDownAll(() => cache.free());

    test('hash d/e v1 and v2 (light)', () {
      final input = utf8.encode('sed do eiusmod tempor incididunt ut labore et dolore magna aliqua');
      final blob = fromHex('0b0b98bea7e805e0010a2126d287a2a0cc833d312cb786385a7c2f9de69d25537f584a9bc9977b00000000'
          '666fd8753bf61a8631f12984e3fd44f4014eca629276817b56f32e9b68bd82f416');
      final vm = RandomXJitVM.light(cache);
      expect(toHex(vm.hash(input)), 'e9ff4503201c0c2cca26d285c93ae883f9b1d30c9eb240b820756f2d5a7905fc');
      expect(toHex(vm.hash(blob)), 'c56414121acda1713c2f2a819d8ae38aed7c80c35c2a769298d34f03833cd5f1');
      vm.v2 = true;
      expect(toHex(vm.hash(input)), '97024134686ce27d362ea8d86d8ef16483ac272abdabd46ef13359400777fe5e');
      expect(toHex(vm.hash(blob)), 'c8e92c5f7c1946fecf06bc382b92e3111da38ee3e6a5ad90704e1a9d8aaf6e76');
      vm.free();
    });
  }, skip: skip);

  test('hash f v1 (ISUB_R 0x80000000 edge case, light)', () {
    final cache = RandomXCache.create(fromHex('7797373ea4633194640bf8d8c3b66724d6aa7bd2dc20e009df2f8f1710abe8'),
        kind: RxMemoryKind.shared);
    final vm = RandomXJitVM.light(cache);
    final input = fromHex('1010e1eaf8cf067b37b5f0ee031ab23ed1755e090a3af4415830145853e2be3e1f6821fed84dae58d00e00'
        'da5214d6c1f2d0622e0abd51f9373d04e0b0f8e6d6514d90689721c4aac5a9bb0d');
    expect(toHex(vm.hash(input)), '78af2a1864c42abce36d2e8983e13df99b2af0ce1362999af09fab004d4435a8');
    vm.free();
    cache.free();
  }, skip: skip);

  // tevador/RandomX src/tests/benchmark.cpp: XOR of the hashes of nonces
  // 0..999 over its block template, key = 4 zero bytes.
  test('benchmark cross-check: 1000 nonces, v1 and v2 (light)', () {
    final template = fromHex('0707f7a4f0d605b303260816ba3f10902e1a145ac5fad3aa3af6ea44c11869dc4f853f002b2e'
        'ea0000000077b206a02ca5b1d4ce6bbfdf0acac38bded34d2dcdeef95cd20cefc12f61d56109');
    final cache = RandomXCache.create(Uint8List(4), kind: RxMemoryKind.shared);
    final vm = RandomXJitVM.light(cache);
    final out = Uint8List(32);
    for (final (v2, expected) in [
      (false, '10b649a3f15c7c7f88277812f2e74b337a0f20ce909af09199cccb960771cfa1'),
      (true, 'b85d79e080b10b6ad28c2e6c993601a1361917dba979e03a0a8f7248aaf4ba52'),
    ]) {
      vm.v2 = v2;
      final acc = Uint8List(32);
      final blob = Uint8List.fromList(template);
      for (var nonce = 0; nonce < 1000; nonce++) {
        writeU32LE(blob, 39, nonce);
        vm.hashInto(blob, out, 0);
        for (var i = 0; i < 32; i++) {
          acc[i] ^= out[i];
        }
      }
      expect(toHex(acc), expected, reason: 'v2=$v2');
    }
    vm.free();
    cache.free();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  // The Win64 prologue/epilogue, run on Linux through a thunk that moves the
  // SysV arguments into the Win64 registers: the program must leave exactly
  // the same state as the SysV build.
  test('Win64 program variant matches SysV (through a calling-convention thunk)', () {
    final cache = RandomXCache.create(key000, kind: RxMemoryKind.shared);
    final cpu = CpuFeatures.current;
    final sysv = JitX64(cpu: cpu, templates: X64Templates(avx: cpu.avx, win64: false));
    final win = JitX64(cpu: cpu, templates: X64Templates(avx: cpu.avx, win64: true), codeOffsetIndex: 3);
    sysv.generateSuperscalarHash(cache.programs);
    win.generateSuperscalarHash(cache.programs);

    // thunk(regFile, memRegs, scratchpad, iterations, target)
    final a = X64()
      ..push(rbp)
      ..movRR(rbp, rsp)
      ..movRR(r11, r8)
      ..movRR(r9, rcx)
      ..movRR(r8, rdx)
      ..movRR(rdx, rsi)
      ..movRR(rcx, rdi)
      ..subRI(rsp, 32)
      ..dbs(const [0x41, 0xFF, 0xD3]) // call r11
      ..movRR(rsp, rbp)
      ..pop(rbp)
      ..ret();
    final thunkMem = ExecMemory.allocate(4096);
    thunkMem.bytes.setRange(0, a.pos, a.bytes);
    thunkMem.executable();
    final thunk = Pointer<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint64, Pointer<Void>)>>
            .fromAddress(thunkMem.address)
        .asFunction<void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int, Pointer<Void>)>();
    final direct = Pointer<NativeFunction<Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint64)>>
            .fromAddress(sysv.programAddress)
        .asFunction<void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int)>();

    // Two identical states: [scratchpad 2 MiB | regFile 256 | memRegs 64].
    final rng = Random(4);
    final aes = AesNative.instance!;
    NativePages state() => NativePages.allocate((2 << 20) + 4096);
    final s1 = state(), s2 = state();
    final prog = Uint8List(3200);
    for (var round = 0; round < 6; round++) {
      final seed = Uint8List.fromList(List.generate(64, (_) => rng.nextInt(256)));
      final aRegs = List.generate(8, (_) => 0x3ff0000000000000 + rng.nextInt(1 << 30));
      for (final st in [s1, s2]) {
        final m = Pointer<Uint8>.fromAddress(st.address).asTypedList((2 << 20) + 4096);
        m.setRange((2 << 20) + 512, (2 << 20) + 576, seed);
        aes.fillAes1Rx4(Pointer.fromAddress(st.address + (2 << 20) + 512), 2 << 20, Pointer.fromAddress(st.address));
        final bd = ByteData.sublistView(m);
        for (var i = 0; i < 8; i++) {
          bd.setInt64((2 << 20) + 192 + 8 * i, aRegs[i], Endian.little);
        }
        bd.setUint32((2 << 20) + 256, 0x12340, Endian.little); // mx
        bd.setUint32((2 << 20) + 260, 0x56780, Endian.little); // ma
        bd.setInt64((2 << 20) + 264, cache.buffer.address, Endian.little);
        bd.setUint32((2 << 20) + 272, 0x9FC0 | (round % 4) << 13, Endian.little); // start in a rounding mode
      }
      // Same random program for both.
      for (var i = 0; i < prog.length; i++) {
        prog[i] = rng.nextInt(256);
      }
      final v2 = round.isOdd;
      sysv.v2 = v2;
      win.v2 = v2;
      final eMask0 = 0x3a00000000000000 | rng.nextInt(1 << 22), eMask1 = 0x3b00000000000000 | rng.nextInt(1 << 22);
      sysv.generateProgramLight(prog, eMask0, eMask1, const [1, 2, 5, 7], 64 * 1000);
      win.generateProgramLight(prog, eMask0, eMask1, const [1, 2, 5, 7], 64 * 1000);
      direct(Pointer.fromAddress(s1.address + (2 << 20)), Pointer.fromAddress(s1.address + (2 << 20) + 256),
          Pointer.fromAddress(s1.address), 64);
      thunk(Pointer.fromAddress(s2.address + (2 << 20)), Pointer.fromAddress(s2.address + (2 << 20) + 256),
          Pointer.fromAddress(s2.address), 64, Pointer.fromAddress(win.programAddress));
      final m1 = Pointer<Uint8>.fromAddress(s1.address).asTypedList((2 << 20) + 280);
      final m2 = Pointer<Uint8>.fromAddress(s2.address).asTypedList((2 << 20) + 280);
      expect(toHex(m2.sublist(2 << 20, (2 << 20) + 256)), toHex(m1.sublist(2 << 20, (2 << 20) + 256)),
          reason: 'register file, round $round');
      expect(m2.sublist((2 << 20) + 272, (2 << 20) + 276), m1.sublist((2 << 20) + 272, (2 << 20) + 276),
          reason: 'rounding mode');
      expect(m2.sublist(0, 2 << 20), m1.sublist(0, 2 << 20), reason: 'scratchpad, round $round');
    }
    expect(0.1 + 0.2, 0.30000000000000004);
    s1.free();
    s2.free();
    thunkMem.free();
    sysv.free();
    win.free();
    cache.free();
  }, skip: skip ?? (ExecMemory.isX64 ? null : 'x86-64 only'));

  // Fast mode reads the 2 GiB dataset directly. A synthetic dataset (a
  // pattern that depends on the address) exercises the dataset addressing of
  // the JIT's fast path against the interpreter's, without building a cache.
  // Needs about 2.2 GiB: XMR_FAST_TEST=1.
  test('fast mode on a synthetic dataset matches the interpreter (v1 and v2)', () {
    final ds = RandomXDataset.allocate(RxMemoryKind.shared);
    final w = ds.memory;
    for (var i = 0; i < w.length; i++) {
      w[i] = (i * 0x9E3779B97F4A7C15) ^ (i >>> 7);
    }
    final jit = RandomXJitVM.fast(ds);
    final interp = RandomXVM.fast(ds);
    final rng = Random(5);
    for (var i = 0; i < 6; i++) {
      final input = Uint8List.fromList(List.generate(76, (_) => rng.nextInt(256)));
      jit.v2 = interp.v2 = i.isOdd;
      expect(toHex(jit.hash(input)), toHex(interp.hash(input)), reason: 'input $i');
    }
    jit.free();
    ds.free();
  }, skip: skip ?? (Platform.environment['XMR_FAST_TEST'] == null ? 'set XMR_FAST_TEST=1' : null),
      timeout: const Timeout(Duration(minutes: 30)));
}
