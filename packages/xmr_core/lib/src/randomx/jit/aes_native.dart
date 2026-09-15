import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import '../aes_gen.dart';
import 'asm_a64.dart';
import 'asm_x64.dart';
import 'cpu_features.dart';
import 'exec_memory.dart';

/// RandomX AES generators and hash as hardware-AES machine code (AES-NI on
/// x86-64), following tevador/xmrig `aes_hash.cpp` (BSD-3-Clause). All three
/// take `(void* a, size_t size, void* b)`:
///   fillAes1Rx4(state, size, out)  state (64 B) is written back
///   fillAes4Rx4(state, size, out)  state is not written back
///   hashAes1Rx4(input, size, out)  64-byte result
typedef AesFnC = Void Function(Pointer<Void>, IntPtr, Pointer<Void>);
typedef AesFn = void Function(Pointer<Void>, int, Pointer<Void>);

class AesNative {
  final ExecMemory _mem;
  final int fill1Address, fill4Address, hashAddress;
  late final AesFn fillAes1Rx4 = _fn(fill1Address);
  late final AesFn fillAes4Rx4 = _fn(fill4Address);
  late final AesFn hashAes1Rx4 = _fn(hashAddress);

  AesNative._(this._mem, this.fill1Address, this.fill4Address, this.hashAddress);

  static AesFn _fn(int address) => Pointer<NativeFunction<AesFnC>>.fromAddress(address).asFunction<AesFn>();

  static AesNative? _instance;

  /// Per isolate; null when the CPU has no usable hardware AES path.
  static AesNative? get instance => _instance ??= _build();

  static bool supported = true;

  static AesNative? _build() {
    if (!supported || !ExecMemory.supported) return null;
    if (ExecMemory.isArm64) return CpuFeatures.current.aes ? _buildA64() : null;
    if (!ExecMemory.isX64) return null;
    final a = X64();
    final keys = RxAesKeys.instance;
    final win = Platform.isWindows;

    final k1labels = List.generate(4, (_) => Label());
    final k4labels = List.generate(8, (_) => Label());
    final hsLabels = List.generate(4, (_) => Label());
    final hx = Label(), hx1 = Label();

    void entry() {
      if (!win) return;
      a.push(rdi);
      a.push(rsi);
      a.movRR(rdi, rcx);
      a.movRR(rsi, rdx);
      a.movRR(rdx, r8);
      a.subRI(rsp, 160);
      for (var i = 0; i < 10; i++) {
        a.movdquMR(Mem(rsp, disp: 16 * i), 6 + i);
      }
    }

    void exit() {
      if (win) {
        for (var i = 0; i < 10; i++) {
          a.movdquRM(6 + i, Mem(rsp, disp: 16 * i));
        }
        a.addRI(rsp, 160);
        a.pop(rsi);
        a.pop(rdi);
      }
      a.ret();
    }

    // fillAes1Rx4(state=rdi, size=rsi, out=rdx)
    final fill1 = a.pos;
    entry();
    for (var i = 0; i < 4; i++) {
      a.movdquRM(i, Mem(rdi, disp: 16 * i));
    }
    for (var i = 0; i < 4; i++) {
      a.movdquRM(4 + i, Mem.rip(k1labels[i]));
    }
    final loop1 = Label();
    a.leaRM(rsi, const Mem(rdx, index: rsi));
    a.bind(loop1);
    a.aesdec(0, 4);
    a.aesenc(1, 5);
    a.aesdec(2, 6);
    a.aesenc(3, 7);
    for (var i = 0; i < 4; i++) {
      a.movdquMR(Mem(rdx, disp: 16 * i), i);
    }
    a.addRI(rdx, 64);
    a.cmpRR(rdx, rsi);
    a.jcc(2, loop1); // jb
    for (var i = 0; i < 4; i++) {
      a.movdquMR(Mem(rdi, disp: 16 * i), i);
    }
    exit();

    // fillAes4Rx4(state=rdi, size=rsi, out=rdx)
    final fill4 = a.pos;
    entry();
    for (var i = 0; i < 4; i++) {
      a.movdquRM(i, Mem(rdi, disp: 16 * i));
    }
    for (var i = 0; i < 8; i++) {
      a.movdquRM(4 + i, Mem.rip(k4labels[i]));
    }
    final loop4 = Label();
    a.leaRM(rsi, const Mem(rdx, index: rsi));
    a.bind(loop4);
    for (var r = 0; r < 4; r++) {
      a.aesdec(0, 4 + r);
      a.aesenc(1, 4 + r);
      a.aesdec(2, 8 + r);
      a.aesenc(3, 8 + r);
    }
    for (var i = 0; i < 4; i++) {
      a.movdquMR(Mem(rdx, disp: 16 * i), i);
    }
    a.addRI(rdx, 64);
    a.cmpRR(rdx, rsi);
    a.jcc(2, loop4);
    exit();

    // hashAes1Rx4(input=rdi, size=rsi, out=rdx)
    final hash = a.pos;
    entry();
    for (var i = 0; i < 4; i++) {
      a.movdquRM(i, Mem.rip(hsLabels[i]));
    }
    final loopH = Label();
    a.leaRM(rsi, const Mem(rdi, index: rsi));
    a.bind(loopH);
    a.aesencM(0, const Mem(rdi));
    a.aesdecM(1, const Mem(rdi, disp: 16));
    a.aesencM(2, const Mem(rdi, disp: 32));
    a.aesdecM(3, const Mem(rdi, disp: 48));
    a.addRI(rdi, 64);
    a.cmpRR(rdi, rsi);
    a.jcc(2, loopH);
    a.movdquRM(4, Mem.rip(hx));
    a.movdquRM(5, Mem.rip(hx1));
    for (final k in const [4, 5]) {
      a.aesenc(0, k);
      a.aesdec(1, k);
      a.aesenc(2, k);
      a.aesdec(3, k);
    }
    for (var i = 0; i < 4; i++) {
      a.movdquMR(Mem(rdx, disp: 16 * i), i);
    }
    exit();

    // constants
    void words(Uint32List w, int from, int count) {
      for (var i = from; i < from + count; i++) {
        a.d32(w[i]);
      }
    }

    a.align(16, code: false);
    for (var i = 0; i < 4; i++) {
      a.bind(k1labels[i]);
      words(keys.gen1R, 4 * i, 4);
    }
    for (var i = 0; i < 8; i++) {
      a.bind(k4labels[i]);
      words(keys.gen4R, 4 * i, 4);
    }
    for (var i = 0; i < 4; i++) {
      a.bind(hsLabels[i]);
      words(keys.hashState, 4 * i, 4);
    }
    a.bind(hx);
    words(keys.hashXKeys, 0, 4);
    a.bind(hx1);
    words(keys.hashXKeys, 4, 4);

    final code = Uint8List.fromList(a.bytes);

    final mem = ExecMemory.allocate(code.length);
    mem.bytes.setRange(0, code.length, code);
    mem.executable();
    return AesNative._(mem, mem.address + fill1, mem.address + fill4, mem.address + hash);
  }

