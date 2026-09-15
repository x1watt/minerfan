import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import '../util/bytes.dart';
import '../util/u64.dart';
import 'config.dart';

/// SuperscalarHash program generation and execution, ported from
/// tevador/RandomX `superscalar.cpp` (BSD-3-Clause). The generator simulates
/// an Intel Ivy Bridge core; every quirk below is consensus-relevant.

class Blake2Generator {
  final Uint8List _data = Uint8List(64);
  int _index = 64;

  Blake2Generator(List<int> seed, [int nonce = 0]) {
    final n = seed.length > 60 ? 60 : seed.length;
    _data.setRange(0, n, seed);
    writeU32LE(_data, 60, nonce);
  }

  int getByte() {
    _check(1);
    return _data[_index++];
  }

  int getUInt32() {
    _check(4);
    final v = readU32LE(_data, _index);
    _index += 4;
    return v;
  }

  void _check(int needed) {
    if (_index + needed > 64) {
      _data.setAll(0, Blake2b.hash(_data, 64));
      _index = 0;
    }
  }
}

// Superscalar instruction types.
const int ssIsubR = 0, ssIxorR = 1, ssIaddRs = 2, ssImulR = 3, ssIrorC = 4;
const int ssIaddC7 = 5, ssIxorC7 = 6, ssIaddC8 = 7, ssIxorC8 = 8, ssIaddC9 = 9, ssIxorC9 = 10;
const int ssImulhR = 11, ssIsmulhR = 12, ssImulRcp = 13;
const int ssInvalid = -1;

// Execution ports.
const int _pNull = 0, _p0 = 1, _p1 = 2, _p5 = 4;
const int _p01 = _p0 | _p1, _p05 = _p0 | _p5, _p015 = _p0 | _p1 | _p5;

class _MacroOp {
  final int size, latency, uop1, uop2;
  final bool dependent;
  const _MacroOp(this.size, this.latency, this.uop1, [this.uop2 = _pNull, this.dependent = false]);
  bool get isSimple => uop2 == _pNull;
  bool get isEliminated => uop1 == _pNull;
}

const _subRr = _MacroOp(3, 1, _p015);
const _xorRr = _MacroOp(3, 1, _p015);
const _imulR = _MacroOp(3, 4, _p1, _p5);
const _mulR = _MacroOp(3, 4, _p1, _p5);
const _movRr = _MacroOp(3, 0, _pNull);
const _leaSib = _MacroOp(4, 1, _p01);
const _imulRr = _MacroOp(4, 3, _p1);
const _rorRi = _MacroOp(4, 1, _p05);
const _addRi = _MacroOp(7, 1, _p015);
const _xorRi = _MacroOp(7, 1, _p015);
const _movRi64 = _MacroOp(10, 1, _p015);
const _imulRrDependent = _MacroOp(4, 3, _p1, _pNull, true);

class _InstrInfo {
  final int type;
  final List<_MacroOp> ops;
  final int resultOp, dstOp, srcOp;
  const _InstrInfo(this.type, this.ops, this.resultOp, this.dstOp, this.srcOp);
  int get size => ops.length;
}

const _isubR = _InstrInfo(ssIsubR, [_subRr], 0, 0, 0);
const _ixorR = _InstrInfo(ssIxorR, [_xorRr], 0, 0, 0);
const _iaddRs = _InstrInfo(ssIaddRs, [_leaSib], 0, 0, 0);
const _imulRInfo = _InstrInfo(ssImulR, [_imulRr], 0, 0, 0);
const _irorC = _InstrInfo(ssIrorC, [_rorRi], 0, 0, -1);
const _iaddC7 = _InstrInfo(ssIaddC7, [_addRi], 0, 0, -1);
const _ixorC7 = _InstrInfo(ssIxorC7, [_xorRi], 0, 0, -1);
const _iaddC8 = _InstrInfo(ssIaddC8, [_addRi], 0, 0, -1);
const _ixorC8 = _InstrInfo(ssIxorC8, [_xorRi], 0, 0, -1);
const _iaddC9 = _InstrInfo(ssIaddC9, [_addRi], 0, 0, -1);
const _ixorC9 = _InstrInfo(ssIxorC9, [_xorRi], 0, 0, -1);
const _imulhR = _InstrInfo(ssImulhR, [_movRr, _mulR, _movRr], 1, 0, 1);
const _ismulhR = _InstrInfo(ssIsmulhR, [_movRr, _imulR, _movRr], 1, 0, 1);
const _imulRcp = _InstrInfo(ssImulRcp, [_movRi64, _imulRrDependent], 1, 1, -1);
const _nop = _InstrInfo(ssInvalid, [], 0, 0, 0);

