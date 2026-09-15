import 'dart:typed_data';

import '../config.dart';
import '../superscalar.dart';
import '../../util/u64.dart';
import 'cpu_features.dart';
import 'exec_memory.dart';
import 'jit_compiler.dart';
import 'x64_templates.dart';

/// x86-64 RandomX JIT compiler: port of xmrig `jit_compiler_x86.cpp`
/// (BSD-3-Clause, Copyright (c) 2018-2020 tevador, Copyright (c) 2019-2021
/// SChernykh, Copyright (c) 2019-2021 XMRig). Instruction handlers write the
/// same bytes as xmrig.
///
/// Register allocation (as in xmrig):
///   rax, rcx, rdx: temporaries; rbx: iteration counter; rsi: scratchpad;
///   rdi: dataset (cache memory in light mode); rbp: ma/mx; r8..r15: r0..r7;
///   xmm0..3: f0..3; xmm4..7: e0..3; xmm8..11: a0..3; xmm12: temporary;
///   xmm13: E and-mask; xmm14: E or-mask; xmm15: scale mask.

const int jitCodeSize = 64 * 1024;
const int _superScalarHashOffset = 32768;

// Instruction groups in reference order (RandomX InstructionType).
const int _gIaddRs = 0, _gIaddM = 1, _gIsubR = 2, _gIsubM = 3, _gImulR = 4, _gImulM = 5, _gImulhR = 6;
const int _gImulhM = 7, _gIsmulhR = 8, _gIsmulhM = 9, _gImulRcp = 10, _gInegR = 11, _gIxorR = 12;
const int _gIxorM = 13, _gIrorR = 14, _gIrolR = 15, _gIswapR = 16, _gFswapR = 17, _gFaddR = 18;
const int _gFaddM = 19, _gFsubR = 20, _gFsubM = 21, _gFscalR = 22, _gFmulR = 23, _gFdivM = 24;
const int _gFsqrtR = 25, _gCbranch = 26, _gCfround = 27, _gIstore = 28;

final Uint8List _opcodeGroup = () {
  final t = Uint8List(256);
  var o = 0;
  for (var g = 0; g < rxFrequencies.length; g++) {
    for (var k = 0; k < rxFrequencies[g]; k++) {
      t[o++] = g;
    }
  }
  while (o < 256) {
    t[o++] = 29; // NOP
  }
  return t;
}();

const List<List<int>> _nopx = [
  [0x90],
  [0x66, 0x90],
  [0x66, 0x66, 0x90],
  [0x0F, 0x1F, 0x40, 0x00],
  [0x0F, 0x1F, 0x44, 0x00, 0x00],
  [0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00],
  [0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00],
  [0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00],
  [0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00],
];
const List<int> _nop13 = [0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x1F, 0x44, 0x00, 0x00];
const List<int> _nop14 = [0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00];
const List<int> _nop25 = [
  0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00
];
const List<int> _nop26 = [
  0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00
];

const int _l3Mask = 0x1FFFF8; // ScratchpadL3Mask
const List<int> _addressMask = [0x3FFF8, 0x3FF8, 0x3FF8, 0x3FF8]; // [L2, L1, L1, L1]
const int _conditionMask = 0xFF << 8;
const int _jumpOffset = 8;

X64Templates? _templates;

X64Templates get x64Templates => _templates ??= X64Templates(avx: CpuFeatures.current.avx);

class JitX64 implements RandomXJitCompiler {
  final CpuFeatures cpu;
  final X64Templates t;
  final ExecMemory mem;

  /// Offset of the code base inside [mem] (xmrig shifts it per VM so threads
  /// use different cache sets).
  final int base;
  late final Uint8List _bytes = mem.bytes;
  late final ByteData _bd = ByteData.sublistView(_bytes);

  final bool amd, bmi2, jccErratum, hasAes;
  @override
  bool v2 = false;

  late final int prologueSize = t.prologue.length;
  late final int epilogueOffset = (jitCodeSize - t.epilogue.length) & ~63;
  late final int codePosFirst = prologueSize + t.loopLoad.length;

