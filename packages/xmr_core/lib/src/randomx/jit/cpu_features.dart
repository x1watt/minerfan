import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../memory.dart';
import 'asm_x64.dart';
import 'cpu_topology.dart';
import 'exec_memory.dart';

/// What the JIT needs to know about the CPU. x86-64 reads CPUID through a
/// tiny generated stub; ARM64 asks the OS (auxv on Linux/Android).
class CpuFeatures {
  final bool x64, arm64;
  final bool aes, avx, avx2, bmi2, xop;
  final String vendor; // GenuineIntel, AuthenticAMD, ...
  final int family, model, stepping;

  /// L3 cache in bytes (0 when unknown).
  final int l3Bytes;

  const CpuFeatures({
    this.x64 = false,
    this.arm64 = false,
    this.aes = false,
    this.avx = false,
    this.avx2 = false,
    this.bmi2 = false,
    this.xop = false,
    this.vendor = '',
    this.family = 0,
    this.model = 0,
    this.stepping = 0,
    this.l3Bytes = 0,
  });

  bool get isAmd => vendor == 'AuthenticAMD' || vendor == 'HygonGenuine';
  bool get isIntel => vendor == 'GenuineIntel';

  /// Intel cores with the JCC erratum (branches must not touch a 32-byte
  /// boundary). Family 6 models from Skylake to Cascade Lake/Comet Lake.
  bool get jccErratum {
    if (!isIntel || family != 6) return false;
    const models = {0x4E, 0x55, 0x5E, 0x8E, 0x9E, 0xA5, 0xA6};
    return models.contains(model);
  }

  static CpuFeatures? _cached;
  static CpuFeatures get current => _cached ??= _detect();

  static CpuFeatures _detect() {
    try {
      if (ExecMemory.isX64) return _detectX64();
      if (ExecMemory.isArm64) return _detectArm64();
    } catch (_) {}
    return const CpuFeatures();
  }

  static CpuFeatures _detectX64() {
    final a = X64();
    if (Platform.isWindows) {
      // rcx = leaf, rdx = subleaf, r8 = out
      a.movRR32(rax, rcx);
      a.movRR32(rcx, rdx);
      a.push(rbx);
      a.dbs(const [0x0F, 0xA2]); // cpuid
      a.movMR32(const Mem(r8), rax);
      a.movMR32(const Mem(r8, disp: 4), rbx);
      a.movMR32(const Mem(r8, disp: 8), rcx);
      a.movMR32(const Mem(r8, disp: 12), rdx);
      a.pop(rbx);
      a.ret();
    } else {
      // rdi = leaf, rsi = subleaf, rdx = out
      a.movRR(r8, rdx);
      a.movRR32(rax, rdi);
      a.movRR32(rcx, rsi);
      a.push(rbx);
      a.dbs(const [0x0F, 0xA2]);
      a.movMR32(const Mem(r8), rax);
      a.movMR32(const Mem(r8, disp: 4), rbx);
      a.movMR32(const Mem(r8, disp: 8), rcx);
      a.movMR32(const Mem(r8, disp: 12), rdx);
      a.pop(rbx);
      a.ret();
    }
    final mem = ExecMemory.allocate(4096);
    final out = RxBuffer.allocate(2, RxMemoryKind.shared);
    try {
      mem.bytes.setRange(0, a.pos, a.bytes);
      mem.executable();
      final f = Pointer<NativeFunction<Void Function(Uint32, Uint32, Pointer<Uint32>)>>.fromAddress(mem.address)
          .asFunction<void Function(int, int, Pointer<Uint32>)>();
      final regs = Pointer<Uint32>.fromAddress(out.address).asTypedList(4);
      (int, int, int, int) cpuid(int leaf, [int sub = 0]) {
        f(leaf, sub, Pointer.fromAddress(out.address));
        return (regs[0], regs[1], regs[2], regs[3]);
      }

      final (maxLeaf, vb, vc, vd) = cpuid(0);
      final vendor = String.fromCharCodes(Uint8List.view(Uint32List.fromList([vb, vd, vc]).buffer));
      final (sig, _, ecx1, _) = maxLeaf >= 1 ? cpuid(1) : (0, 0, 0, 0);
      final (_, ebx7, _, _) = maxLeaf >= 7 ? cpuid(7, 0) : (0, 0, 0, 0);
      final (maxExt, _, _, _) = cpuid(0x80000000);
      final (_, _, ecxE1, _) = maxExt >= 0x80000001 ? cpuid(0x80000001) : (0, 0, 0, 0);
      var family = (sig >> 8) & 0xf;
      var model = (sig >> 4) & 0xf;
      if (family == 0xf) family += (sig >> 20) & 0xff;
      if (family == 6 || family >= 0xf) model |= ((sig >> 16) & 0xf) << 4;

      // OS support for AVX state (OSXSAVE + XGETBV is not needed for the
      // instructions used: vzeroupper only matters when AVX exists at all).
      final avx = (ecx1 & (1 << 28)) != 0 && (ecx1 & (1 << 27)) != 0;

      var l3 = 0;
      // Deterministic cache parameters: leaf 4 (Intel) or 0x8000001D (AMD).
      final cacheLeaf = vendor == 'GenuineIntel' ? 4 : (maxExt >= 0x8000001D ? 0x8000001D : -1);
      if (cacheLeaf > 0) {
        for (var i = 0; i < 16; i++) {
          final (ea, eb, ec, _) = cpuid(cacheLeaf, i);
          final type = ea & 0x1f;
          if (type == 0) break;
          final level = (ea >> 5) & 7;
          if (level == 3) {
            final ways = ((eb >> 22) & 0x3ff) + 1;
            final parts = ((eb >> 12) & 0x3ff) + 1;
            final line = (eb & 0xfff) + 1;
            final sets = ec + 1;
            final sharing = ((ea >> 14) & 0xfff) + 1;
            final cpus = Platform.numberOfProcessors;
            // Total L3 over all cache instances (one per CCX on AMD).
            l3 = ways * parts * line * sets * ((cpus + sharing - 1) ~/ sharing);
          }
        }
      }
      if (l3 == 0) l3 = _sysfsL3();

      return CpuFeatures(
        x64: true,
        aes: (ecx1 & (1 << 25)) != 0,
        avx: avx,
        avx2: avx && (ebx7 & (1 << 5)) != 0,
        bmi2: (ebx7 & (1 << 8)) != 0,
        xop: (ecxE1 & (1 << 11)) != 0,
        vendor: vendor,
        family: family,
        model: model,
        stepping: sig & 0xf,
        l3Bytes: l3,
      );
    } finally {
      mem.free();
      out.free();
    }
  }

