import 'dart:io' show Platform;
import 'dart:typed_data';

import 'asm_x64.dart';

/// The static code pieces of the x86-64 RandomX JIT, written with the Dart
/// assembler. Port of xmrig/tevador `jit_compiler_x86_static.S` and
/// `asm/*.inc` (BSD-3-Clause, Copyright (c) 2018-2019 tevador,
/// Copyright (c) 2019-2021 SChernykh, Copyright (c) 2019-2021 XMRig).
///
/// One change from xmrig: the program keeps its rounding mode in
/// `MemoryRegisters` (offset 16) and the caller's MXCSR at offset 20. The
/// prologue saves the caller's MXCSR and loads RandomX's; the epilogue does
/// the reverse, so the rounding mode carries over the 8 programs of a hash
/// while Dart code in between runs with its own FP state.

const int _spMask64 = 2097088; // RANDOMX_SCRATCHPAD_MASK (L3, 64-byte lines)
const int _datasetBaseMask = 2147483584;
const int _cacheMask = 4194303;

class X64Templates {
  final bool win64;
  late final Uint8List prefetchScratchpad, prefetchScratchpadBmi2;
  late final Uint8List prologue; // up to loop_begin, 64-byte multiple
  late final int exp240Offset; // eMask goes here (16 bytes)
  late final int imulRcpStoreOffset; // first `mov rcx, imm64` of 16
  late final Uint8List loopLoad;
  late final Uint8List readDataset, readDatasetV2;
  late final Uint8List readDatasetLightInit, readDatasetLightInitV2, readDatasetLightFin;
  late final Uint8List loopStore, loopStoreHardAes;
  late final Uint8List epilogue;
  late final Uint8List datasetInit; // copied to code+0; calls code+32768
  late final Uint8List sshashLoad, sshashPrefetch, sshashInit;