  int codePos = 0;
  final Int32List _registerUsage = Int32List(8);
  int _prevCfround = -1, _prevFpOperation = -1;
  int _imulRcpStorage = 0, _imulRcpUsed = 0;

  JitX64({int codeOffsetIndex = 0, CpuFeatures? cpu, X64Templates? templates})
      : cpu = cpu ?? CpuFeatures.current,
        t = templates ?? x64Templates,
        mem = ExecMemory.allocate(jitCodeSize * 2),
        base = (codeOffsetIndex * 59 * 64) % jitCodeSize,
        amd = (cpu ?? CpuFeatures.current).isAmd,
        bmi2 = (cpu ?? CpuFeatures.current).bmi2,
        jccErratum = (cpu ?? CpuFeatures.current).jccErratum,
        hasAes = (cpu ?? CpuFeatures.current).aes {
    _copy(0, t.prologue);
    _copy(prologueSize, t.loopLoad);
    _copy(epilogueOffset, t.epilogue);
  }

  /// Address of the generated program function.
  @override
  int get programAddress => mem.address + base;

  /// Address of the dataset init function ([generateDatasetInitCode]).
  @override
  int get datasetInitAddress => mem.address + base;

  @override
  int get initialFpControl => 0x9FC0; // MXCSR: round to nearest, exceptions masked

  @override
  bool get eMaskInRegisterFile => false;

  @override
  void free() => mem.free();

  // ---- byte helpers (positions are relative to the code base) ----------

  void _copy(int pos, List<int> src) => _bytes.setRange(base + pos, base + pos + src.length, src);
  void _w32(int pos, int v) => _bd.setUint32(base + pos, v & 0xffffffff, Endian.little);
  void _w64(int pos, int v) => _bd.setInt64(base + pos, v, Endian.little);
  int _r32(int pos) => _bd.getUint32(base + pos, Endian.little);

  void _emit32(int v) {
    _w32(codePos, v);
    codePos += 4;
  }

  void _emit64(int v) {
    _w64(codePos, v);
    codePos += 8;
  }

  void _emitByte(int v) => _bytes[base + codePos++] = v & 0xff;

  void _emit(List<int> b) {
    _copy(codePos, b);
    codePos += b.length;
  }

  // ---- program generation -----------------------------------------------

  /// Writes the program in [prog] (entropy then instructions, as produced by
  /// AesGenerator4R) for full mode. [eMask] is the E or-mask pair and
  /// [readReg] the four address registers.
  @override
  void generateProgram(Uint8List prog, int eMask0, int eMask1, List<int> readReg) {
    mem.writable();
    _generateProgramPrologue(prog, eMask0, eMask1, readReg);
    _emit(v2 ? t.readDatasetV2 : t.readDataset);
    _generateProgramEpilogue(readReg);
    mem.executable();
  }

  /// Light mode: dataset items are computed by the SuperscalarHash code at
  /// code+32768 ([generateSuperscalarHash] must have run on this compiler).
  @override
  void generateProgramLight(Uint8List prog, int eMask0, int eMask1, List<int> readReg, int datasetOffset) {
    mem.writable();
    _generateProgramPrologue(prog, eMask0, eMask1, readReg);
    _emit(v2 ? t.readDatasetLightInitV2 : t.readDatasetLightInit);
    _w32(codePos, 0xc381);
    codePos += 2;
    _emit32(datasetOffset ~/ cacheLineSize);
    _emitByte(0xe8);
    _emit32(_superScalarHashOffset - (codePos + 4));
    _emit(t.readDatasetLightFin);
    _generateProgramEpilogue(readReg);
    mem.executable();
  }