  static CpuFeatures _detectArm64() {
    var aes = false;
    if (Platform.isMacOS || Platform.isIOS) {
      aes = true; // every Apple ARM64 CPU has the crypto extension
    } else if (Platform.isLinux || Platform.isAndroid) {
      try {
        final getauxval = DynamicLibrary.process()
            .lookupFunction<UnsignedLong Function(UnsignedLong), int Function(int)>('getauxval');
        const atHwcap = 16, hwcapAes = 1 << 3;
        aes = (getauxval(atHwcap) & hwcapAes) != 0;
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        final f = DynamicLibrary.open('kernel32.dll')
            .lookupFunction<Int32 Function(Uint32), int Function(int)>('IsProcessorFeaturePresent');
        const pfArmV8Crypto = 30;
        aes = f(pfArmV8Crypto) != 0;
      } catch (_) {}
    }
    return CpuFeatures(arm64: true, aes: aes, l3Bytes: _sysfsL3());
  }

  static int _sysfsL3() => CpuTopology.readSysfsL3();

  static CpuTopology? _topology;

  /// Core clusters and cache layout (Linux/Android sysfs, /proc/cpuinfo).
  static CpuTopology get topology => _topology ??= CpuTopology.read();

  /// Mining threads to use by default.
  /// - x86-64 desktops: one per physical core (measured best; SMT siblings
  ///   mostly compete for cache).
  /// - ARM (phones, boards), light mode: every core (measured on a phone:
  ///   the little cores add about 8 H/s each).
  /// - ARM, fast mode: big cores capped by the L3, 2 MiB per thread.
  static int recommendedThreads({bool fastMode = false}) {
    // ARM cores have no SMT, and sysfs core ids repeat per cluster there,
    // so the topology result is used as is.
    if (current.arm64) return fastMode ? topology.recommendedThreads : topology.recommendedLightThreads;
    final phys = physicalCores();
    if (Platform.isAndroid) {
      final t = topology.recommendedThreads; // x86-64 Android (emulators, Chromebooks)
      return t < phys ? t : phys;
    }
    return phys;
  }

  /// Physical cores (Linux/Android from sysfs topology; elsewhere logical
  /// processors, halved when there are many of them since SMT is likely).
  static int? _physicalCores;
  static int physicalCores() => _physicalCores ??= _countPhysicalCores();

  static int _countPhysicalCores() {
    final logical = Platform.numberOfProcessors;
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        final cores = <String>{};
        for (var i = 0; i < logical; i++) {
          final t = '/sys/devices/system/cpu/cpu$i/topology';
          final pkg = File('$t/physical_package_id').readAsStringSync().trim();
          final core = File('$t/core_id').readAsStringSync().trim();
          cores.add('$pkg:$core');
        }
        if (cores.isNotEmpty) return cores.length;
      }
    } catch (_) {}
    if ((Platform.isWindows || Platform.isLinux) && logical >= 8 && current.x64) return logical ~/ 2;
    return logical;
  }

  /// Mining threads by xmrig's rule of thumb: each RandomX thread wants
  /// 2 MiB of L3 for its scratchpad; never more than [cores] - 1.
  int suggestedThreads(int cores) {
    final max = cores > 1 ? cores - 1 : 1;
    if (l3Bytes <= 0) return max;
    final byCache = l3Bytes ~/ (2 << 20);
    return byCache < 1 ? 1 : (byCache < max ? byCache : max);
  }

  @override
  String toString() => x64
      ? '$vendor family ${family.toRadixString(16)} model ${model.toRadixString(16)}'
          '${aes ? ' AES' : ''}${avx2 ? ' AVX2' : ''}${bmi2 ? ' BMI2' : ''}, L3 ${l3Bytes >> 20} MiB'
      : (arm64 ? 'ARM64${aes ? ' AES' : ''}' : 'unsupported CPU');
}
