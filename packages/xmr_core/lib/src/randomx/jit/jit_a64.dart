import 'dart:ffi';
import 'dart:typed_data';

import '../config.dart';
import '../superscalar.dart';
import '../../util/u64.dart';
import 'asm_a64.dart';
import 'exec_memory.dart';
import 'jit_compiler.dart';

/// ARM64 RandomX JIT compiler: port of xmrig `jit_compiler_a64.cpp` and
/// `jit_compiler_a64_static.S` (BSD-3-Clause, Copyright (c) 2018-2019
/// tevador, Copyright (c) 2019 SChernykh, Copyright (c) 2019-2020 XMRig),
/// with tevador's ISUB_R 0x80000000 fix.
///
/// Register allocation (as in xmrig):
///   x0: RegisterFile*, then an IMUL_RCP literal; x1: MemoryRegisters*, then
///   the dataset; x2: scratchpad; x3: loop counter; x4-x7, x12-x15: r0-r7;
///   x8: FPCR bit-reversed; x9: mx/ma; x10: spMix1; x11, x21-x30: IMUL_RCP
///   literals; x16/x17: spAddr0/1; x19, x20: temporaries (x18 untouched).
///   v0-v15: 32-bit immediate literals; v16-v19: f0-3; v20-v23: e0-3;
///   v24-v27: a0-3; v28: temporary; v29: E and-mask; v30: E or-mask;
///   v31: scale mask.
///
/// Differences from xmrig: the caller's FPCR is saved and RandomX's rounding
/// mode is loaded from `MemoryRegisters` (+16, caller at +20), and the
/// epilogue writes the mode back and restores the caller's FPCR. There is no
/// soft-AES v2 path (CPUs without the crypto extension use the interpreter).

const List<int> _intRegMap = [4, 5, 6, 7, 12, 13, 14, 15];

// Instruction groups in reference order (as in jit_x64.dart).
final Uint8List _opcodeGroup = () {
  final t = Uint8List(256);
  var o = 0;
  for (var g = 0; g < rxFrequencies.length; g++) {
    for (var k = 0; k < rxFrequencies[g]; k++) {
      t[o++] = g;
    }
  }
  while (o < 256) {
    t[o++] = 29;
  }
  return t;
}();

// ARMv8 encodings used by the handlers (xmrig namespace ARMV8A).
const int _b = 0x14000000, _eor = 0xCA000000, _eor32 = 0x4A000000, _add = 0x8B000000, _sub = 0xCB000000;
const int _mul = 0x9B007C00, _umulh = 0x9BC07C00, _smulh = 0x9B407C00, _movz = 0xD2800000, _movn = 0x92800000;
const int _movk = 0xF2800000, _addImmLo = 0x91000000, _addImmHi = 0x91400000, _ldrLiteral = 0x58000000;
const int _ror = 0x9AC02C00, _rorImm = 0x93C00000, _movReg = 0xAA0003E0, _fadd = 0x4E60D400, _fsub = 0x4EE0D400;
const int _feor = 0x6E201C00, _fmul = 0x6E60DC00, _fdiv = 0x6E60FC00, _fsqrt = 0x6EE1F800;

const int _log2L1 = 14, _log2L2 = 18, _log2L3 = 21, _log2DatasetBase = 31, _log2CacheLines = 22;
const int _l3Mask = 0x1FFFF8;

/// Offsets of the static code, built once per isolate.
class A64Templates {
  late final Uint8List blob; // program + light path + init_dataset, CodeSize bytes
  late final int mainLoopBegin, prologueSize, imulRcpLiteralsEnd, vmInstructionsEnd;
  late final int cachelineAlignMask1, cachelineAlignMask2, updateSpMix1, v2FeMix, v1FeMix;
  late final int vmInstructionsEndLight, lightCachelineAlignMask, lightTweak, lightDatasetOffset;
  late final int endV1, endV2, endLightV1, endLightV2, initDataset;
  int get codeSize => blob.length;

  // randomx_calc_dataset_item_aarch64 pieces
  late final Uint8List calcPrologue, calcPrefetchTail, calcMix, calcStoreResult;

  A64Templates() {
    _buildBlob();
    _buildCalcItem();
  }

  static final A64Templates instance = A64Templates();

