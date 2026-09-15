import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import '../../util/u64.dart';
import '../aes_gen.dart';
import '../cache.dart';
import '../config.dart';
import '../memory.dart';
import '../vm.dart';
import 'aes_native.dart';
import 'cpu_features.dart';
import 'exec_memory.dart';
import 'jit_compiler.dart';

/// RandomX VM running JIT-compiled programs (x86-64), driven like xmrig's
/// `CompiledVm`/`CompiledLightVm` (BSD-3-Clause). Blake2b and program
/// decoding run in Dart; scratchpad fill, the 8 programs and the final AES
/// hash run as machine code.
///
/// The cache (light mode) or dataset (fast mode) must live in shared
/// (native) memory.
typedef _ProgramC = Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint64);
typedef _Program = void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int);

// Layout of the VM's native block: the scratchpad first, on a 2 MiB
// boundary so it can be one transparent huge page (with SMT two threads
// share a TLB, and 512 small pages per scratchpad thrash it).
const int _scratchpadOff = 0;
const int _tempHashOff = rxScratchpadL3; // 64
const int _regFileOff = _tempHashOff + 64; // 256 (16-byte aligned)
const int _memRegsOff = _regFileOff + 256; // mx, ma, memory, rx mxcsr, caller mxcsr
const int _programOff = _memRegsOff + 64; // 128 + 384 * 8 = 3200
const int _blockSize = _programOff + 3200;

class RandomXJitVM implements RandomXHasher {
  final RandomXCache? cache;
  final RandomXDataset? dataset;
  @override
  bool v2;

  final RandomXJitCompiler _jit;
  /// Hardware AES routines; null on CPUs without AES instructions, where the
  /// scratchpad fill and hash run in Dart (v1 programs still run as machine
  /// code; v2 needs AES inside the program and uses the interpreter).
  final AesNative? _aes;
  RandomXVM? _v2Fallback;
  late final Uint32List _u32 = Pointer<Uint32>.fromAddress(_base).asTypedList(_blockSize ~/ 4);
  late final Uint32List _tempWords = Uint32List.sublistView(_u32, _tempHashOff ~/ 4, _tempHashOff ~/ 4 + 16);
  late final Uint32List _scratchWords = Uint32List.sublistView(_u32, _scratchpadOff ~/ 4, (_scratchpadOff + rxScratchpadL3) ~/ 4);
  late final Uint32List _programWords = Uint32List.sublistView(_u32, _programOff ~/ 4, (_programOff + 3200) ~/ 4);
  late final Uint32List _regWords = Uint32List.sublistView(_u32, _regFileOff ~/ 4, (_regFileOff + 256) ~/ 4);

  bool get hardwareAes => _aes != null;
  final NativePages _block;
  final int _base;
  late final Uint8List _bytes = Pointer<Uint8>.fromAddress(_base).asTypedList(_blockSize);
  late final ByteData _bd = ByteData.sublistView(_bytes);
  late final Uint8List _program = Uint8List.sublistView(_bytes, _programOff, _programOff + 3200);
  late final Uint8List _regFile = Uint8List.sublistView(_bytes, _regFileOff, _regFileOff + 256);
  late final _Program _run =
      Pointer<NativeFunction<_ProgramC>>.fromAddress(_jit.programAddress).asFunction<_Program>();
  final List<int> _readReg = List.filled(4, 0);
  final Blake2b _b64 = Blake2b(64), _b32 = Blake2b(32);
  late final Pointer<Void> _pTemp = Pointer.fromAddress(_base + _tempHashOff);
  late final Pointer<Void> _pRegFile = Pointer.fromAddress(_base + _regFileOff);
  late final Pointer<Void> _pRegA = Pointer.fromAddress(_base + _regFileOff + 192);
  late final Pointer<Void> _pMemRegs = Pointer.fromAddress(_base + _memRegsOff);
  late final Pointer<Void> _pProgram = Pointer.fromAddress(_base + _programOff);
  late final Pointer<Void> _pScratchpad = Pointer.fromAddress(_base + _scratchpadOff);