  void _generateProgramPrologue(Uint8List prog, int eMask0, int eMask1, List<int> readReg) {
    _imulRcpStorage = t.imulRcpStoreOffset + 2;
    _imulRcpUsed = 0;
    _w64(_imulRcpStorage - 34, eMask0);
    _w64(_imulRcpStorage - 26, eMask1);
    codePos = codePosFirst;
    _prevCfround = -1;
    _prevFpOperation = -1;
    for (var j = 0; j < 8; j++) {
      _registerUsage[j] = codePos;
    }
    final n = v2 ? rxProgramSizeV2 : rxProgramSizeV1;
    for (var i = 0; i < n; i++) {
      final o = 128 + 8 * i;
      final opcode = prog[o];
      final dst = prog[o + 1] & 7;
      final src = prog[o + 2] & 7;
      final mod = prog[o + 3];
      final imm = prog[o + 4] | (prog[o + 5] << 8) | (prog[o + 6] << 16) | (prog[o + 7] << 24);
      _instruction(_opcodeGroup[opcode], dst, src, mod, imm);
    }
    _w64(codePos, 0xc03341c08b41 + (readReg[2] << 16) + (readReg[3] << 40));
    codePos += 6;
  }

  void _generateProgramEpilogue(List<int> readReg) {
    _w64(codePos, 0xc03349c08b49 + (readReg[0] << 16) + (readReg[1] << 40));
    codePos += 6;
    _emit(bmi2 ? t.prefetchScratchpadBmi2 : t.prefetchScratchpad);
    _emit(v2 ? t.loopStoreHardAes : t.loopStore);
    if (jccErratum) {
      final branchBegin = codePos;
      final branchEnd = branchBegin + 9;
      if ((branchBegin ^ branchEnd) >= 32) {
        var alignment = 32 - (branchBegin & 31);
        if (alignment > 8) {
          _emit(_nopx[alignment - 9].sublist(0, alignment - 8));
          alignment = 8;
        }
        _emit(_nopx[alignment - 1]);
      }
    }
    _w64(codePos, 0x850f01eb83);
    codePos += 5;
    _emit32(prologueSize - codePos - 4);
    _emitByte(0xe9);
    _emit32(epilogueOffset - codePos - 4);
  }

  void _instruction(int group, int dst, int src, int mod, int imm) {
    switch (group) {
      case _gIaddRs:
        _hIaddRs(dst, src, mod, imm);
      case _gIaddM:
        _memOp(dst, src, mod, imm, 0x0604034c, 0x86034c);
      case _gIsubR:
        _hIsubR(dst, src, imm);
      case _gIsubM:
        _memOp(dst, src, mod, imm, 0x06042b4c, 0x862b4c);
      case _gImulR:
        _hImulR(dst, src, imm);
      case _gImulM:
        _hImulM(dst, src, mod, imm);
      case _gImulhR:
        bmi2 ? _hImulhRBmi2(dst, src) : _hImulhR(dst, src);
      case _gImulhM:
        bmi2 ? _hImulhMBmi2(dst, src, mod, imm) : _hImulhM(dst, src, mod, imm);
      case _gIsmulhR:
        _hIsmulhR(dst, src);
      case _gIsmulhM:
        _hIsmulhM(dst, src, mod, imm);
      case _gImulRcp:
        _hImulRcp(dst, imm);
      case _gInegR:
        _w32(codePos, 0xd8f749 + (dst << 16));
        codePos += 3;
        _registerUsage[dst] = codePos;
      case _gIxorR:
        _hIxorR(dst, src, imm);
      case _gIxorM:
        _memOp(dst, src, mod, imm, 0x0604334c, 0x86334c);
      case _gIrorR:
        _hRotate(dst, src, imm, 0xc8d349c88b41, 0xc8c149);
      case _gIrolR:
        _hRotate(dst, src, imm, 0xc0d349c88b41, 0xc0c149);
      case _gIswapR:
        if (src != dst) {
          _w32(codePos, 0xc0874d + (((dst << 3) + src) << 16));
          codePos += 3;
          _registerUsage[dst] = codePos;
          _registerUsage[src] = codePos;
        }
      case _gFswapR:
        _w64(codePos, 0x01c0c60f66 + (((dst << 3) + dst) << 24));
        codePos += 5;
      case _gFaddR:
        _prevFpOperation = codePos;
        _w64(codePos, 0xc0580f4166 + ((((dst & 3) << 3) + (src & 3)) << 32));
        codePos += 5;
      case _gFaddM:
        _prevFpOperation = codePos;
        _genAddressReg(true, src, mod, imm);
        _w64(codePos, 0x41660624e60f44f3);
        _w32(codePos + 8, 0xc4580f + ((dst & 3) << 19));
        codePos += 11;
      case _gFsubR:
        _prevFpOperation = codePos;
        _w64(codePos, 0xc05c0f4166 + ((((dst & 3) << 3) + (src & 3)) << 32));
        codePos += 5;
      case _gFsubM:
        _prevFpOperation = codePos;
        _genAddressReg(true, src, mod, imm);
        _w64(codePos, 0x41660624e60f44f3);
        _w32(codePos + 8, 0xc45c0f + ((dst & 3) << 19));
        codePos += 11;
      case _gFscalR:
        _emit32(0xc7570f41 + ((dst & 3) << 27));
      case _gFmulR:
        _prevFpOperation = codePos;
        _w64(codePos, 0xe0590f4166 + ((((dst & 3) << 3) + (src & 3)) << 32));
        codePos += 5;
      case _gFdivM:
        _prevFpOperation = codePos;
        _genAddressReg(true, src, mod, imm);
        _w64(codePos, 0x0624e60f44f3);
        codePos += 6;
        _w64(codePos, 0xe6560f45e5540f45);
        codePos += 8;
        _w64(codePos, 0xe45e0f4166 + ((dst & 3) << 35));
        codePos += 5;
      case _gFsqrtR:
        _prevFpOperation = codePos;
        _emit32(0xe4510f66 + ((((dst & 3) << 3) + (dst & 3)) << 24));
      case _gCbranch:
        _hCbranch(dst, mod, imm);
      case _gCfround:
        bmi2 ? _hCfroundBmi2(src, imm) : _hCfround(src, imm);
      case _gIstore:
        _genAddressRegDst(dst, mod, imm);
        _emit32(0x0604894c + (src << 19));
      default:
        _emitByte(0x90);
    }
  }