const _slot3 = [_isubR, _ixorR];
const _slot3L = [_isubR, _ixorR, _imulhR, _ismulhR];
const _slot4 = [_irorC, _iaddRs];
const _slot7 = [_ixorC7, _iaddC7];
const _slot8 = [_ixorC8, _iaddC8];
const _slot9 = [_ixorC9, _iaddC9];

class _DecoderBuffer {
  final int index;
  final List<int> counts;
  const _DecoderBuffer(this.index, this.counts);
  int get size => counts.length;
}

const _buf484 = _DecoderBuffer(0, [4, 8, 4]);
const _buf7333 = _DecoderBuffer(1, [7, 3, 3, 3]);
const _buf3733 = _DecoderBuffer(2, [3, 7, 3, 3]);
const _buf493 = _DecoderBuffer(3, [4, 9, 3]);
const _buf4444 = _DecoderBuffer(4, [4, 4, 4, 4]);
const _buf3310 = _DecoderBuffer(5, [3, 3, 10]);
const _defaultBuffers = [_buf484, _buf7333, _buf3733, _buf493];

_DecoderBuffer _fetchNext(int instrType, int cycle, int mulCount, Blake2Generator gen) {
  if (instrType == ssImulhR || instrType == ssIsmulhR) return _buf3310;
  if (mulCount < cycle + 1) return _buf4444;
  if (instrType == ssImulRcp) return (gen.getByte() & 1) != 0 ? _buf484 : _buf493;
  return _defaultBuffers[gen.getByte() & 3];
}

class _RegisterInfo {
  int latency = 0;
  int lastOpGroup = ssInvalid;
  int lastOpPar = -1;
}

class _SsInstruction {
  _InstrInfo info = _nop;
  int src = -1, dst = -1, mod = 0, imm32 = 0;
  int opGroup = ssInvalid, opGroupPar = 0;
  bool canReuse = false, groupParIsSource = false;

  void createForSlot(Blake2Generator gen, int slotSize, int fetchType, bool isLast) {
    switch (slotSize) {
      case 3:
        create(isLast ? _slot3L[gen.getByte() & 3] : _slot3[gen.getByte() & 1], gen);
      case 4:
        if (fetchType == 4 && !isLast) {
          create(_imulRInfo, gen);
        } else {
          create(_slot4[gen.getByte() & 1], gen);
        }
      case 7:
        create(_slot7[gen.getByte() & 1], gen);
      case 8:
        create(_slot8[gen.getByte() & 1], gen);
      case 9:
        create(_slot9[gen.getByte() & 1], gen);
      case 10:
        create(_imulRcp, gen);
      default:
        throw StateError('bad slot size $slotSize');
    }
  }