  RandomXJitVM._(this.cache, this.dataset, this.v2, this._jit, this._aes, this._block)
      : _base = _block.address;

  /// True if this CPU/OS can run the JIT VM: x86-64 or ARM64 on an OS that
  /// allows executable memory. Hardware AES makes it faster but is optional.
  static bool get supported {
    if (!ExecMemory.supported) return false;
    final cpu = CpuFeatures.current;
    return cpu.x64 || cpu.arm64;
  }

  static RandomXJitVM light(RandomXCache cache, {bool v2 = false, int index = 0, bool hardwareAes = true}) {
    if (cache.buffer.kind != RxMemoryKind.shared) throw ArgumentError('the JIT needs a cache in shared memory');
    final jit = RandomXJitCompiler.create(index: index)..v2 = v2;
    jit.generateSuperscalarHash(cache.programs);
    return RandomXJitVM._(cache, null, v2, jit, hardwareAes ? AesNative.instance : null, _allocBlock());
  }

  static RandomXJitVM fast(RandomXDataset dataset, {bool v2 = false, int index = 0, bool hardwareAes = true}) {
    if (dataset.buffer.kind != RxMemoryKind.shared) throw ArgumentError('the JIT needs a dataset in shared memory');
    final jit = RandomXJitCompiler.create(index: index)..v2 = v2;
    return RandomXJitVM._(null, dataset, v2, jit, hardwareAes ? AesNative.instance : null, _allocBlock());
  }

  static NativePages _allocBlock() => NativePages.allocate(_blockSize);

  @override
  void free() {
    _jit.free();
    _block.free();
  }

  /// RandomX hash of [input].
  @override
  Uint8List hash(List<int> input) {
    final out = Uint8List(32);
    hashInto(input, out, 0);
    return out;
  }

  /// RandomX hash of [input] written to [out] at [offset], allocation free.
  @override
  void hashInto(List<int> input, Uint8List out, int offset) {
    final aes = _aes;
    if (v2 && aes == null) {
      final f = _v2Fallback ??= dataset != null ? RandomXVM.fast(dataset!) : RandomXVM.light(cache!);
      f.v2 = true;
      f.hashInto(input, out, offset);
      return;
    }
    _b64
      ..reset()
      ..update(input)
      ..digestInto(_bytes, _tempHashOff);
    if (aes != null) {
      aes.fillAes1Rx4(_pTemp, rxScratchpadL3, _pScratchpad);
    } else {
      fillAes1Rx4(_tempWords, _scratchWords, 0, _scratchWords.length);
    }
    _bd.setUint32(_memRegsOff + 16, _jit.initialFpControl, Endian.little); // round to nearest
    _jit.v2 = v2;
    final progBytes = 128 + (v2 ? rxProgramSizeV2 : rxProgramSizeV1) * 8;
    for (var chain = 0; chain < rxProgramCount; chain++) {
      if (aes != null) {
        aes.fillAes4Rx4(_pTemp, progBytes, _pProgram);
      } else {
        fillAes4Rx4(_tempWords, _programWords, progBytes ~/ 4);
      }
      _runProgram();
      if (chain < rxProgramCount - 1) {
        _b64
          ..reset()
          ..update(_regFile)
          ..digestInto(_bytes, _tempHashOff);
      }
    }
    if (aes != null) {
      aes.hashAes1Rx4(_pScratchpad, rxScratchpadL3, _pRegA);
    } else {
      hashAes1Rx4(_scratchWords, _regWords, 48);
    }
    _b32
      ..reset()
      ..update(_regFile)
      ..digestInto(out, offset);
  }

  int _entropy(int i) => _bd.getInt64(_programOff + 8 * i, Endian.little);

