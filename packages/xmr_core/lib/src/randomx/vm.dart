import 'dart:math' as math;
import 'dart:typed_data';

import '../crypto/aes_soft.dart';
import 'package:crypto_core/crypto_core.dart';
import '../util/u64.dart';
import 'aes_gen.dart';
import 'cache.dart';
import 'config.dart';
import 'fpround.dart';

/// RandomX virtual machine: a pre-decoded bytecode interpreter following
/// tevador/RandomX `bytecode_machine.cpp` and `vm_interpreted.cpp`
/// (BSD-3-Clause). Supports RandomX v1 (rx/0) and v2.
///
/// One VM hashes one input at a time and owns its 2 MiB scratchpad. It reads
/// either a [RandomXDataset] (fast mode) or computes dataset items from a
/// [RandomXCache] (light mode).

// Bytecode types. Register-immediate forms get their own type instead of
// the reference's "source points at the immediate" trick.
const int _iaddRs = 0, _iaddM = 1, _isubR = 2, _isubI = 3, _isubM = 4, _imulR = 5, _imulI = 6, _imulM = 7;
const int _imulhR = 8, _imulhM = 9, _ismulhR = 10, _ismulhM = 11, _inegR = 12, _ixorR = 13, _ixorI = 14;
const int _ixorM = 15, _irorR = 16, _irorI = 17, _irolR = 18, _irolI = 19, _iswapR = 20, _fswapR = 21;
const int _faddR = 22, _faddM = 23, _fsubR = 24, _fsubM = 25, _fscalR = 26, _fmulR = 27, _fdivM = 28;
const int _fsqrtR = 29, _cbranch = 30, _cfround = 31, _istore = 32, _nop = 33;

/// Opcode (0..255) to reference instruction group, from the frequency table.
final Int32List _opcodeGroup = () {
  final t = Int32List(256);
  var o = 0;
  for (var g = 0; g < rxFrequencies.length; g++) {
    for (var k = 0; k < rxFrequencies[g]; k++) {
      t[o++] = g;
    }
  }
  return t;
}();

// Reference instruction groups (InstructionType order).
const int _gIaddRs = 0, _gIaddM = 1, _gIsubR = 2, _gIsubM = 3, _gImulR = 4, _gImulM = 5, _gImulhR = 6;
const int _gImulhM = 7, _gIsmulhR = 8, _gIsmulhM = 9, _gImulRcp = 10, _gInegR = 11, _gIxorR = 12;
const int _gIxorM = 13, _gIrorR = 14, _gIrolR = 15, _gIswapR = 16, _gFswapR = 17, _gFaddR = 18;
const int _gFaddM = 19, _gFsubR = 20, _gFsubM = 21, _gFscalR = 22, _gFmulR = 23, _gFdivM = 24;
const int _gFsqrtR = 25, _gCbranch = 26, _gCfround = 27, _gIstore = 28;

// Register file slots: f0..f3 (0..7), e0..e3 (8..15), a0..a3 (16..23), lane
// lo then hi. Slots 24..25 hold a masked FDIV_M operand, slot 26 the
// rounding error whose sign bit the nudge reads.
const int _fBase = 0, _eBase = 8, _aBase = 16, _tmpSlot = 24, _errSlot = 26;

/// A RandomX hasher: the interpreter ([RandomXVM]) or the JIT VM.
abstract interface class RandomXHasher {
  abstract bool v2;
  Uint8List hash(List<int> input);

  /// Writes the 32-byte hash of [input] to [out] at [offset].
  void hashInto(List<int> input, Uint8List out, int offset);

  /// Releases native memory (no-op for the interpreter).
  void free();
}

class RandomXVM implements RandomXHasher {
  final RandomXCache? cache;
  final Int64List? dataset;
  @override
  bool v2;

  // Scratchpad (2 MiB) and its views.
  final Int64List _sp = Int64List(rxScratchpadL3 ~/ 8);
  late final Int32List _sp32 = Int32List.view(_sp.buffer);
  late final Uint32List _spU32 = Uint32List.view(_sp.buffer);
  late final Float64List _spF = Float64List.view(_sp.buffer);