  void _buildBlob() {
    final a = A64();
    final mainLoop = A64Label(), literalV0 = A64Label(), vmInstrEnd = A64Label(), xorDatasetLine = A64Label();
    final v1Mix = A64Label(), feStore = A64Label(), calcItem = A64Label(), initLoop = A64Label();

    // ---- randomx_program_aarch64 --------------------------------------
    a.subImm(31, 31, 192);
    a.stp(16, 17, 31, 0);
    a.str(19, 31, 16);
    a.stp(20, 21, 31, 32);
    a.stp(22, 23, 31, 48);
    a.stp(24, 25, 31, 64);
    a.stp(26, 27, 31, 80);
    a.stp(28, 29, 31, 96);
    a.stp(8, 30, 31, 112);
    a.stpD(8, 9, 31, 128);
    a.stpD(10, 11, 31, 144);
    a.stpD(12, 13, 31, 160);
    a.stpD(14, 15, 31, 176);
    // ours: swap in RandomX's rounding mode, keep MemoryRegisters*
    a.mrsFpcr(19);
    a.strW(19, 1, 20);
    a.ldrW(19, 1, 16);
    a.msrFpcr(19);
    a.strPre(1, 31, -16);
    for (final r in const [4, 5, 6, 7, 12, 13, 14, 15]) {
      a.movXzr(r);
    }
    a.ldp(9, 1, 1, 0);
    a.movReg(10, 9);
    a.ldpQ(24, 25, 0, 192);
    a.ldpQ(26, 27, 0, 224);
    a.moviMantissaMask(29);
    a.ldrQ(30, 0, 64);
    a.movz(16, 0x80f0, hw: 3);
    a.dup2d(31, 16);
    a.mrsFpcr(8);
    a.rbit(8, 8);
    a.strPre(0, 31, -16);
    a.adr(30, literalV0);
    for (var i = 0; i < 8; i++) {
      a.ldpQ(2 * i, 2 * i + 1, 30, 32 * i);
    }
    a.ldp(0, 11, 30, -96);
    a.ldp(21, 22, 30, -80);
    a.ldp(23, 24, 30, -64);
    a.ldp(25, 26, 30, -48);
    a.ldp(27, 28, 30, -32);
    a.ldp(29, 30, 30, -16);

    a.bind(mainLoop);
    mainLoopBegin = a.pos;
    a.lsrImm(20, 10, 32);
    a.andW1(16, 10); // mask inserted by the JIT
    a.andW1(17, 20);
    a.addReg(16, 16, 2);
    a.addReg(17, 17, 2);
    for (var i = 0; i < 4; i++) {
      a.ldp(20, 19, 16, 16 * i);
      a.eorReg(_intRegMap[2 * i], _intRegMap[2 * i], 20);
      a.eorReg(_intRegMap[2 * i + 1], _intRegMap[2 * i + 1], 19);
    }
    for (var i = 0; i < 4; i++) {
      final lo = 16 + 2 * i, hi = 17 + 2 * i;
      a.ldrQ(hi, 17, 16 * i);
      a.sxtl(lo, hi);
      a.scvtf2d(lo, lo);
      a.sxtl2(hi, hi);
      a.scvtf2d(hi, hi);
    }
    for (var i = 20; i < 24; i++) {
      a.andV(i, i, 29);
    }
    for (var i = 20; i < 24; i++) {
      a.orrV(i, i, 30);
    }

    prologueSize = a.pos; // randomx_program_aarch64_vm_instructions
    a.zeros(6144 * 4);
    a.zeros(12 * 8); // literal_x0 .. literal_x30
    imulRcpLiteralsEnd = a.pos;
    a.bind(literalV0);
    a.zeros(16 * 16); // literal_v0 .. literal_v15

    a.bind(vmInstrEnd);
    vmInstructionsEnd = a.pos;
    a.lsrImm(10, 9, 32);
    a.eorReg(9, 9, 20);
    a.movReg32(20, 9);
    a.rorImm(9, 9, 32);
    cachelineAlignMask1 = a.pos;
    a.andX1(20, 20);
    a.addReg(20, 20, 1);
    a.prfmPldl2strm(20);
    cachelineAlignMask2 = a.pos;
    a.andX1(10, 10);
    a.addReg(10, 10, 1);
    a.bind(xorDatasetLine);
    for (var i = 0; i < 4; i++) {
      a.ldp(20, 19, 10, 16 * i);
      a.eorReg(_intRegMap[2 * i], _intRegMap[2 * i], 20);
      a.eorReg(_intRegMap[2 * i + 1], _intRegMap[2 * i + 1], 19);
    }
    updateSpMix1 = a.pos;
    a.eorReg(10, 0, 0); // replaced by eor x10, readReg0, readReg1
    a.stp(4, 5, 17, 0);
    a.stp(6, 7, 17, 16);
    a.stp(12, 13, 17, 32);
    a.stp(14, 15, 17, 48);
    v2FeMix = a.pos;
    a.b(v1Mix); // replaced by movi v28.4s, #0 for v2
    for (var e = 20; e < 24; e++) {
      a.aese(16, 28);
      a.aesd(17, 28);
      a.aese(18, 28);
      a.aesd(19, 28);
      a.aesmc(16, 16);
      a.aesimc(17, 17);
      a.aesmc(18, 18);
      a.aesimc(19, 19);
      for (var f = 16; f < 20; f++) {
        a.eorV(f, f, e);
      }
    }
    a.b(feStore);
    a.bind(v1Mix);
    v1FeMix = a.pos;
    for (var i = 0; i < 4; i++) {
      a.eorV(16 + i, 16 + i, 20 + i);
    }
    a.bind(feStore);
    a.stpQ(16, 17, 16, 0);
    a.stpQ(18, 19, 16, 32);
    a.subsImm(3, 3, 1);
    a.bne(mainLoop);
    a.ldrPost(0, 31, 16);
    a.stp(4, 5, 0, 0);
    a.stp(6, 7, 0, 16);
    a.stp(12, 13, 0, 32);
    a.stp(14, 15, 0, 48);
    a.stpQ(16, 17, 0, 64);
    a.stpQ(18, 19, 0, 96);
    a.stpQ(20, 21, 0, 128);
    a.stpQ(22, 23, 0, 160);
    // ours: store RandomX's rounding mode, restore the caller's FPCR
    a.ldrPost(1, 31, 16);
    a.mrsFpcr(19);
    a.strW(19, 1, 16);
    a.ldrW(19, 1, 20);
    a.msrFpcr(19);
    a.ldp(16, 17, 31, 0);
    a.ldr(19, 31, 16);
    a.ldp(20, 21, 31, 32);
    a.ldp(22, 23, 31, 48);
    a.ldp(24, 25, 31, 64);
    a.ldp(26, 27, 31, 80);
    a.ldp(28, 29, 31, 96);
    a.ldp(8, 30, 31, 112);
    a.ldpD(8, 9, 31, 128);
    a.ldpD(10, 11, 31, 144);
    a.ldpD(12, 13, 31, 160);
    a.ldpD(14, 15, 31, 176);
    a.addImm(31, 31, 192);
    a.ret();

    // ---- light mode: the dataset item is computed by calc_item --------
    vmInstructionsEndLight = a.pos;
    a.subImm(31, 31, 96);
    a.stp(0, 1, 31, 64);
    a.stp(2, 30, 31, 80);
    a.lsrImm(2, 9, 32);
    lightCachelineAlignMask = a.pos;
    a.andW1(2, 2);
    lightTweak = a.pos;
    a.eorReg(9, 9, 20);
    a.rorImm(9, 9, 32);
    a.movReg(0, 1);
    a.addImm(1, 31, 0); // mov x1, sp
    a.lsrImm(2, 2, 6);
    lightDatasetOffset = a.pos;
    a.addImm(2, 2, 0);
    a.addImm(2, 2, 0);
    a.bl(calcItem);
    a.addImm(10, 31, 0); // mov x10, sp
    a.ldp(0, 1, 31, 64);
    a.ldp(2, 30, 31, 80);
    a.addImm(31, 31, 96);
    a.b(xorDatasetLine);

    endV1 = a.pos;
    a.lsrImm(10, 9, 32);
    a.eorReg(9, 9, 20);
    a.movReg32(20, 9);
    a.rorImm(9, 9, 32);
    endV2 = a.pos;
    a.lsrImm(10, 9, 32);
    a.rorImm(9, 9, 32);
    a.eorReg(9, 9, 20);
    a.movReg32(20, 9);
    endLightV1 = a.pos;
    a.eorReg(9, 9, 20);
    a.rorImm(9, 9, 32);
    endLightV2 = a.pos;
    a.rorImm(9, 9, 32);
    a.eorReg(9, 9, 20);

    // ---- randomx_init_dataset_aarch64(cache*, dataset, start, end) ----
    initDataset = a.pos;
    a.stpPre(20, 30, 31, -16);
    a.ldr(0, 0, 0);
    a.bind(initLoop);
    a.bl(calcItem);
    a.addImm(1, 1, 64);
    a.addImm(2, 2, 1);
    a.cmpReg(2, 3);
    a.bne(initLoop);
    a.ldpPost(20, 30, 31, 16);
    a.ret();

    // The generated calc_dataset_item code starts here (CodeSize).
    a.bind(calcItem);
    blob = Uint8List.fromList(a.bytes);
  }