  void create(_InstrInfo i, Blake2Generator gen) {
    info = i;
    src = dst = -1;
    canReuse = groupParIsSource = false;
    switch (i.type) {
      case ssIsubR:
        mod = 0;
        imm32 = 0;
        opGroup = ssIaddRs;
        groupParIsSource = true;
      case ssIxorR:
        mod = 0;
        imm32 = 0;
        opGroup = ssIxorR;
        groupParIsSource = true;
      case ssIaddRs:
        mod = gen.getByte();
        imm32 = 0;
        opGroup = ssIaddRs;
        groupParIsSource = true;
      case ssImulR:
        mod = 0;
        imm32 = 0;
        opGroup = ssImulR;
        groupParIsSource = true;
      case ssIrorC:
        mod = 0;
        do {
          imm32 = gen.getByte() & 63;
        } while (imm32 == 0);
        opGroup = ssIrorC;
        opGroupPar = -1;
      case ssIaddC7:
      case ssIaddC8:
      case ssIaddC9:
        mod = 0;
        imm32 = gen.getUInt32();
        opGroup = ssIaddC7;
        opGroupPar = -1;
      case ssIxorC7:
      case ssIxorC8:
      case ssIxorC9:
        mod = 0;
        imm32 = gen.getUInt32();
        opGroup = ssIxorC7;
        opGroupPar = -1;
      case ssImulhR:
        canReuse = true;
        mod = 0;
        imm32 = 0;
        opGroup = ssImulhR;
        opGroupPar = gen.getUInt32().toSigned(32);
      case ssIsmulhR:
        canReuse = true;
        mod = 0;
        imm32 = 0;
        opGroup = ssIsmulhR;
        opGroupPar = gen.getUInt32().toSigned(32);
      case ssImulRcp:
        mod = 0;
        do {
          imm32 = gen.getUInt32();
        } while (isZeroOrPowerOf2(imm32));
        opGroup = ssImulRcp;
        opGroupPar = -1;
    }
  }

  bool selectDestination(int cycle, bool allowChainedMul, List<_RegisterInfo> regs, Blake2Generator gen) {
    final available = <int>[];
    for (var i = 0; i < 8; i++) {
      final r = regs[i];
      if (r.latency <= cycle &&
          (canReuse || i != src) &&
          (allowChainedMul || opGroup != ssImulR || r.lastOpGroup != ssImulR) &&
          (r.lastOpGroup != opGroup || r.lastOpPar != opGroupPar) &&
          (info.type != ssIaddRs || i != registerNeedsDisplacement)) {
        available.add(i);
      }
    }
    if (available.isEmpty) return false;
    dst = available.length > 1 ? available[gen.getUInt32() % available.length] : available[0];
    return true;
  }

  bool selectSource(int cycle, List<_RegisterInfo> regs, Blake2Generator gen) {
    final available = <int>[];
    for (var i = 0; i < 8; i++) {
      if (regs[i].latency <= cycle) available.add(i);
    }
    if (available.length == 2 && info.type == ssIaddRs) {
      if (available[0] == registerNeedsDisplacement || available[1] == registerNeedsDisplacement) {
        opGroupPar = src = registerNeedsDisplacement;
        return true;
      }
    }
    if (available.isEmpty) return false;
    src = available.length > 1 ? available[gen.getUInt32() % available.length] : available[0];
    if (groupParIsSource) opGroupPar = src;
    return true;
  }
}

/// A generated SuperscalarHash program, pre-decoded for execution.
class SuperscalarProgram {
  /// Instruction type per slot.
  final Int32List type;
  final Int32List dst;
  final Int32List src;

  /// Shift for IADD_RS, rotation for IROR_C.
  final Int32List shift;

  /// Sign-extended immediate, or the precomputed reciprocal for IMUL_RCP.
  final Int64List imm;
  final int addressRegister;

  /// Raw fields in reference instruction format, for test vectors.
  final List<int> rawOpcode, rawDst, rawSrc, rawMod, rawImm32;

  SuperscalarProgram._(this.type, this.dst, this.src, this.shift, this.imm, this.addressRegister, this.rawOpcode,
      this.rawDst, this.rawSrc, this.rawMod, this.rawImm32);

  int get size => type.length;

  /// Bytes of the program in the reference `Instruction` layout (8 bytes
  /// each), as hashed by the RandomX generator tests.
  Uint8List toReferenceBytes() {
    final out = Uint8List(size * 8);
    for (var i = 0; i < size; i++) {
      out[8 * i] = rawOpcode[i];
      out[8 * i + 1] = rawDst[i];
      out[8 * i + 2] = rawSrc[i];
      out[8 * i + 3] = rawMod[i];
      writeU32LE(out, 8 * i + 4, rawImm32[i]);
    }
    return out;
  }

  static const int _cycleMapSize = rxSuperscalarLatency + 4;
  static const int _lookForwardCycles = 4;
  static const int _maxThrowawayCount = 256;