  // Integer registers; r[8] is a constant zero used by memory operands whose
  // source equals their destination.
  final Int64List _r = Int64List(9);

  final Float64List _fr = Float64List(27);
  late final Int64List _fri = Int64List.view(_fr.buffer);
  late final Uint32List _fr32 = Uint32List.view(_fr.buffer);

  // Generated program: 16 entropy words then instructions (3200 bytes).
  final Uint32List _prog = Uint32List(3200 ~/ 4);
  late final Uint8List _progBytes = Uint8List.view(_prog.buffer);
  late final Int64List _progWords = Int64List.view(_prog.buffer);

  final Uint32List _temp = Uint32List(16); // 64-byte Blake2b chain state
  late final Uint8List _tempBytes = Uint8List.view(_temp.buffer);

  // Bytecode: 4 ints per instruction (type, dst, src, aux) plus an immediate.
  // aux is the IADD_RS shift, the memory mask, or the CBRANCH target; for
  // CBRANCH, src holds the condition shift.
  final Int32List _code = Int32List(4 * rxProgramMaxSize);
  final Int64List _imm = Int64List(rxProgramMaxSize);
  final Int32List _regUsage = Int32List(8);

  // Program configuration.
  int _ma = 0, _mx = 0, _datasetOffset = 0;
  int _readReg0 = 0, _readReg1 = 0, _readReg2 = 0, _readReg3 = 0;
  int _eMask0 = 0, _eMask1 = 0;
  int _fprc = 0;

  final Int64List _item = Int64List(8);
  final Int64List _rl = Int64List(8);
  final Uint8List _regFile = Uint8List(256);

  RandomXVM.light(RandomXCache this.cache, {this.v2 = false}) : dataset = null;

  RandomXVM.fast(RandomXDataset ds, {this.v2 = false})
      : dataset = ds.memory,
        cache = null;

  int get _programSize => v2 ? rxProgramSizeV2 : rxProgramSizeV1;

  @override
  void hashInto(List<int> input, Uint8List out, int offset) => out.setRange(offset, offset + 32, hash(input));

  @override
  void free() {}

  /// RandomX hash of [input] (32 bytes).
  @override
  Uint8List hash(List<int> input) {
    _tempBytes.setAll(0, Blake2b.hash(input, 64));
    fillAes1Rx4(_temp, _spU32, 0, _spU32.length);
    _fprc = 0;
    for (var chain = 0; chain < rxProgramCount - 1; chain++) {
      _run();
      _tempBytes.setAll(0, Blake2b.hash(_registerFile(), 64));
    }
    _run();
    // getFinalResult: AesHash1R of the scratchpad replaces the a registers.
    hashAes1Rx4(_spU32, _fr32, 2 * _aBase);
    return Blake2b.hash(_registerFile(), 32);
  }

  Uint8List _registerFile() {
    final b = _regFile;
    for (var i = 0; i < 8; i++) {
      final v = _r[i];
      for (var k = 0; k < 8; k++) {
        b[8 * i + k] = (v >>> (8 * k)) & 0xff;
      }
    }
    b.setRange(64, 256, Uint8List.view(_fr.buffer, 0, 192));
    return b;
  }

  void _run() {
    fillAes4Rx4(_temp, _prog, _prog.length);
    _initialize();
    _compile();
    _execute();
  }

  static int _smallPositiveFloatBits(int entropy) {
    var exponent = entropy >>> 59;
    final mantissa = entropy & mantissaMask;
    exponent += exponentBias;
    exponent &= exponentMask;
    return (exponent << mantissaSize) | mantissa;
  }

  static int _floatMask(int entropy) {
    const mask22bit = (1 << 22) - 1;
    final exponent = (constExponentBits | ((entropy >>> 60) << 4)) << mantissaSize;
    return (entropy & mask22bit) | exponent;
  }