  void _buildCalcItem() {
    // Prologue: x0 = cache memory, x1 = output, x2 = item number.
    final a = A64();
    final consts = A64Label(), prefetch = A64Label();
    a.subImm(31, 31, 112);
    for (var i = 0; i < 7; i++) {
      a.stp(2 * i, 2 * i + 1, 31, 16 * i);
    }
    a.adr(7, consts);
    a.ldp(12, 13, 7, 0);
    a.ldp(8, 9, 31, 0);
    a.movReg(10, 2);
    a.madd(0, 2, 12, 12);
    a.eorReg(1, 0, 13);
    a.ldp(12, 13, 7, 16);
    a.eorReg(2, 0, 12);
    a.eorReg(3, 0, 13);
    a.ldp(12, 13, 7, 32);
    a.eorReg(4, 0, 12);
    a.eorReg(5, 0, 13);
    a.ldp(12, 13, 7, 48);
    a.eorReg(6, 0, 12);
    a.eorReg(7, 0, 13);
    a.b(prefetch);
    a.bind(consts);
    a.d64(superscalarMul0);
    for (var i = 1; i < 8; i++) {
      a.d64(superscalarAdd[i]);
    }
    a.bind(prefetch);
    calcPrologue = Uint8List.fromList(a.bytes);

    final p = A64();
    p.addReg(11, 8, 11, lsl: 6);
    p.prfmPldl2strm(11);
    calcPrefetchTail = Uint8List.fromList(p.bytes);

    final m = A64();
    for (var i = 0; i < 4; i++) {
      m.ldp(12, 13, 11, 16 * i);
      m.eorReg(2 * i, 2 * i, 12);
      m.eorReg(2 * i + 1, 2 * i + 1, 13);
    }
    calcMix = Uint8List.fromList(m.bytes);

    final s = A64();
    for (var i = 0; i < 4; i++) {
      s.stp(2 * i, 2 * i + 1, 9, 16 * i);
    }
    for (var i = 0; i < 7; i++) {
      s.ldp(2 * i, 2 * i + 1, 31, 16 * i);
    }
    s.addImm(31, 31, 112);
    s.ret();
    calcStoreResult = Uint8List.fromList(s.bytes);
  }
}