  void _runProgram() {
    final e = _bd;
    for (var i = 0; i < 8; i++) {
      e.setInt64(_regFileOff + 192 + 8 * i, _smallPositiveFloatBits(_entropy(i)), Endian.little);
    }
    final ma = _entropy(8) & cacheLineAlignMask;
    final mx = _entropy(10) & 0xffffffff;
    final addressRegisters = _entropy(12);
    _readReg[0] = addressRegisters & 1;
    _readReg[1] = 2 + ((addressRegisters >> 1) & 1);
    _readReg[2] = 4 + ((addressRegisters >> 2) & 1);
    _readReg[3] = 6 + ((addressRegisters >> 3) & 1);
    final datasetOffset = umodU64By32(_entropy(13), datasetExtraItems + 1) * cacheLineSize;
    final eMask0 = _floatMask(_entropy(14));
    final eMask1 = _floatMask(_entropy(15));
    e.setUint32(_memRegsOff, mx, Endian.little);
    e.setUint32(_memRegsOff + 4, ma, Endian.little);
    if (_jit.eMaskInRegisterFile) {
      e.setInt64(_regFileOff + 64, eMask0, Endian.little);
      e.setInt64(_regFileOff + 72, eMask1, Endian.little);
    }
    final ds = dataset;
    if (ds != null) {
      _jit.generateProgram(_program, eMask0, eMask1, _readReg);
      e.setInt64(_memRegsOff + 8, ds.buffer.address + datasetOffset, Endian.little);
    } else {
      _jit.generateProgramLight(_program, eMask0, eMask1, _readReg, datasetOffset);
      e.setInt64(_memRegsOff + 8, cache!.buffer.address, Endian.little);
    }
    _run(_pRegFile, _pMemRegs, _pScratchpad, rxProgramIterations);
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
}

typedef _DatasetInitC = Void Function(Pointer<Void>, Pointer<Void>, Uint64, Uint64);
typedef _DatasetInit = void Function(Pointer<Void>, Pointer<Void>, int, int);

/// Compiled dataset initialisation for one cache (fast mode). Built once;
/// [initAddress] and [cacheSlot] can be passed to other isolates, which call
/// [initRange] on the same code.
class JitDatasetInit {
  final RandomXJitCompiler? _jit;
  final RxBuffer? _slot;
  final int initAddress;
  final int cacheSlot;

  JitDatasetInit._(this._jit, this._slot, this.initAddress, this.cacheSlot);

  static JitDatasetInit build(RandomXCache cache) {
    if (cache.buffer.kind != RxMemoryKind.shared) throw ArgumentError('the JIT needs a cache in shared memory');
    final jit = RandomXJitCompiler.create();
    jit.generateSuperscalarHash(cache.programs);
    jit.generateDatasetInitCode();
    final slot = RxBuffer.allocate(1, RxMemoryKind.shared)..words[0] = cache.buffer.address;
    return JitDatasetInit._(jit, slot, jit.datasetInitAddress, slot.address);
  }

  /// Fills dataset items [start, end) at [datasetAddress]; callable from any
  /// isolate with the addresses of a built instance.
  static void initRange(int initAddress, int cacheSlot, int datasetAddress, int start, int end) {
    final f = Pointer<NativeFunction<_DatasetInitC>>.fromAddress(initAddress).asFunction<_DatasetInit>();
    f(Pointer.fromAddress(cacheSlot), Pointer.fromAddress(datasetAddress + start * 64), start, end);
  }

  void free() {
    _jit?.free();
    _slot?.free();
  }
}

/// Hashes tevador's test vector (a) with the JIT in light mode and reports
/// the result; for diagnostics on new devices (256 MiB, a few seconds).
String jitSelfCheck() {
  if (!RandomXJitVM.supported) return 'JIT unavailable (${CpuFeatures.current})';
  final key = 'test key 000'.codeUnits;
  final cache = RandomXCache.create(key, kind: RxMemoryKind.shared);
  try {
    final vm = RandomXJitVM.light(cache);
    final clock = Stopwatch()..start();
    final h = vm.hash('This is a test'.codeUnits);
    final ms = clock.elapsedMilliseconds;
    vm.free();
    final hex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final ok = hex == '639183aae1bf4c9a35884cb46b09cad9175f04efd7684e7262a0ac1c2f0b4e3f';
    final mapping = ExecMemory.allowRwx ? 'rwx allowed' : 'w^x';
    return '${ok ? 'OK' : 'MISMATCH $hex'} (${CpuFeatures.current}, $mapping, light hash $ms ms)';
  } finally {
    cache.free();
  }
}