  void _initialize() {
    final e = _progWords;
    for (var i = 0; i < 8; i++) {
      _fri[_aBase + i] = _smallPositiveFloatBits(e[i]);
    }
    _ma = e[8] & cacheLineAlignMask;
    _mx = e[10] & mask32;
    final addressRegisters = e[12];
    _readReg0 = addressRegisters & 1;
    _readReg1 = 2 + ((addressRegisters >> 1) & 1);
    _readReg2 = 4 + ((addressRegisters >> 2) & 1);
    _readReg3 = 6 + ((addressRegisters >> 3) & 1);
    _datasetOffset = umodU64By32(e[13], datasetExtraItems + 1) * cacheLineSize;
    _eMask0 = _floatMask(e[14]);
    _eMask1 = _floatMask(e[15]);
  }

  static int _memMask(int mod) => (mod & 3) != 0 ? scratchpadL1Mask : scratchpadL2Mask;

  void _set(int i, int type, int dst, int src, int aux, int imm) {
    final o = 4 * i;
    _code[o] = type;
    _code[o + 1] = dst;
    _code[o + 2] = src;
    _code[o + 3] = aux;
    _imm[i] = imm;
  }

  void _compile() {
    final p = _progBytes;
    final usage = _regUsage;
    for (var i = 0; i < 8; i++) {
      usage[i] = -1;
    }
    final n = _programSize;
    for (var i = 0; i < n; i++) {
      final o = 128 + 8 * i;
      final opcode = p[o];
      final dst = p[o + 1] & 7;
      final src = p[o + 2] & 7;
      final mod = p[o + 3];
      final imm32 = p[o + 4] | (p[o + 5] << 8) | (p[o + 6] << 16) | (p[o + 7] << 24);
      final simm = imm32.toSigned(32);
      switch (_opcodeGroup[opcode]) {
        case _gIaddRs:
          _set(i, _iaddRs, dst, src, (mod >> 2) & 3, dst == registerNeedsDisplacement ? simm : 0);
          usage[dst] = i;
        case _gIaddM:
          _memOp(i, _iaddM, dst, src, mod, simm);
        case _gIsubR:
          _regOp(i, _isubR, _isubI, dst, src, simm);
        case _gIsubM:
          _memOp(i, _isubM, dst, src, mod, simm);
        case _gImulR:
          _regOp(i, _imulR, _imulI, dst, src, simm);
        case _gImulM:
          _memOp(i, _imulM, dst, src, mod, simm);
        case _gImulhR:
          _set(i, _imulhR, dst, src, 0, 0);
          usage[dst] = i;
        case _gImulhM:
          _memOp(i, _imulhM, dst, src, mod, simm);
        case _gIsmulhR:
          _set(i, _ismulhR, dst, src, 0, 0);
          usage[dst] = i;
        case _gIsmulhM:
          _memOp(i, _ismulhM, dst, src, mod, simm);
        case _gImulRcp:
          if (!isZeroOrPowerOf2(imm32)) {
            _set(i, _imulI, dst, src, 0, randomxReciprocal(imm32));
            usage[dst] = i;
          } else {
            _set(i, _nop, 0, 0, 0, 0);
          }
        case _gInegR:
          _set(i, _inegR, dst, src, 0, 0);
          usage[dst] = i;
        case _gIxorR:
          _regOp(i, _ixorR, _ixorI, dst, src, simm);
        case _gIxorM:
          _memOp(i, _ixorM, dst, src, mod, simm);
        case _gIrorR:
          _regOp(i, _irorR, _irorI, dst, src, imm32 & 63);
        case _gIrolR:
          _regOp(i, _irolR, _irolI, dst, src, imm32 & 63);
        case _gIswapR:
          if (src != dst) {
            _set(i, _iswapR, dst, src, 0, 0);
            usage[dst] = i;
            usage[src] = i;
          } else {
            _set(i, _nop, 0, 0, 0, 0);
          }
        case _gFswapR:
          _set(i, _fswapR, 2 * dst, 0, 0, 0); // f0..f3 then e0..e3
        case _gFaddR:
          _set(i, _faddR, _fBase + 2 * (dst & 3), _aBase + 2 * (src & 3), 0, 0);
        case _gFaddM:
          _set(i, _faddM, _fBase + 2 * (dst & 3), src, _memMask(mod), simm);
        case _gFsubR:
          _set(i, _fsubR, _fBase + 2 * (dst & 3), _aBase + 2 * (src & 3), 0, 0);
        case _gFsubM:
          _set(i, _fsubM, _fBase + 2 * (dst & 3), src, _memMask(mod), simm);
        case _gFscalR:
          _set(i, _fscalR, _fBase + 2 * (dst & 3), 0, 0, 0);
        case _gFmulR:
          _set(i, _fmulR, _eBase + 2 * (dst & 3), _aBase + 2 * (src & 3), 0, 0);
        case _gFdivM:
          _set(i, _fdivM, _eBase + 2 * (dst & 3), src, _memMask(mod), simm);
        case _gFsqrtR:
          _set(i, _fsqrtR, _eBase + 2 * (dst & 3), 0, 0, 0);
        case _gCbranch:
          final shift = (mod >> 4) + conditionOffset;
          var imm = simm | (1 << shift);
          imm &= ~(1 << (shift - 1));
          _set(i, _cbranch, dst, shift, usage[dst], imm);
          for (var j = 0; j < 8; j++) {
            usage[j] = i;
          }
        case _gCfround:
          _set(i, _cfround, 0, src, 0, imm32 & 63);
        case _gIstore:
          _set(i, _istore, dst, src, (mod >> 4) < storeL3Condition ? _memMask(mod) : scratchpadL3Mask, simm);
        default:
          _set(i, _nop, 0, 0, 0, 0);
      }
    }
  }