class JitA64 implements RandomXJitCompiler {
  final A64Templates t;
  final ExecMemory mem;
  late final Uint8List _bytes = mem.bytes;
  late final ByteData _bd = ByteData.sublistView(_bytes);

  @override
  bool v2 = false;

  int _literalPos = 0;
  int _num32bitLiterals = 0;
  final Int32List _regChangedOffset = Int32List(8);

  JitA64({A64Templates? templates})
      : t = templates ?? A64Templates.instance,
        mem = ExecMemory.allocate(_calcSize((templates ?? A64Templates.instance))) {
    installArm64CacheFlush();
    _bytes.setRange(0, t.codeSize, t.blob);
    mem.executable(offset: 0, length: t.codeSize);
  }

  static int _calcSize(A64Templates t) =>
      t.codeSize +
      t.calcPrologue.length +
      rxCacheAccesses * (4 + t.calcPrefetchTail.length + 4 + (rxSuperscalarMaxSize + 2) * 16 + t.calcMix.length + 4) +
      t.calcStoreResult.length +
      4096;

  @override
  int get programAddress => mem.address;

  @override
  int get datasetInitAddress => mem.address + t.initDataset;

  @override
  int get initialFpControl => 0; // round to nearest, IEEE defaults

  @override
  bool get eMaskInRegisterFile => true;

  @override
  void free() => mem.free();

  void _w32(int pos, int v) => _bd.setUint32(pos, v & 0xffffffff, Endian.little);

  int _emit32(int pos, int v) {
    _w32(pos, v);
    return pos + 4;
  }

  // ---- program ------------------------------------------------------------

  void _mainLoopMasks() {
    var p = t.mainLoopBegin + 4;
    final mask = (_log2L3 - 7) << 10;
    p = _emit32(p, 0x121A0000 | 16 | (10 << 5) | mask); // and w16, w10, ScratchpadL3Mask64
    _emit32(p, 0x121A0000 | 17 | (20 << 5) | mask); // and w17, w20, ScratchpadL3Mask64
  }

  int _body(Uint8List prog) {
    var codePos = t.prologueSize;
    _literalPos = t.imulRcpLiteralsEnd;
    _num32bitLiterals = 0;
    for (var i = 0; i < 8; i++) {
      _regChangedOffset[i] = codePos;
    }
    final n = v2 ? rxProgramSizeV2 : rxProgramSizeV1;
    for (var i = 0; i < n; i++) {
      final o = 128 + 8 * i;
      final imm = prog[o + 4] | (prog[o + 5] << 8) | (prog[o + 6] << 16) | (prog[o + 7] << 24);
      codePos = _instruction(codePos, _opcodeGroup[prog[o]], prog[o + 1] & 7, prog[o + 2] & 7, prog[o + 3], imm);
    }
    return codePos;
  }

  void _feMix() {
    if (v2) {
      _emit32(t.v2FeMix, 0x4F00041C); // movi v28.4s, #0: fall into the AES mix
    } else {
      _emit32(t.v2FeMix, _b | ((t.v1FeMix - t.v2FeMix) ~/ 4));
    }
  }

  @override
  void generateProgram(Uint8List prog, int eMask0, int eMask1, List<int> readReg) {
    mem.writable();
    _mainLoopMasks();
    var codePos = _body(prog);
    codePos = _emit32(codePos, _eor32 | 20 | (_intRegMap[readReg[2]] << 5) | (_intRegMap[readReg[3]] << 16));
    codePos = _emit32(codePos, _b | (((t.vmInstructionsEnd - codePos) ~/ 4) & 0x3FFFFFF));
    final end = codePos;
    final mask = (_log2DatasetBase - 7) << 10;
    _emit32(t.cachelineAlignMask1, 0x121A0000 | 20 | (20 << 5) | mask);
    _emit32(t.cachelineAlignMask2, 0x121A0000 | 10 | (10 << 5) | mask);
    _emit32(t.updateSpMix1, _eor | 10 | (_intRegMap[readReg[0]] << 5) | (_intRegMap[readReg[1]] << 16));
    _feMix();
    _bytes.setRange(t.vmInstructionsEnd, t.vmInstructionsEnd + 16, t.blob, v2 ? t.endV2 : t.endV1);
    mem.executable(offset: t.mainLoopBegin, length: t.codeSize - t.mainLoopBegin);
    assert(end < t.imulRcpLiteralsEnd);
  }