  X64Templates({required bool avx, bool? win64}) : win64 = win64 ?? Platform.isWindows {
    prefetchScratchpad = _build((a) {
      a.movRR(rdx, rax);
      a.andRI32(rax, _spMask64);
      a.prefetcht0(const Mem(rsi, index: rax));
      a.rorRI(rdx, 32);
      a.andRI32(rdx, _spMask64);
      a.prefetcht0(const Mem(rsi, index: rdx));
    });
    prefetchScratchpadBmi2 = _build((a) {
      a.rorxRdxRax32();
      a.andRI32(rax, _spMask64);
      a.prefetcht0(const Mem(rsi, index: rax));
      a.andRI32(rdx, _spMask64);
      a.prefetcht0(const Mem(rsi, index: rdx));
    });
    _buildPrologue(avx);
    loopLoad = _build((a) {
      a.leaRM(rcx, const Mem(rsi, index: rax));
      a.movMR(const Mem(rsp, disp: 16), rcx);
      for (var i = 0; i < 8; i++) {
        a.xorRM(r8 + i, Mem(rcx, disp: 8 * i));
      }
      a.leaRM(rcx, const Mem(rsi, index: rdx));
      a.movMR(const Mem(rsp, disp: 24), rcx);
      for (var i = 0; i < 8; i++) {
        a.cvtdq2pdRM(i, Mem(rcx, disp: 8 * i));
      }
      for (var i = 4; i < 8; i++) {
        a.andpd(i, 13);
      }
      for (var i = 4; i < 8; i++) {
        a.orpd(i, 14);
      }
    });
    readDataset = _build((a) {
      a.movRR32(rcx, rbp); // ecx = ma
      a.andRI32(rcx, _datasetBaseMask);
      a.xorRM(r8, const Mem(rdi, index: rcx));
      a.rorRI(rbp, 32); // swap ma and mx
      a.xorRR(rbp, rax); // modify mx
      a.movRR32(rdx, rbp);
      a.andRI32(rdx, _datasetBaseMask);
      a.prefetchnta(const Mem(rdi, index: rdx));
      for (var i = 1; i < 8; i++) {
        a.xorRM(r8 + i, Mem(rdi, index: rcx, disp: 8 * i));
      }
    });
    readDatasetV2 = _build((a) {
      a.movRR32(rcx, rbp);
      a.andRI32(rcx, _datasetBaseMask);
      a.xorRM(r8, const Mem(rdi, index: rcx));
      a.xorRR(rbp, rax); // modify ma
      a.movRR32(rdx, rbp);
      a.rorRI(rbp, 32);
      a.andRI32(rdx, _datasetBaseMask);
      a.prefetchnta(const Mem(rdi, index: rdx));
      for (var i = 1; i < 8; i++) {
        a.xorRM(r8 + i, Mem(rdi, index: rcx, disp: 8 * i));
      }
    });
    readDatasetLightInit = _build((a) {
      a.subRI(rsp, 200);
      a.movMR(const Mem(rsp, disp: 64), rbx);
      for (var i = 0; i < 8; i++) {
        a.movMR(Mem(rsp, disp: 56 - 8 * i), r8 + i);
      }
      a.rorRI(rbp, 32);
      a.xorRR(rbp, rax);
      a.movRR(rbx, rbp);
      a.shrRI(rbx, 38);
      a.andRI32(rbx, _datasetBaseMask ~/ 64);
    });
    // v2 (xmrig has no light-mode v2 path; order as in tevador's
    // program_read_dataset_sshash_init_v2.inc): read ma, then modify it.
    readDatasetLightInitV2 = _build((a) {
      a.subRI(rsp, 200);
      a.movMR(const Mem(rsp, disp: 64), rbx);
      for (var i = 0; i < 8; i++) {
        a.movMR(Mem(rsp, disp: 56 - 8 * i), r8 + i);
      }
      a.movRR32(rbx, rbp); // ebx = ma
      a.shrRI(rbx, 6);
      a.andRI32(rbx, _datasetBaseMask ~/ 64);
      a.xorRR(rbp, rax); // modify ma
      a.rorRI(rbp, 32); // swap ma and mx
    });
    readDatasetLightFin = _build((a) {
      a.movRM(rbx, const Mem(rsp, disp: 64));
      for (var i = 0; i < 8; i++) {
        a.xorRM(r8 + i, Mem(rsp, disp: 56 - 8 * i));
      }
      a.addRI(rsp, 200);
    });
    void storeInts(X64 a) {
      a.movRM(rcx, const Mem(rsp, disp: 24));
      for (var i = 0; i < 8; i++) {
        a.movMR(Mem(rcx, disp: 8 * i), r8 + i);
      }
      a.movRM(rcx, const Mem(rsp, disp: 16));
    }

    void storeFloats(X64 a) {
      for (var i = 0; i < 4; i++) {
        a.movapdMR(Mem(rcx, disp: 16 * i), i);
      }
    }

    loopStore = _build((a) {
      storeInts(a);
      for (var i = 0; i < 4; i++) {
        a.xorpd(i, 4 + i);
      }
      storeFloats(a);
    });
    loopStoreHardAes = _build((a) {
      storeInts(a);
      for (var k = 4; k < 8; k++) {
        a.aesenc(0, k);
        a.aesdec(1, k);
        a.aesenc(2, k);
        a.aesdec(3, k);
      }
      storeFloats(a);
    });
    _buildEpilogue();
    _buildDatasetInit();
    sshashLoad = _build((a) {
      for (var i = 0; i < 8; i++) {
        a.xorRM(r8 + i, Mem(rbx, disp: 8 * i));
      }
    });
    sshashPrefetch = _build(_sshPrefetch);
    _buildSshInit();
  }

  static Uint8List _build(void Function(X64) f) {
    final a = X64();
    f(a);
    return Uint8List.fromList(a.bytes);
  }

  static void _sshPrefetch(X64 a) {
    a.andRI(rbx, _cacheMask); // 48 81 E3 imm32
    a.shlRI(rbx, 6);
    a.addRR(rbx, rdi);
    a.prefetchnta(const Mem(rbx));
  }