  void _regOp(int i, int regType, int immType, int dst, int src, int imm) {
    if (src != dst) {
      _set(i, regType, dst, src, 0, 0);
    } else {
      _set(i, immType, dst, src, 0, imm);
    }
    _regUsage[dst] = i;
  }

  void _memOp(int i, int type, int dst, int src, int mod, int simm) {
    if (src != dst) {
      _set(i, type, dst, src, _memMask(mod), simm);
    } else {
      _set(i, type, dst, 8, scratchpadL3Mask, simm); // r[8] is always zero
    }
    _regUsage[dst] = i;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _execute() {
    final r = _r, fr = _fr, fri = _fri, sp = _sp, sp32 = _sp32, spF = _spF;
    final code = _code, immA = _imm;
    final n = 4 * _programSize;
    final v2 = this.v2;
    final ds = dataset;
    final c = cache;
    final eMask0 = _eMask0, eMask1 = _eMask1;
    final rr0 = _readReg0, rr1 = _readReg1, rr2 = _readReg2, rr3 = _readReg3;

    for (var i = 0; i < 9; i++) {
      r[i] = 0;
    }

    var spAddr0 = _mx;
    var spAddr1 = _ma;
    var fprc = _fprc;

    for (var ic = 0; ic < rxProgramIterations; ic++) {
      final spMix = r[rr0] ^ r[rr1];
      spAddr0 = (spAddr0 ^ spMix) & scratchpadL3Mask64;
      spAddr1 = (spAddr1 ^ (spMix >>> 32)) & scratchpadL3Mask64;

      final w0 = spAddr0 >> 3;
      for (var i = 0; i < 8; i++) {
        r[i] ^= sp[w0 + i];
      }
      final h1 = spAddr1 >> 2;
      for (var i = 0; i < 8; i++) {
        fr[i] = sp32[h1 + i].toDouble();
      }
      for (var i = 0; i < 8; i += 2) {
        fr[8 + i] = sp32[h1 + 8 + i].toDouble();
        fri[8 + i] = (fri[8 + i] & dynamicMantissaMask) | eMask0;
        fr[9 + i] = sp32[h1 + 9 + i].toDouble();
        fri[9 + i] = (fri[9 + i] & dynamicMantissaMask) | eMask1;
      }

      // ---- program body ----
      for (var o = 0; o < n; o += 4) {
        final d = code[o + 1];
        switch (code[o]) {
          case _iaddRs:
            r[d] += (r[code[o + 2]] << code[o + 3]) + immA[o >> 2];
          case _iaddM:
            r[d] += sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3];
          case _isubR:
            r[d] -= r[code[o + 2]];
          case _isubI:
            r[d] -= immA[o >> 2];
          case _isubM:
            r[d] -= sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3];
          case _imulR:
            r[d] *= r[code[o + 2]];
          case _imulI:
            r[d] *= immA[o >> 2];
          case _imulM:
            r[d] *= sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3];
          case _imulhR:
            r[d] = mulhU64(r[d], r[code[o + 2]]);
          case _imulhM:
            r[d] = mulhU64(r[d], sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3]);
          case _ismulhR:
            r[d] = mulhS64(r[d], r[code[o + 2]]);
          case _ismulhM:
            r[d] = mulhS64(r[d], sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3]);
          case _inegR:
            r[d] = -r[d];
          case _ixorR:
            r[d] ^= r[code[o + 2]];
          case _ixorI:
            r[d] ^= immA[o >> 2];
          case _ixorM:
            r[d] ^= sp[((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 3];
          case _irorR:
            r[d] = rotr64(r[d], r[code[o + 2]]);
          case _irorI:
            r[d] = rotr64(r[d], immA[o >> 2]);
          case _irolR:
            r[d] = rotl64(r[d], r[code[o + 2]]);
          case _irolI:
            r[d] = rotl64(r[d], immA[o >> 2]);
          case _iswapR:
            final s = code[o + 2];
            final t = r[s];
            r[s] = r[d];
            r[d] = t;
          case _fswapR:
            final t = fri[d];
            fri[d] = fri[d + 1];
            fri[d + 1] = t;
          case _faddR:
            final s = code[o + 2];
            if (fprc == 0) {
              fr[d] += fr[s];
              fr[d + 1] += fr[s + 1];
            } else {
              _add(fr, fri, d, fr[d], fr[s], fprc);
              _add(fr, fri, d + 1, fr[d + 1], fr[s + 1], fprc);
            }
          case _faddM:
            final h = ((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 2;
            if (fprc == 0) {
              fr[d] += sp32[h];
              fr[d + 1] += sp32[h + 1];
            } else {
              _add(fr, fri, d, fr[d], sp32[h].toDouble(), fprc);
              _add(fr, fri, d + 1, fr[d + 1], sp32[h + 1].toDouble(), fprc);
            }
          case _fsubR:
            final s = code[o + 2];
            if (fprc == 0) {
              fr[d] -= fr[s];
              fr[d + 1] -= fr[s + 1];
            } else {
              _add(fr, fri, d, fr[d], -fr[s], fprc);
              _add(fr, fri, d + 1, fr[d + 1], -fr[s + 1], fprc);
            }
          case _fsubM:
            final h = ((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 2;
            if (fprc == 0) {
              fr[d] -= sp32[h];
              fr[d + 1] -= sp32[h + 1];
            } else {
              _add(fr, fri, d, fr[d], -sp32[h].toDouble(), fprc);
              _add(fr, fri, d + 1, fr[d + 1], -sp32[h + 1].toDouble(), fprc);
            }
          case _fscalR:
            fri[d] ^= 0x80F0000000000000;
            fri[d + 1] ^= 0x80F0000000000000;
          case _fmulR:
            final s = code[o + 2];
            if (fprc == 0) {
              fr[d] *= fr[s];
              fr[d + 1] *= fr[s + 1];
            } else {
              _mul(fr, fri, d, fr[d], fr[s], fprc);
              _mul(fr, fri, d + 1, fr[d + 1], fr[s + 1], fprc);
            }
          case _fdivM:
            final h = ((r[code[o + 2]] + immA[o >> 2]) & code[o + 3]) >> 2;
            fr[_tmpSlot] = sp32[h].toDouble();
            fri[_tmpSlot] = (fri[_tmpSlot] & dynamicMantissaMask) | eMask0;
            fr[_tmpSlot + 1] = sp32[h + 1].toDouble();
            fri[_tmpSlot + 1] = (fri[_tmpSlot + 1] & dynamicMantissaMask) | eMask1;
            if (fprc == 0) {
              fr[d] /= fr[_tmpSlot];
              fr[d + 1] /= fr[_tmpSlot + 1];
            } else {
              _div(fr, fri, d, fr[d], fr[_tmpSlot], fprc);
              _div(fr, fri, d + 1, fr[d + 1], fr[_tmpSlot + 1], fprc);
            }
          case _fsqrtR:
            if (fprc == 0) {
              fr[d] = math.sqrt(fr[d]);
              fr[d + 1] = math.sqrt(fr[d + 1]);
            } else {
              _sqrt(fr, fri, d, fr[d], fprc);
              _sqrt(fr, fri, d + 1, fr[d + 1], fprc);
            }
          case _cbranch:
            final v = r[d] + immA[o >> 2];
            r[d] = v;
            if ((v & (conditionMask << code[o + 2])) == 0) o = 4 * code[o + 3];
          case _cfround:
            final isrc = rotr64(r[code[o + 2]], immA[o >> 2]);
            if (!v2 || (isrc & 60) == 0) fprc = isrc & 3;
          case _istore:
            sp[((r[d] + immA[o >> 2]) & code[o + 3]) >> 3] = r[code[o + 2]];
        }
      }

      // ---- dataset read and register mixing ----
      final readPtr = _datasetOffset + (_ma & cacheLineAlignMask);
      final mixV = (r[rr2] ^ r[rr3]) & mask32;
      if (v2) {
        _ma ^= mixV;
      } else {
        _mx ^= mixV;
      }
      final itemNumber = readPtr >> 6;
      if (ds != null) {
        final io = itemNumber * 8;
        for (var q = 0; q < 8; q++) {
          r[q] ^= ds[io + q];
        }
      } else {
        final item = _item;
        c!.initDatasetItem(item, 0, itemNumber, _rl);
        for (var q = 0; q < 8; q++) {
          r[q] ^= item[q];
        }
      }
      final t = _mx;
      _mx = _ma;
      _ma = t;

      final w1 = spAddr1 >> 3;
      for (var i = 0; i < 8; i++) {
        sp[w1 + i] = r[i];
      }

      if (v2) {
        final f32 = _fr32;
        for (var i = 0; i < 4; i++) {
          final k = 2 * _eBase + 4 * i; // e[i] as a 128-bit round key
          aesEncRound(f32, 0, f32, k);
          aesDecRound(f32, 4, f32, k);
          aesEncRound(f32, 8, f32, k);
          aesDecRound(f32, 12, f32, k);
        }
      } else {
        for (var i = 0; i < 8; i++) {
          fri[i] ^= fri[8 + i];
        }
      }

      final wf = spAddr0 >> 3;
      for (var i = 0; i < 8; i++) {
        spF[wf + i] = fr[i];
      }
      spAddr0 = 0;
      spAddr1 = 0;
    }
    _fprc = fprc;
  }

  // ---- directed rounding, result written to fr[i] ------------------------
  //
  // The round-to-nearest result goes into fr[i]; when the exact error points
  // the other way for this mode, the bit pattern moves one ulp in place.
  // Rare special cases (overflow, signed zero, out-of-range operands) defer
  // to the general routines in fpround.dart.

  static const double _safeMax = 1e290, _safeMin = 1e-290;

  /// Moves fr[i] (holding c, nonzero) one ulp according to [mode] and the
  /// sign of the exact error err = exact - c. The error sign is random, so
  /// this works on sign bits (err goes through the fr/fri alias) instead of
  /// comparisons, which compile to mispredicted branches.
  @pragma('vm:prefer-inline')
  static void _nudge(Float64List fr, Int64List fri, int i, double err, int mode) {
    fr[_errSlot] = err;
    final e = fri[_errSlot];
    final nz = ((e & 0x7FFFFFFFFFFFFFFF) + 0x7FFFFFFFFFFFFFFF) >>> 63; // err != 0
    final se = e >>> 63; // err < 0 (when nz)
    final sc = fri[i] >>> 63; // c < 0
    int delta;
    if (mode == 1) {
      delta = (nz & se) * (2 * sc - 1); // toward -inf
    } else if (mode == 2) {
      delta = (nz & (se ^ 1)) * (1 - 2 * sc); // toward +inf
    } else {
      delta = -(nz & (se ^ sc)); // toward zero
    }
    fri[i] += delta;
  }

  @pragma('vm:never-inline')
  static void _add(Float64List fr, Int64List fri, int i, double a, double b, int mode) {
    final c = a + b;
    if (c == 0.0 || !c.isFinite) {
      fr[i] = fAdd(a, b, mode);
      return;
    }
    fr[i] = c;
    final bv = c - a;
    final err = (a - (c - bv)) + (b - bv);
    _nudge(fr, fri, i, err, mode);
  }

  /// a*b - p exactly (Dekker), valid for operands and product inside
  /// [_safeMin, _safeMax] in magnitude.
  @pragma('vm:prefer-inline')
  static double _twoProductErr(double a, double b, double p) {
    const split = 134217729.0; // 2^27 + 1
    final ta = split * a;
    final ah = ta - (ta - a);
    final al = a - ah;
    final tb = split * b;
    final bh = tb - (tb - b);
    final bl = b - bh;
    return ((ah * bh - p) + ah * bl + al * bh) + al * bl;
  }

  // E-group operations (FMUL_R, FDIV_M, FSQRT_R) only ever see positive
  // finite operands: E values have their sign bit masked off on load and the
  // a registers are small positive numbers. Results are positive, so
  // round-down and round-toward-zero coincide and range checks are one-sided.

  /// Rounds positive fr[i] given err = exact - fr[i], branch-free.
  @pragma('vm:prefer-inline')
  static void _nudgePos(Float64List fr, Int64List fri, int i, double err, int mode) {
    fr[_errSlot] = err;
    final e = fri[_errSlot];
    final nz = ((e & 0x7FFFFFFFFFFFFFFF) + 0x7FFFFFFFFFFFFFFF) >>> 63;
    final se = e >>> 63;
    fri[i] += mode == 2 ? nz & (se ^ 1) : -(nz & se);
  }

  @pragma('vm:never-inline')
  static void _mul(Float64List fr, Int64List fri, int i, double a, double b, int mode) {
    final c = a * b;
    if (a < _safeMax && b < _safeMax && c < _safeMax && c > _safeMin && a > 0 && b > 0) {
      fr[i] = c;
      final err = _twoProductErr(a, b, c);
      _nudgePos(fr, fri, i, err, mode);
    } else {
      fr[i] = fMul(a, b, mode);
    }
  }

  @pragma('vm:never-inline')
  static void _div(Float64List fr, Int64List fri, int i, double a, double b, int mode) {
    final c = a / b;
    if (a < _safeMax && b < _safeMax && c < _safeMax && c > _safeMin && a > _safeMin && b > _safeMin) {
      fr[i] = c;
      final p = c * b;
      final err = (a - p) - _twoProductErr(c, b, p);
      _nudgePos(fr, fri, i, err, mode);
    } else {
      fr[i] = fDiv(a, b, mode);
    }
  }

  @pragma('vm:never-inline')
  static void _sqrt(Float64List fr, Int64List fri, int i, double a, int mode) {
    final c = math.sqrt(a);
    if (a < _safeMax && a > _safeMin) {
      fr[i] = c;
      final p = c * c;
      final err = (a - p) - _twoProductErr(c, c, p);
      _nudgePos(fr, fri, i, err, mode);
    } else {
      fr[i] = fSqrt(a, mode);
    }
  }
}