  void _genAddressReg(bool toRax, int src, int mod, int imm) {
    _w32(codePos, (toRax ? 0x24808d41 : 0x24888d41) + (src << 16));
    codePos += src == 4 ? 4 : 3; // r12 needs a SIB byte
    _emit32(imm);
    if (toRax) {
      _emitByte(0x25);
    } else {
      _w32(codePos, 0xe181);
      codePos += 2;
    }
    _emit32(_addressMask[mod & 3]);
  }

  void _genAddressRegDst(int dst, int mod, int imm) {
    _w32(codePos, 0x24808d41 + (dst << 16));
    codePos += dst == 4 ? 4 : 3;
    _emit32(imm);
    _emitByte(0x25);
    _emit32(mod < (storeL3Condition << 4) ? _addressMask[mod & 3] : _l3Mask);
  }

  void _genAddressImm(int imm) => _emit32(imm & _l3Mask);

  void _hIaddRs(int dst, int src, int mod, int imm) {
    final sib = (((mod >> 2) & 3) << 6) | (src << 3) | dst;
    var k = 0x048d4f + (dst << 19);
    if (dst == registerNeedsDisplacement) k = 0xac8d4f;
    _w32(codePos, k | (sib << 24));
    _w32(codePos + 4, imm);
    codePos += dst == registerNeedsDisplacement ? 8 : 4;
    _registerUsage[dst] = codePos;
  }

  void _memOp(int dst, int src, int mod, int imm, int regForm, int immForm) {
    if (src != dst) {
      _genAddressReg(true, src, mod, imm);
      _emit32(regForm + (dst << 19));
    } else {
      _w32(codePos, immForm + (dst << 19));
      codePos += 3;
      _genAddressImm(imm);
    }
    _registerUsage[dst] = codePos;
  }

  void _hIsubR(int dst, int src, int imm) {
    if (src != dst) {
      _w32(codePos, 0xc02b4d + (dst << 19) + (src << 16));
      codePos += 3;
    } else {
      _w32(codePos, 0xe88149 + (dst << 16));
      codePos += 3;
      _emit32(imm);
    }
    _registerUsage[dst] = codePos;
  }