  void _buildPrologue(bool avx) {
    final a = X64();
    final mantissaMask = Label(), exp240 = Label(), scaleMask = Label();
    final imulRcpStore = Label(), loopBegin = Label();
    if (win64) {
      for (final r in const [rbx, rbp, rdi, rsi, r12, r13, r14, r15]) {
        a.push(r);
      }
      a.subRI(rsp, 80);
      for (var i = 0; i < 5; i++) {
        a.movdquMR(Mem(rsp, disp: 64 - 16 * i), 6 + i);
      }
      a.subRI(rsp, 80);
      for (var i = 0; i < 5; i++) {
        a.movdquMR(Mem(rsp, disp: 64 - 16 * i), 11 + i);
      }
      a.push(rdx); // MemoryRegisters*
      a.subRI(rsp, 8);
      a.stmxcsr(const Mem(rdx, disp: 20));
      a.ldmxcsr(const Mem(rdx, disp: 16));
      a.push(rcx); // RegisterFile*
      a.movRM(rbp, const Mem(rdx)); // mx, ma
      a.movRM(rdi, const Mem(rdx, disp: 8)); // dataset
      a.movRR(rsi, r8); // scratchpad
      a.movRR(rbx, r9); // iterations
    } else {
      for (final r in const [rbx, rbp, r12, r13, r14, r15]) {
        a.push(r);
      }
      a.push(rsi); // MemoryRegisters*
      a.subRI(rsp, 8);
      a.stmxcsr(const Mem(rsi, disp: 20));
      a.ldmxcsr(const Mem(rsi, disp: 16));
      a.movRR(rbx, rcx); // iterations
      a.push(rdi); // RegisterFile*
      a.movRR(rcx, rdi);
      a.movRM(rbp, const Mem(rsi));
      a.movRM(rdi, const Mem(rsi, disp: 8));
      a.movRR(rsi, rdx);
    }
    a.movRR(rax, rbp);
    a.rorRI(rbp, 32);
    for (var i = 0; i < 8; i++) {
      a.xorRR(r8 + i, r8 + i);
    }
    a.leaRM(rcx, const Mem(rcx, disp: 120));
    for (var i = 0; i < 4; i++) {
      a.movapdRM(8 + i, Mem(rcx, disp: 72 + 16 * i));
    }
    a.movapdRM(13, Mem.rip(mantissaMask));
    a.movapdRM(14, Mem.rip(exp240));
    a.movapdRM(15, Mem.rip(scaleMask));
    // randomx_program_prologue_first_load
    a.subRI(rsp, 248);
    a.movRR(rdx, rax);
    a.andRI32(rax, _spMask64);
    a.rorRI(rdx, 32);
    a.andRI32(rdx, _spMask64);
    if (avx) {
      a.vzeroupper();
    }
    a.movMI32(const Mem(rsp), 0x9FC0);
    a.movMI32(const Mem(rsp, disp: 4), 0xBFC0);
    a.movMI32(const Mem(rsp, disp: 8), 0xDFC0);
    a.movMI32(const Mem(rsp, disp: 12), 0xFFC0);
    a.movMI32(const Mem(rsp, disp: 32), -1);
    a.jmp(imulRcpStore);
    a.align(64);
    a.bind(mantissaMask);
    a.dbs(const [0, 0, 192, 255, 255, 255, 255, 0, 0, 0, 192, 255, 255, 255, 255, 0]);
    a.bind(exp240);
    exp240Offset = a.pos;
    a.dbs(List.filled(16, 0));
    a.bind(scaleMask);
    a.dbs(const [0, 0, 0, 0, 0, 0, 240, 128, 0, 0, 0, 0, 0, 0, 240, 128]);
    a.bind(imulRcpStore);
    imulRcpStoreOffset = a.pos;
    for (var i = 0; i < 16; i++) {
      a.movRI64(rcx, 0); // 48 B9 imm64
      a.push(rcx);
    }
    a.addRI(rsp, 128);
    a.jmp(loopBegin);
    a.align(64);
    a.bind(loopBegin);
    prologue = Uint8List.fromList(a.bytes);
  }