  static int _scheduleUop(int uop, List<Int32List> portBusy, int cycle, bool commit) {
    for (; cycle < _cycleMapSize; cycle++) {
      if ((uop & _p5) != 0 && portBusy[cycle][2] == 0) {
        if (commit) portBusy[cycle][2] = uop;
        return cycle;
      }
      if ((uop & _p0) != 0 && portBusy[cycle][0] == 0) {
        if (commit) portBusy[cycle][0] = uop;
        return cycle;
      }
      if ((uop & _p1) != 0 && portBusy[cycle][1] == 0) {
        if (commit) portBusy[cycle][1] = uop;
        return cycle;
      }
    }
    return -1;
  }

  static int _scheduleMop(_MacroOp mop, List<Int32List> portBusy, int cycle, int depCycle, bool commit) {
    if (mop.dependent && depCycle > cycle) cycle = depCycle;
    if (mop.isEliminated) return cycle;
    if (mop.isSimple) return _scheduleUop(mop.uop1, portBusy, cycle, commit);
    for (; cycle < _cycleMapSize; cycle++) {
      final c1 = _scheduleUop(mop.uop1, portBusy, cycle, false);
      final c2 = _scheduleUop(mop.uop2, portBusy, cycle, false);
      if (c1 >= 0 && c1 == c2) {
        if (commit) {
          _scheduleUop(mop.uop1, portBusy, c1, true);
          _scheduleUop(mop.uop2, portBusy, c2, true);
        }
        return c1;
      }
    }
    return -1;
  }

  static SuperscalarProgram generate(Blake2Generator gen) {
    final portBusy = List<Int32List>.generate(_cycleMapSize, (_) => Int32List(3));
    final regs = List<_RegisterInfo>.generate(8, (_) => _RegisterInfo());
    final opcodes = <int>[], dsts = <int>[], srcs = <int>[], mods = <int>[], imms = <int>[];

    _DecoderBuffer? decodeBuffer;
    final cur = _SsInstruction();
    var macroOpIndex = 0;
    var cycle = 0;
    var depCycle = 0;
    var portsSaturated = false;
    var programSize = 0;
    var mulCount = 0;
    var throwAwayCount = 0;

    for (var decodeCycle = 0;
        decodeCycle < rxSuperscalarLatency && !portsSaturated && programSize < rxSuperscalarMaxSize;
        decodeCycle++) {
      decodeBuffer = _fetchNext(cur.info.type, decodeCycle, mulCount, gen);
      var bufferIndex = 0;
      while (bufferIndex < decodeBuffer.size) {
        final topCycle = cycle;
        if (macroOpIndex >= cur.info.size) {
          if (portsSaturated || programSize >= rxSuperscalarMaxSize) break;
          cur.createForSlot(gen, decodeBuffer.counts[bufferIndex], decodeBuffer.index,
              decodeBuffer.size == bufferIndex + 1);
          macroOpIndex = 0;
        }
        final mop = cur.info.ops[macroOpIndex];
        var scheduleCycle = _scheduleMop(mop, portBusy, cycle, depCycle, false);
        if (scheduleCycle < 0) {
          portsSaturated = true;
          break;
        }

        if (macroOpIndex == cur.info.srcOp) {
          var forward = 0;
          for (; forward < _lookForwardCycles && !cur.selectSource(scheduleCycle, regs, gen); forward++) {
            scheduleCycle++;
            cycle++;
          }
          if (forward == _lookForwardCycles) {
            if (throwAwayCount < _maxThrowawayCount) {
              throwAwayCount++;
              macroOpIndex = cur.info.size;
              continue;
            }
            cur.info = _nop;
            break;
          }
        }

        if (macroOpIndex == cur.info.dstOp) {
          var forward = 0;
          for (;
              forward < _lookForwardCycles && !cur.selectDestination(scheduleCycle, throwAwayCount > 0, regs, gen);
              forward++) {
            scheduleCycle++;
            cycle++;
          }
          if (forward == _lookForwardCycles) {
            if (throwAwayCount < _maxThrowawayCount) {
              throwAwayCount++;
              macroOpIndex = cur.info.size;
              continue;
            }
            cur.info = _nop;
            break;
          }
        }
        throwAwayCount = 0;

        scheduleCycle = _scheduleMop(mop, portBusy, scheduleCycle, scheduleCycle, true);
        if (scheduleCycle < 0) {
          portsSaturated = true;
          break;
        }
        depCycle = scheduleCycle + mop.latency;

        if (macroOpIndex == cur.info.resultOp) {
          final ri = regs[cur.dst];
          ri.latency = depCycle;
          ri.lastOpGroup = cur.opGroup;
          ri.lastOpPar = cur.opGroupPar;
        }
        bufferIndex++;
        macroOpIndex++;

        if (scheduleCycle >= rxSuperscalarLatency) portsSaturated = true;
        cycle = topCycle;

        if (macroOpIndex >= cur.info.size) {
          opcodes.add(cur.info.type);
          dsts.add(cur.dst);
          srcs.add(cur.src >= 0 ? cur.src : cur.dst);
          mods.add(cur.mod);
          imms.add(cur.imm32);
          programSize++;
          final t = cur.info.type;
          if (t == ssImulR || t == ssImulhR || t == ssIsmulhR || t == ssImulRcp) mulCount++;
        }
      }
      cycle++;
    }

    // ASIC latency: 1 cycle per op, unlimited parallelism.
    final asic = List<int>.filled(8, 0);
    for (var i = 0; i < programSize; i++) {
      final d = dsts[i], s = srcs[i];
      final latDst = asic[d] + 1;
      final latSrc = d != s ? asic[s] + 1 : 0;
      asic[d] = latDst > latSrc ? latDst : latSrc;
    }
    var maxLat = 0, addressReg = 0;
    for (var i = 0; i < 8; i++) {
      if (asic[i] > maxLat) {
        maxLat = asic[i];
        addressReg = i;
      }
    }

    final type = Int32List(programSize), dst = Int32List(programSize), src = Int32List(programSize);
    final shift = Int32List(programSize);
    final imm = Int64List(programSize);
    for (var i = 0; i < programSize; i++) {
      type[i] = opcodes[i];
      dst[i] = dsts[i];
      src[i] = srcs[i];
      switch (opcodes[i]) {
        case ssIaddRs:
          shift[i] = (mods[i] >> 2) & 3;
        case ssIrorC:
          shift[i] = imms[i];
        case ssIaddC7 || ssIaddC8 || ssIaddC9 || ssIxorC7 || ssIxorC8 || ssIxorC9:
          imm[i] = signExtend32(imms[i]);
        case ssImulRcp:
          imm[i] = randomxReciprocal(imms[i]);
      }
    }
    return SuperscalarProgram._(type, dst, src, shift, imm, addressReg, opcodes, dsts, srcs, mods, imms);
  }