  @override
  void generateProgramLight(Uint8List prog, int eMask0, int eMask1, List<int> readReg, int datasetOffset) {
    mem.writable();
    _mainLoopMasks();
    var codePos = _body(prog);
    codePos = _emit32(codePos, _eor32 | 20 | (_intRegMap[readReg[2]] << 5) | (_intRegMap[readReg[3]] << 16));
    _bytes.setRange(t.lightTweak, t.lightTweak + 8, t.blob, v2 ? t.endLightV2 : t.endLightV1);
    codePos = _emit32(codePos, _b | (((t.vmInstructionsEndLight - codePos) ~/ 4) & 0x3FFFFFF));
    _emit32(t.lightCachelineAlignMask, 0x121A0000 | 2 | (2 << 5) | ((_log2DatasetBase - 7) << 10));
    _emit32(t.updateSpMix1, _eor | 10 | (_intRegMap[readReg[0]] << 5) | (_intRegMap[readReg[1]] << 16));
    _feMix();
    final items = datasetOffset ~/ cacheLineSize;
    final p = _emit32(t.lightDatasetOffset, _addImmLo | 2 | (2 << 5) | ((items & 0xFFF) << 10));
    _emit32(p, _addImmHi | 2 | (2 << 5) | ((items >> 12) << 10));
    mem.executable(offset: t.mainLoopBegin, length: t.codeSize - t.mainLoopBegin);
  }

  // ---- immediates -----------------------------------------------------------

  int _emitMovImmediate(int k, int dst, int imm) {
    imm &= 0xffffffff;
    final negative = imm >= 0x80000000;
    if (imm < (1 << 16)) {
      return _emit32(k, _movz | dst | (imm << 5));
    }
    if (_num32bitLiterals < 64) {
      final lane = ((_num32bitLiterals ~/ 4) << 5) | ((_num32bitLiterals % 4) << 19);
      k = _emit32(k, (negative ? 0x4E042C00 : 0x0E043C00) | dst | lane); // smov / umov dst, vN.s[M]
      _w32(t.imulRcpLiteralsEnd + 4 * _num32bitLiterals, imm);
      ++_num32bitLiterals;
      return k;
    }
    if (negative) {
      k = _emit32(k, _movn | dst | (1 << 21) | ((((~imm) & 0xffffffff) >> 16) << 5));
    } else {
      k = _emit32(k, _movz | dst | (1 << 21) | ((imm >> 16) << 5));
    }
    return _emit32(k, _movk | dst | ((imm & 0xFFFF) << 5));
  }

  int _emitAddImmediate(int k, int dst, int src, int imm) {
    imm &= 0xffffffff;
    if (imm < (1 << 24)) {
      final lo = imm & 0xFFF, hi = imm >> 12;
      if (lo != 0 && hi != 0) {
        k = _emit32(k, _addImmLo | dst | (src << 5) | (lo << 10));
        return _emit32(k, _addImmHi | dst | (dst << 5) | (hi << 10));
      } else if (lo != 0) {
        return _emit32(k, _addImmLo | dst | (src << 5) | (lo << 10));
      }
      return _emit32(k, _addImmHi | dst | (src << 5) | (hi << 10));
    }
    const tmp = 20;
    k = _emitMovImmediate(k, tmp, imm);
    return _emit32(k, _add | dst | (src << 5) | (tmp << 16));
  }

  int _emitMemLoad(int k, int tmp, int dst, int src, int mod, int imm) {
    if (src != dst) {
      imm &= (mod & 3) != 0 ? (rxScratchpadL1 - 1) : (rxScratchpadL2 - 1);
      var tInstr = 0x927d0000 | tmp | (tmp << 5);
      if (imm != 0) {
        k = _emitAddImmediate(k, tmp, src, imm);
      } else {
        tInstr = 0x927d0000 | tmp | (src << 5);
      }
      k = _emit32(k, tInstr | ((((mod & 3) != 0 ? _log2L1 : _log2L2) - 4) << 10));
      return _emit32(k, 0xf8606840 | tmp | (tmp << 16)); // ldr tmp, [x2, tmp]
    }
    imm = (imm & _l3Mask) >> 3;
    if (imm != 0) {
      k = _emitMovImmediate(k, tmp, imm);
      return _emit32(k, 0xf8607840 | tmp | (tmp << 16)); // ldr tmp, [x2, tmp, lsl 3]
    }
    return _emit32(k, 0xf9400040 | tmp); // ldr tmp, [x2]
  }

  int _emitMemLoadFp(int k, int src, int mod, int imm) {
    const tmpFp = 28, tmp = 19;
    imm &= (mod & 3) != 0 ? (rxScratchpadL1 - 1) : (rxScratchpadL2 - 1);
    var tInstr = 0x927d0000 | tmp | (tmp << 5);
    if (imm != 0) {
      k = _emitAddImmediate(k, tmp, src, imm);
    } else {
      tInstr = 0x927d0000 | tmp | (src << 5);
    }
    k = _emit32(k, tInstr | ((((mod & 3) != 0 ? _log2L1 : _log2L2) - 4) << 10));
    k = _emit32(k, 0x3ce06800 | tmpFp | (2 << 5) | (tmp << 16)); // ldr q28, [x2, x19]
    k = _emit32(k, 0x0f20a400 | tmpFp | (tmpFp << 5)); // sxtl v28.2d, v28.2s
    return _emit32(k, 0x4E61D800 | tmpFp | (tmpFp << 5)); // scvtf v28.2d, v28.2d
  }