  void _buildEpilogue() {
    final a = X64();
    a.addRI(rsp, 248);
    a.pop(rcx); // RegisterFile*
    for (var i = 0; i < 8; i++) {
      a.movMR(Mem(rcx, disp: 8 * i), r8 + i);
    }
    for (var i = 0; i < 4; i++) {
      a.movdqaMR(Mem(rcx, disp: 64 + 16 * i), i);
    }
    a.leaRM(rcx, const Mem(rcx, disp: 64));
    for (var i = 0; i < 4; i++) {
      a.movdqaMR(Mem(rcx, disp: 64 + 16 * i), 4 + i);
    }
    a.addRI(rsp, 8);
    a.pop(rdx); // MemoryRegisters*
    a.stmxcsr(const Mem(rdx, disp: 16));
    a.ldmxcsr(const Mem(rdx, disp: 20));
    if (win64) {
      for (var i = 0; i < 5; i++) {
        a.movdquRM(15 - i, Mem(rsp, disp: 16 * i));
      }
      a.addRI(rsp, 80);
      for (var i = 0; i < 5; i++) {
        a.movdquRM(10 - i, Mem(rsp, disp: 16 * i));
      }
      a.addRI(rsp, 80);
      for (final r in const [r15, r14, r13, r12, rsi, rdi, rbp, rbx]) {
        a.pop(r);
      }
    } else {
      for (final r in const [r15, r14, r13, r12, rbp, rbx]) {
        a.pop(r);
      }
    }
    a.ret();
    epilogue = Uint8List.fromList(a.bytes);
  }

  void _buildDatasetInit() {
    final a = X64();
    for (final r in const [rbx, rbp, r12, r13, r14, r15]) {
      a.push(r);
    }
    if (win64) {
      a.push(rdi);
      a.push(rsi);
      a.movRM(rdi, const Mem(rcx)); // cache->memory
      a.movRR(rsi, rdx); // dataset
      a.movRR(rbp, r8); // block index
      a.push(r9); // end block index
    } else {
      a.movRM(rdi, const Mem(rdi));
      a.movRR(rbp, rdx);
      a.push(rcx);
    }
    final loop = Label();
    a.bind(loop);
    a.prefetchw(const Mem(rsi));
    a.movRR(rbx, rbp);
    a.db(0xE8);
    a.d32(32768 - (a.pos + 4)); // call the SuperscalarHash at code+32768
    for (var i = 0; i < 8; i++) {
      a.movMR(Mem(rsi, disp: 8 * i), r8 + i);
    }
    a.addRI(rbp, 1);
    a.addRI(rsi, 64);
    a.cmpRM(rbp, const Mem(rsp));
    a.jcc(2, loop, short: true); // jb
    a.pop(rax);
    if (win64) {
      a.pop(rsi);
      a.pop(rdi);
    }
    for (final r in const [r15, r14, r13, r12, rbp, rbx]) {
      a.pop(r);
    }
    a.ret();
    datasetInit = Uint8List.fromList(a.bytes);
  }

  void _buildSshInit() {
    final a = X64();
    final consts = List.generate(8, (_) => Label());
    final end = Label();
    a.leaRM(r8, const Mem(rbx, disp: 1));
    _sshPrefetch(a);
    a.imulRM(r8, Mem.rip(consts[0]));
    for (var i = 1; i < 8; i++) {
      a.movRM(r8 + i, Mem.rip(consts[i]));
      a.xorRR(r8 + i, r8);
    }
    a.jmp(end);
    a.align(64);
    const values = [
      6364136223846793005,
      -9148333072579190276, // 9298411001130361340
      -6381431487974942650, // 12065312585734608966
      -9140414860584924836, // 9306329213124626780
      5281919268842080866,
      -7910590639137690612, // 10536153434571861004
      3398623926847679864,
      -8897639553701190322, // 9549104520008361294
    ];
    for (var i = 0; i < 8; i++) {
      a.bind(consts[i]);
      a.d64(values[i]);
    }
    a.align(64);
    a.bind(end);
    sshashInit = Uint8List.fromList(a.bytes);
  }
}
