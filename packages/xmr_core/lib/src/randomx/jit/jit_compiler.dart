import 'dart:typed_data';

import '../superscalar.dart';
import 'exec_memory.dart';
import 'jit_a64.dart';
import 'jit_x64.dart';

/// What the JIT VM needs from an architecture's compiler (x86-64 or ARM64).
abstract class RandomXJitCompiler {
  bool get v2;
  set v2(bool value);

  /// The generated program: `void(RegisterFile*, MemoryRegisters*, scratchpad, iterations)`.
  int get programAddress;

  /// `void(uint8_t** cacheMemory, dataset, start, end)`, after
  /// [generateSuperscalarHash] and [generateDatasetInitCode].
  int get datasetInitAddress;

  /// FP control word a hash starts with (MXCSR on x86-64, FPCR on ARM64).
  int get initialFpControl;

  /// ARM64 reads the E or-mask from `RegisterFile.f[0]`.
  bool get eMaskInRegisterFile;

  void generateProgram(Uint8List prog, int eMask0, int eMask1, List<int> readReg);
  void generateProgramLight(Uint8List prog, int eMask0, int eMask1, List<int> readReg, int datasetOffset);
  void generateSuperscalarHash(List<SuperscalarProgram> programs);
  void generateDatasetInitCode();
  void free();

  static RandomXJitCompiler create({int index = 0}) =>
      ExecMemory.isArm64 ? JitA64() : JitX64(codeOffsetIndex: index);
}