  void free() => _mem.free();

  /// ARMv8 crypto extension version. AESE/AESD include the round-key xor
  /// before the S-box, so x86's AESENC(s, k) is AESE(s, 0), AESMC, EOR k
  /// (and AESDEC is AESD, AESIMC, EOR). Only v0-v7 and v16-v31 are used
  /// (v8-v15 are callee-saved).
  static AesNative _buildA64() {
    final a = A64();
    final keys = RxAesKeys.instance;
    const zero = 31;
    void enc(int s, int k) {
      a.aese(s, zero);
      a.aesmc(s, s);
      a.eorV(s, s, k);
    }

    void dec(int s, int k) {
      a.aesd(s, zero);
      a.aesimc(s, s);
      a.eorV(s, s, k);
    }

    final k1 = A64Label(), k4 = A64Label(), hs = A64Label(), hx = A64Label();

    // fillAes1Rx4(x0 = state, x1 = size, x2 = out)
    final fill1 = a.pos;
    final l1 = A64Label();
    a.ldpQ(0, 1, 0, 0);
    a.ldpQ(2, 3, 0, 32);
    a.adr(3, k1);
    a.ldpQ(4, 5, 3, 0);
    a.ldpQ(6, 7, 3, 32);
    a.moviZero4s(zero);
    a.addReg(1, 2, 1);
    a.bind(l1);
    dec(0, 4);
    enc(1, 5);
    dec(2, 6);
    enc(3, 7);
    a.stpQ(0, 1, 2, 0);
    a.stpQ(2, 3, 2, 32);
    a.addImm(2, 2, 64);
    a.cmpReg(2, 1);
    a.bne(l1);
    a.stpQ(0, 1, 0, 0);
    a.stpQ(2, 3, 0, 32);
    a.ret();

    // fillAes4Rx4(x0 = state, x1 = size, x2 = out); keys in v4-v7, v16-v19
    final fill4 = a.pos;
    final l4 = A64Label();
    a.ldpQ(0, 1, 0, 0);
    a.ldpQ(2, 3, 0, 32);
    a.adr(3, k4);
    a.ldpQ(4, 5, 3, 0);
    a.ldpQ(6, 7, 3, 32);
    a.ldpQ(16, 17, 3, 64);
    a.ldpQ(18, 19, 3, 96);
    a.moviZero4s(zero);
    a.addReg(1, 2, 1);
    a.bind(l4);
    for (var r = 0; r < 4; r++) {
      dec(0, 4 + r);
      enc(1, 4 + r);
      dec(2, 16 + r);
      enc(3, 16 + r);
    }
    a.stpQ(0, 1, 2, 0);
    a.stpQ(2, 3, 2, 32);
    a.addImm(2, 2, 64);
    a.cmpReg(2, 1);
    a.bne(l4);
    a.ret();

    // hashAes1Rx4(x0 = input, x1 = size, x2 = out)
    final hash = a.pos;
    final lh = A64Label();
    a.adr(3, hs);
    a.ldpQ(0, 1, 3, 0);
    a.ldpQ(2, 3, 3, 32);
    a.moviZero4s(zero);
    a.addReg(1, 0, 1);
    a.bind(lh);
    a.ldpQ(4, 5, 0, 0);
    a.ldpQ(6, 7, 0, 32);
    enc(0, 4);
    dec(1, 5);
    enc(2, 6);
    dec(3, 7);
    a.addImm(0, 0, 64);
    a.cmpReg(0, 1);
    a.bne(lh);
    a.adr(3, hx);
    a.ldpQ(4, 5, 3, 0);
    for (final k in const [4, 5]) {
      enc(0, k);
      dec(1, k);
      enc(2, k);
      dec(3, k);
    }
    a.stpQ(0, 1, 2, 0);
    a.stpQ(2, 3, 2, 32);
    a.ret();

    void words(Uint32List w) {
      for (final x in w) {
        a.w(x);
      }
    }

    a.align(16);
    a.bind(k1);
    words(keys.gen1R);
    a.bind(k4);
    words(keys.gen4R);
    a.bind(hs);
    words(keys.hashState);
    a.bind(hx);
    words(keys.hashXKeys);

    final code = Uint8List.fromList(a.bytes);
    final mem = ExecMemory.allocate(code.length);
    mem.bytes.setRange(0, code.length, code);
    mem.executable();
    return AesNative._(mem, mem.address + fill1, mem.address + fill4, mem.address + hash);
  }
}