  void _hImulR(int dst, int src, int imm) {
    if (src != dst) {
      _emit32(0xc0af0f4d + ((dst * 8 + src) << 24));
    } else {
      _w32(codePos, 0xc0694d + (((dst << 3) + dst) << 16));
      codePos += 3;
      _emit32(imm);
    }
    _registerUsage[dst] = codePos;
  }

  void _hImulM(int dst, int src, int mod, int imm) {
    if (src != dst) {
      _genAddressReg(true, src, mod, imm);
      _w64(codePos, 0x0604af0f4c + (dst << 27));
      codePos += 5;
    } else {
      _emit32(0x86af0f4c + (dst << 27));
      _genAddressImm(imm);
    }
    _registerUsage[dst] = codePos;
  }

  void _hImulhR(int dst, int src) {
    _w32(codePos, 0xc08b49 + (dst << 16));
    _w32(codePos + 3, 0xe0f749 + (src << 16));
    _w32(codePos + 6, 0xc28b4c + (dst << 19));
    codePos += 9;
    _registerUsage[dst] = codePos;
  }

  void _hImulhRBmi2(int dst, int src) {
    _w32(codePos, 0xC4D08B49 + (dst << 16));
    _w32(codePos + 4, 0xC0F6FB42 + (dst << 27) + (src << 24));
    codePos += 8;
    _registerUsage[dst] = codePos;
  }

  void _hImulhM(int dst, int src, int mod, int imm) {
    if (src != dst) {
      _genAddressReg(false, src, mod, imm);
      _w64(codePos, 0x0e24f748c08b49 + (dst << 16));
      codePos += 7;
    } else {
      _w64(codePos, 0xa6f748c08b49 + (dst << 16));
      codePos += 6;
      _genAddressImm(imm);
    }
    _w32(codePos, 0xc28b4c + (dst << 19));
    codePos += 3;
    _registerUsage[dst] = codePos;
  }

  void _hImulhMBmi2(int dst, int src, int mod, int imm) {
    if (src != dst) {
      _genAddressReg(false, src, mod, imm);
      _w32(codePos, 0xC4D08B49 + (dst << 16));
      _w64(codePos + 4, 0x0E04F6FB62 + (dst << 27));
      codePos += 9;
    } else {
      _w64(codePos, 0x86F6FB62C4D08B49 + (dst << 16) + (dst << 59));
      _w32(codePos + 8, imm & _l3Mask);
      codePos += 12;
    }
    _registerUsage[dst] = codePos;
  }

  void _hIsmulhR(int dst, int src) {
    _w64(codePos, 0x8b4ce8f749c08b49 + (dst << 16) + (src << 40));
    codePos += 8;
    _emitByte(0xc2 + 8 * dst);
    _registerUsage[dst] = codePos;
  }

  void _hIsmulhM(int dst, int src, int mod, int imm) {
    if (src != dst) {
      _genAddressReg(false, src, mod, imm);
      _w64(codePos, 0x0e2cf748c08b49 + (dst << 16));
      codePos += 7;
    } else {
      _w64(codePos, 0xaef748c08b49 + (dst << 16));
      codePos += 6;
      _genAddressImm(imm);
    }
    _w32(codePos, 0xc28b4c + (dst << 19));
    codePos += 3;
    _registerUsage[dst] = codePos;
  }

  void _hImulRcp(int dst, int imm) {
    if (isZeroOrPowerOf2(imm)) return;
    final reciprocal = randomxReciprocal(imm);
    if (_imulRcpUsed < 16) {
      _w64(_imulRcpStorage, reciprocal);
      _w64(codePos, 0x2444AF0F4C + (dst << 27) + ((248 - _imulRcpUsed * 8) << 40));
      ++_imulRcpUsed;
      _imulRcpStorage += 11;
      codePos += 6;
    } else {
      _w32(codePos, 0xb848);
      codePos += 2;
      _emit64(reciprocal);
      _emit32(0xc0af0f4c + (dst << 27));
    }
    _registerUsage[dst] = codePos;
  }

  void _hIxorR(int dst, int src, int imm) {
    if (src != dst) {
      _w32(codePos, 0xc0334d + (((dst << 3) + src) << 16));
      codePos += 3;
    } else {
      _w64(codePos, (imm << 24) + 0xf08149 + (dst << 16));
      codePos += 7;
    }
    _registerUsage[dst] = codePos;
  }