  /// Packed copy of (type, dst, src, shift) per instruction for execution.
  late final Int32List code = () {
    final c = Int32List(4 * size);
    for (var i = 0; i < size; i++) {
      c[4 * i] = type[i];
      c[4 * i + 1] = dst[i];
      c[4 * i + 2] = src[i];
      c[4 * i + 3] = shift[i];
    }
    return c;
  }();

  /// Runs the program on registers r[0..7].
  @pragma('vm:unsafe:no-bounds-checks')
  void execute(Int64List r) {
    final code = this.code, imm = this.imm;
    final n = code.length;
    for (var o = 0; o < n; o += 4) {
      final d = code[o + 1];
      switch (code[o]) {
        case ssIsubR:
          r[d] -= r[code[o + 2]];
        case ssIxorR:
          r[d] ^= r[code[o + 2]];
        case ssIaddRs:
          r[d] += r[code[o + 2]] << code[o + 3];
        case ssImulR:
          r[d] *= r[code[o + 2]];
        case ssIrorC:
          final x = r[d], c = code[o + 3];
          r[d] = (x >>> c) | (x << (64 - c));
        case ssIaddC7 || ssIaddC8 || ssIaddC9:
          r[d] += imm[o >> 2];
        case ssIxorC7 || ssIxorC8 || ssIxorC9:
          r[d] ^= imm[o >> 2];
        case ssImulhR:
          r[d] = mulhU64(r[d], r[code[o + 2]]);
        case ssIsmulhR:
          r[d] = mulhS64(r[d], r[code[o + 2]]);
        case ssImulRcp:
          r[d] *= imm[o >> 2];
      }
    }
  }
}