  // ---- handlers -------------------------------------------------------------

  int _instruction(int k, int group, int idst, int isrc, int mod, int imm) {
    final src = _intRegMap[isrc], dst = _intRegMap[idst];
    const tmp = 20;
    switch (group) {
      case 0: // IADD_RS
        k = _emit32(k, _add | dst | (dst << 5) | (((mod >> 2) & 3) << 10) | (src << 16));
        if (idst == registerNeedsDisplacement) k = _emitAddImmediate(k, dst, dst, imm);
        _regChangedOffset[idst] = k;
      case 1: // IADD_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _add | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 2: // ISUB_R
        if (src != dst) {
          k = _emit32(k, _sub | dst | (dst << 5) | (src << 16));
        } else if (imm == 0x80000000) {
          // tevador fix: -(int32)0x80000000 is +2^31, not a sign-extended add.
          k = _emit32(k, _movz | tmp | (1 << 21) | (0x8000 << 5));
          k = _emit32(k, _add | dst | (dst << 5) | (tmp << 16));
        } else {
          k = _emitAddImmediate(k, dst, dst, -imm);
        }
        _regChangedOffset[idst] = k;
      case 3: // ISUB_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _sub | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 4: // IMUL_R
        var s = src;
        if (src == dst) {
          s = tmp;
          k = _emitMovImmediate(k, tmp, imm);
        }
        k = _emit32(k, _mul | dst | (dst << 5) | (s << 16));
        _regChangedOffset[idst] = k;
      case 5: // IMUL_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _mul | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 6: // IMULH_R
        k = _emit32(k, _umulh | dst | (dst << 5) | (src << 16));
        _regChangedOffset[idst] = k;
      case 7: // IMULH_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _umulh | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 8: // ISMULH_R
        k = _emit32(k, _smulh | dst | (dst << 5) | (src << 16));
        _regChangedOffset[idst] = k;
      case 9: // ISMULH_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _smulh | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 10: // IMUL_RCP
        if (isZeroOrPowerOf2(imm)) return k;
        final literalId = (t.imulRcpLiteralsEnd - _literalPos) ~/ 8;
        _literalPos -= 8;
        _bd.setInt64(_literalPos, randomxReciprocal(imm), Endian.little);
        if (literalId < 12) {
          const literalRegs = [30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 11, 0];
          k = _emit32(k, _mul | dst | (dst << 5) | (literalRegs[literalId] << 16));
        } else {
          final offset = (_literalPos - k) ~/ 4;
          k = _emit32(k, _ldrLiteral | tmp | ((offset & 0x7FFFF) << 5));
          k = _emit32(k, _mul | dst | (dst << 5) | (tmp << 16));
        }
        _regChangedOffset[idst] = k;
      case 11: // INEG_R
        k = _emit32(k, _sub | dst | (31 << 5) | (dst << 16));
        _regChangedOffset[idst] = k;
      case 12: // IXOR_R
        var s = src;
        if (src == dst) {
          s = tmp;
          k = _emitMovImmediate(k, tmp, imm);
        }
        k = _emit32(k, _eor | dst | (dst << 5) | (s << 16));
        _regChangedOffset[idst] = k;
      case 13: // IXOR_M
        k = _emitMemLoad(k, tmp, dst, src, mod, imm);
        k = _emit32(k, _eor | dst | (dst << 5) | (tmp << 16));
        _regChangedOffset[idst] = k;
      case 14: // IROR_R
        if (src != dst) {
          k = _emit32(k, _ror | dst | (dst << 5) | (src << 16));
        } else if ((imm & 63) != 0) {
          k = _emit32(k, _rorImm | dst | (dst << 5) | ((imm & 63) << 10) | (dst << 16));
        }
        _regChangedOffset[idst] = k;
      case 15: // IROL_R
        if (src != dst) {
          k = _emit32(k, _sub | tmp | (31 << 5) | (src << 16));
          k = _emit32(k, _ror | dst | (dst << 5) | (tmp << 16));
        } else if ((imm & 63) != 0) {
          k = _emit32(k, _rorImm | dst | (dst << 5) | (((-imm) & 63) << 10) | (dst << 16));
        }
        _regChangedOffset[idst] = k;
      case 16: // ISWAP_R
        if (src == dst) return k;
        k = _emit32(k, _movReg | tmp | (dst << 16));
        k = _emit32(k, _movReg | dst | (src << 16));
        k = _emit32(k, _movReg | src | (tmp << 16));
        _regChangedOffset[isrc] = k;
        _regChangedOffset[idst] = k;
      case 17: // FSWAP_R
        final d = idst + 16;
        k = _emit32(k, 0x6e004000 | d | (d << 5) | (d << 16)); // ext d.16b, d.16b, d.16b, #8
      case 18: // FADD_R
        final d = (idst & 3) + 16, s = (isrc & 3) + 24;
        k = _emit32(k, _fadd | d | (d << 5) | (s << 16));
      case 19: // FADD_M
        final d = (idst & 3) + 16;
        k = _emitMemLoadFp(k, src, mod, imm);
        k = _emit32(k, _fadd | d | (d << 5) | (28 << 16));
      case 20: // FSUB_R
        final d = (idst & 3) + 16, s = (isrc & 3) + 24;
        k = _emit32(k, _fsub | d | (d << 5) | (s << 16));
      case 21: // FSUB_M
        final d = (idst & 3) + 16;
        k = _emitMemLoadFp(k, src, mod, imm);
        k = _emit32(k, _fsub | d | (d << 5) | (28 << 16));
      case 22: // FSCAL_R
        final d = (idst & 3) + 16;
        k = _emit32(k, _feor | d | (d << 5) | (31 << 16));
      case 23: // FMUL_R
        final d = (idst & 3) + 20, s = (isrc & 3) + 24;
        k = _emit32(k, _fmul | d | (d << 5) | (s << 16));
      case 24: // FDIV_M
        final d = (idst & 3) + 20;
        k = _emitMemLoadFp(k, src, mod, imm);
        k = _emit32(k, 0x4E201C00 | 28 | (28 << 5) | (29 << 16)); // and v28, v28, v29
        k = _emit32(k, 0x4EA01C00 | 28 | (28 << 5) | (30 << 16)); // orr v28, v28, v30
        k = _emit32(k, _fdiv | d | (d << 5) | (28 << 16));
      case 25: // FSQRT_R
        final d = (idst & 3) + 20;
        k = _emit32(k, _fsqrt | d | (d << 5));
      case 26: // CBRANCH
        final modCond = mod >> 4;
        final shift = modCond + 8;
        final cimm = ((imm | (1 << shift)) & ~(1 << (shift - 1))) & 0xffffffff;
        k = _emitAddImmediate(k, dst, dst, cimm);
        k = _emit32(k, (0xF2781C1F - (modCond << 16)) | (dst << 5)); // tst dst, mask
        final offset = ((_regChangedOffset[idst] - k) >> 2) & 0x7FFFF;
        k = _emit32(k, 0x54000000 | (offset << 5)); // b.eq target
        for (var i = 0; i < 8; i++) {
          _regChangedOffset[i] = k;
        }
      case 27: // CFROUND
        k = _emit32(k, _rorImm | tmp | (src << 5) | ((imm & 63) << 10) | (src << 16));
        if (v2) {
          k = _emit32(k, 0xF27E0E9F); // tst x20, 60
          k = _emit32(k, 0x54000081); // b.ne next
        }
        k = _emit32(k, 0xB3580400 | 8 | (tmp << 5)); // bfi x8, x20, 40, 2
        k = _emit32(k, 0xDAC00000 | tmp | (8 << 5)); // rbit x20, x8
        k = _emit32(k, 0xD51B4400 | tmp); // msr fpcr, x20
      case 28: // ISTORE
        var simm = imm;
        final l3 = (mod >> 4) >= storeL3Condition;
        if (!l3) {
          simm &= (mod & 3) != 0 ? (rxScratchpadL1 - 1) : (rxScratchpadL2 - 1);
        } else {
          simm &= rxScratchpadL3 - 1;
        }
        var tInstr = 0x927d0000 | tmp | (tmp << 5);
        if (simm != 0) {
          k = _emitAddImmediate(k, tmp, dst, simm);
        } else {
          tInstr = 0x927d0000 | tmp | (dst << 5);
        }
        final log2 = l3 ? _log2L3 : ((mod & 3) != 0 ? _log2L1 : _log2L2);
        k = _emit32(k, tInstr | ((log2 - 4) << 10));
        k = _emit32(k, 0xF8206840 | src | (tmp << 16)); // str src, [x2, x20]
      default: // NOP
        break;
    }
    return k;
  }