  void _hRotate(int dst, int src, int imm, int regForm, int immForm) {
    if (src != dst) {
      _w64(codePos, regForm + (src << 16) + (dst << 40));
      codePos += 6;
    } else {
      _w32(codePos, immForm + (dst << 16));
      codePos += 3;
      _emitByte(imm & 63);
    }
    _registerUsage[dst] = codePos;
  }

  void _hCfround(int src, int imm) {
    final t = _prevCfround;
    if (t > _prevFpOperation && !v2) _copy(t, amd ? _nop26 : _nop14);
    final pos = codePos;
    _prevCfround = pos;
    _w32(pos, 0x00C08B49 + (src << 16));
    final rotate = ((imm & 63) - 2) & 63;
    _w32(pos + 3, 0x00C8C148 + (rotate << 24));
    codePos = _cfroundTail(pos + 7);
  }

  void _hCfroundBmi2(int src, int imm) {
    final t = _prevCfround;
    if (t > _prevFpOperation && !v2) _copy(t, amd ? _nop25 : _nop13);
    final pos = codePos;
    _prevCfround = pos;
    final rotate = ((imm & 63) - 2) & 63;
    _w64(pos, 0xC0F0FBC3C4 | (src << 32) | (rotate << 40));
    codePos = _cfroundTail(pos + 6);
  }

  /// The mode index is in eax bits 2..3; load MXCSR from the table at [rsp].
  int _cfroundTail(int pos) {
    if (amd) {
      if (v2) {
        _w32(pos, 0x1375F0A8); // test al, 0xF0; jnz +19
        pos += 4;
      }
      _w64(pos, 0x742024443B0CE083);
      _w64(pos + 8, 0x8900EB0414AE0F0A);
      _w32(pos + 16, 0x202444);
      return pos + 19;
    }
    if (v2) {
      if (jccErratum) {
        final branchBegin = pos & 31;
        if (branchBegin >= 28) {
          final alignment = 32 - branchBegin;
          _copy(pos, _nopx[alignment - 1]);
          pos += alignment;
        }
      }
      _w32(pos, 0x0775F0A8); // test al, 0xF0; jnz +7
      pos += 4;
    }
    _w64(pos, 0x0414AE0F0CE083);
    return pos + 7;
  }

  void _hCbranch(int reg, int mod, int imm) {
    var pos = codePos;
    var jmpOffset = _registerUsage[reg];
    // Jumping back over an FP instruction counts as an FP instruction now.
    if (jmpOffset <= _prevFpOperation) _prevFpOperation = pos;
    jmpOffset -= pos + 16;
    if (jccErratum) {
      final branchBegin = pos + 7;
      final branchEnd = branchBegin + (jmpOffset >= -128 ? 9 : 13);
      if ((branchBegin ^ branchEnd) >= 32) {
        final alignment = 32 - (branchBegin & 31);
        jmpOffset -= alignment;
        for (var i = 0; i < alignment; i++) {
          _bytes[base + pos + i] = _jmpAlignPrefix(alignment, i);
        }
        pos += alignment;
      }
    }
    _w32(pos, 0x00c08149 + (reg << 16));
    final shift = mod >> 4;
    final orMask = (1 << _jumpOffset) << shift;
    final andMask = _rotl32(~(1 << (_jumpOffset - 1)) & 0xffffffff, shift);
    _w32(pos + 3, (imm | orMask) & andMask);
    _w32(pos + 7, 0x00c0f749 + (reg << 16));
    _w32(pos + 10, _conditionMask << shift);
    pos += 14;
    if (jmpOffset >= -128) {
      _w32(pos, 0x74 + ((jmpOffset & 0xffffff) << 8));
      pos += 2;
    } else {
      _w64(pos, 0x840f + (((jmpOffset - 4) & 0xffffffff) << 16));
      pos += 6;
    }
    for (var j = 0; j < 8; j++) {
      _registerUsage[j] = pos;
    }
    codePos = pos;
  }

  static int _jmpAlignPrefix(int size, int i) {
    // xmrig JMP_ALIGN_PREFIX: segment prefixes (0x2E), after up to 4 bytes of NOP for sizes 9..13.
    final nopLen = size >= 9 ? size - 8 : 0;
    if (i < nopLen) return _nopx[nopLen - 1][i];
    return 0x2E;
  }

  static int _rotl32(int a, int shift) => ((a << shift) | (a >>> ((32 - shift) & 31))) & 0xffffffff;

  // ---- SuperscalarHash --------------------------------------------------

  /// Compiles the 8 SuperscalarHash programs of a cache at code+32768: a
  /// function taking rbx = item number, rdi = cache memory and returning
  /// the item in r8..r15.
  @override
  void generateSuperscalarHash(List<SuperscalarProgram> programs) {
    mem.writable();
    _copy(_superScalarHashOffset, t.sshashInit);
    codePos = _superScalarHashOffset + t.sshashInit.length;
    for (var j = 0; j < programs.length; j++) {
      final prog = programs[j];
      for (var i = 0; i < prog.size; i++) {
        _superscalarInstruction(prog.rawOpcode[i], prog.rawDst[i], prog.rawSrc[i], prog.rawMod[i], prog.rawImm32[i]);
      }
      _emit(t.sshashLoad);
      if (j < programs.length - 1) {
        _w32(codePos, 0xd88b49 + (prog.addressRegister << 16)); // mov rbx, r(addr)
        codePos += 3;
        _emit(t.sshashPrefetch);
      }
    }
    _emitByte(0xc3);
    mem.executable();
  }

  /// Places the dataset init loop at code+0 (after [generateSuperscalarHash]).
  /// Signature: `void(uint8_t** cacheMemory, uint8_t* dataset, uint64 start, uint64 end)`.
  @override
  void generateDatasetInitCode() {
    mem.writable();
    _copy(0, t.datasetInit);
    mem.executable();
  }

  void _superscalarInstruction(int type, int dst, int src, int mod, int imm) {
    switch (type) {
      case 0: // ISUB_R
        _w32(codePos, 0x00C02B4D + (dst << 19) + (src << 16));
        codePos += 3;
      case 1: // IXOR_R
        _w32(codePos, 0x00C0334D + (dst << 19) + (src << 16));
        codePos += 3;
      case 2: // IADD_RS
        final sib = (((mod >> 2) & 3) << 6) | (src << 3) | dst;
        _emit32(0x00048D4F + (dst << 19) + (sib << 24));
      case 3: // IMUL_R
        _emit32(0xC0AF0F4D + (dst << 27) + (src << 24));
      case 4: // IROR_C
        _emit32(0x00C8C149 + (dst << 16) + ((imm & 63) << 24));
      case 5 || 7 || 9: // IADD_C7/8/9
        _w32(codePos, 0x00C08149 + (dst << 16));
        codePos += 3;
        _emit32(imm);
      case 6 || 8 || 10: // IXOR_C7/8/9
        _w32(codePos, 0x00F08149 + (dst << 16));
        codePos += 3;
        _emit32(imm);
      case 11: // IMULH_R
        _w32(codePos, 0x00C08B49 + (dst << 16));
        codePos += 3;
        _w32(codePos, 0x00E0F749 + (src << 16));
        codePos += 3;
        _w32(codePos, 0x00C28B4C + (dst << 19));
        codePos += 3;
      case 12: // ISMULH_R
        _w32(codePos, 0x00C08B49 + (dst << 16));
        codePos += 3;
        _w32(codePos, 0x00E8F749 + (src << 16));
        codePos += 3;
        _w32(codePos, 0x00C28B4C + (dst << 19));
        codePos += 3;
      case 13: // IMUL_RCP
        _w32(codePos, 0x0000B848);
        codePos += 2;
        _emit64(randomxReciprocal(imm));
        _emit32(0xC0AF0F4C + (dst << 27));
      default:
        throw StateError('bad superscalar instruction $type');
    }
  }

  // for tests
  int readCode32(int pos) => _r32(pos);
}