  // ---- SuperscalarHash --------------------------------------------------------

  @override
  void generateSuperscalarHash(List<SuperscalarProgram> programs) {
    mem.writable();
    var codePos = t.codeSize;
    _bytes.setRange(codePos, codePos + t.calcPrologue.length, t.calcPrologue);
    codePos += t.calcPrologue.length;
    _num32bitLiterals = 64; // no vector literals here: plain mov immediates
    const tmp = 12;
    for (var i = 0; i < programs.length; i++) {
      // and x11, x10, CacheSize / CacheLineSize - 1
      codePos = _emit32(codePos, 0x92400000 | 11 | (10 << 5) | ((_log2CacheLines - 1) << 10));
      _bytes.setRange(codePos, codePos + t.calcPrefetchTail.length, t.calcPrefetchTail);
      codePos += t.calcPrefetchTail.length;
      final prog = programs[i];
      final jmpPos = codePos;
      codePos += 4;
      for (var j = 0; j < prog.size; j++) {
        if (prog.rawOpcode[j] == 13) {
          _bd.setInt64(codePos, randomxReciprocal(prog.rawImm32[j]), Endian.little);
          codePos += 8;
        }
      }
      var literalPos = jmpPos;
      literalPos = _emit32(literalPos, _b | ((codePos - jmpPos) ~/ 4)); // jump over the literal pool
      for (var j = 0; j < prog.size; j++) {
        final dst = prog.rawDst[j], src = prog.rawSrc[j], imm = prog.rawImm32[j];
        switch (prog.rawOpcode[j]) {
          case 0: // ISUB_R
            codePos = _emit32(codePos, _sub | dst | (dst << 5) | (src << 16));
          case 1: // IXOR_R
            codePos = _emit32(codePos, _eor | dst | (dst << 5) | (src << 16));
          case 2: // IADD_RS
            codePos = _emit32(codePos, _add | dst | (dst << 5) | (((prog.rawMod[j] >> 2) & 3) << 10) | (src << 16));
          case 3: // IMUL_R
            codePos = _emit32(codePos, _mul | dst | (dst << 5) | (src << 16));
          case 4: // IROR_C
            codePos = _emit32(codePos, _rorImm | dst | (dst << 5) | ((imm & 63) << 10) | (dst << 16));
          case 5 || 7 || 9: // IADD_C7/8/9
            codePos = _emitAddImmediate(codePos, dst, dst, imm);
          case 6 || 8 || 10: // IXOR_C7/8/9
            codePos = _emitMovImmediate(codePos, tmp, imm);
            codePos = _emit32(codePos, _eor | dst | (dst << 5) | (tmp << 16));
          case 11: // IMULH_R
            codePos = _emit32(codePos, _umulh | dst | (dst << 5) | (src << 16));
          case 12: // ISMULH_R
            codePos = _emit32(codePos, _smulh | dst | (dst << 5) | (src << 16));
          case 13: // IMUL_RCP
            final offset = ((literalPos - codePos) ~/ 4) & 0x7FFFF;
            literalPos += 8;
            codePos = _emit32(codePos, _ldrLiteral | tmp | (offset << 5));
            codePos = _emit32(codePos, _mul | dst | (dst << 5) | (tmp << 16));
        }
      }
      _bytes.setRange(codePos, codePos + t.calcMix.length, t.calcMix);
      codePos += t.calcMix.length;
      codePos = _emit32(codePos, _movReg | 10 | (prog.addressRegister << 16)); // registerValue
    }
    _bytes.setRange(codePos, codePos + t.calcStoreResult.length, t.calcStoreResult);
    codePos += t.calcStoreResult.length;
    mem.executable(offset: t.codeSize, length: codePos - t.codeSize);
  }

  /// The init loop is part of the static code; nothing to generate.
  @override
  void generateDatasetInitCode() {}
}

ExecMemory? _flushMem;

/// Installs a self-emitted instruction cache flush (dc cvau / ic ivau over
/// the cache lines reported by CTR_EL0) for Linux/Android, where libc may
/// not export `__clear_cache`. The routine lives on fresh pages, which the
/// kernel makes coherent when they are first mapped.
void installArm64CacheFlush() {
  if (_flushMem != null || arm64CacheFlushFallback != null || !ExecMemory.isArm64) return;
  final a = A64();
  final loop1 = A64Label(), loop2 = A64Label();
  a.w(0xD53B0023); // mrs x3, ctr_el0
  a.w(0xD3400000 | (16 << 16) | (19 << 10) | (3 << 5) | 4); // ubfx x4, x3, #16, #4 (DminLine)
  a.w(0x92400000 | (3 << 10) | (3 << 5) | 5); // and x5, x3, #0xf (IminLine)
  a.movz(6, 4);
  a.w(0x9AC02000 | (4 << 16) | (6 << 5) | 7); // lslv x7, x6, x4: data line bytes
  a.w(0x9AC02000 | (5 << 16) | (6 << 5) | 8); // lslv x8, x6, x5: instruction line bytes
  a.addReg(1, 0, 1); // end
  a.subImm(9, 7, 1);
  a.w(0x8A200000 | (9 << 16) | (0 << 5) | 10); // bic x10, x0, x9
  a.bind(loop1);
  a.w(0xD50B7B20 | 10); // dc cvau, x10
  a.addReg(10, 10, 7);
  a.cmpReg(10, 1);
  a.blo(loop1);
  a.w(0xD5033B9F); // dsb ish
  a.subImm(9, 8, 1);
  a.w(0x8A200000 | (9 << 16) | (0 << 5) | 10); // bic x10, x0, x9
  a.bind(loop2);
  a.w(0xD50B7520 | 10); // ic ivau, x10
  a.addReg(10, 10, 8);
  a.cmpReg(10, 1);
  a.blo(loop2);
  a.w(0xD5033B9F); // dsb ish
  a.w(0xD5033FDF); // isb
  a.ret();
  final m = ExecMemory.allocate(4096);
  m.bytes.setRange(0, a.pos, a.bytes);
  m.executable(); // no flush needed yet: fresh pages, first execution
  _flushMem = m;
  final f = Pointer<NativeFunction<Void Function(IntPtr, IntPtr)>>.fromAddress(m.address)
      .asFunction<void Function(int, int)>();
  arm64CacheFlushFallback = f;
}
