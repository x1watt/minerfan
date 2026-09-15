import 'dart:io';

/// CPU layout for choosing mining threads on phones and other big.LITTLE
/// chips. RandomX wants about 2 MiB of cache per thread for its scratchpad,
/// and little cores (Cortex-A53/A55/A510/A520) add little hashrate but a lot
/// of heat, so the recommendation is: big cores only, capped by the L3.
///
/// Android often hides cache sizes from apps, so the L3 is estimated from
/// the core types in `/proc/cpuinfo` when sysfs does not report it.
class CpuTopology {
  /// Maximum frequency (kHz) per logical CPU; 0 when unknown.
  final List<int> maxKHz;

  /// ARM `CPU part` numbers seen in /proc/cpuinfo (implementer << 12 | part).
  final Set<int> parts;

  /// L3 size from sysfs, 0 when unknown.
  final int l3Bytes;

  /// Part number per logical CPU when /proc/cpuinfo lists them all (empty
  /// otherwise). Some SoCs give big and little cores the same maximum
  /// frequency (Unisoc T606: A75 and A55 both at 1.6 GHz), so core types
  /// decide there.
  final List<int> cpuParts;

  const CpuTopology(this.maxKHz, this.parts, this.l3Bytes, [this.cpuParts = const []]);

  // ARM implementer 0x41 parts.
  static const Set<int> _littleParts = {0x41d03, 0x41d05, 0x41d46, 0x41d80}; // A53, A55, A510, A520
  static const Set<int> _xParts = {0x41d44, 0x41d48, 0x41d4e, 0x41d82, 0x41d85, 0x41d87}; // X1..X925
  // Qualcomm Oryon (Snapdragon 8 Elite and later): large shared L2 per cluster.
  static const Set<int> _oryonParts = {0x51001};

  int get logical => maxKHz.length;

  /// CPUs outside the slowest cluster, when there is more than one cluster
  /// (all CPUs when the frequencies are equal or unknown).
  int get bigCores {
    if (cpuParts.length == logical && cpuParts.isNotEmpty) {
      final little = cpuParts.where(_littleParts.contains).length;
      if (little > 0 && little < logical) return logical - little;
    }
    final known = maxKHz.where((f) => f > 0).toList();
    if (known.length < logical || known.isEmpty) return logical;
    final lowest = known.reduce((a, b) => a < b ? a : b);
    final highest = known.reduce((a, b) => a > b ? a : b);
    if (highest == lowest) return logical;
    return known.where((f) => f > lowest).length;
  }

  bool get allLittle => parts.isNotEmpty && parts.every(_littleParts.contains);

  /// L3 (or shared last-level cache) in bytes: sysfs when present, else an
  /// estimate from the core types.
  int get estimatedL3 {
    if (l3Bytes > 0) return l3Bytes;
    if (parts.any(_oryonParts.contains)) return 12 << 20;
    if (parts.any(_xParts.contains)) return 8 << 20; // flagship SoCs: 6 to 12 MiB
    if (allLittle) return 1 << 20;
    if (parts.isNotEmpty) return 4 << 20; // mid-range big cores (A7x)
    return 0;
  }

  /// Mining threads for light mode: every core. Measured on a Unisoc T606
  /// with tevador's native benchmark: 1/2/4/6/8 threads gave
  /// 16.8/31.1/48.2/67.6/81.3 H/s. Light mode spends its time computing
  /// dataset items, which little cores help with as well.
  int get recommendedLightThreads => logical < 1 ? 1 : logical;

  /// Mining threads for fast mode: big cores, capped by the cache (2 MiB of
  /// L3 per scratchpad), at least one. (Not yet measured on a phone.)
  int get recommendedThreads {
    var n = allLittle ? (logical < 2 ? logical : 2) : bigCores;
    final l3 = estimatedL3;
    if (l3 > 0) {
      final byCache = l3 ~/ (2 << 20);
      if (byCache >= 1 && byCache < n) n = byCache;
    }
    return n < 1 ? 1 : n;
  }

  /// Reads the running system (Linux and Android sysfs, /proc/cpuinfo).
  static CpuTopology read() {
    final n = Platform.numberOfProcessors;
    final freqs = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      freqs[i] = _readInt('/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq');
    }
    var perCpu = <int>[];
    try {
      perCpu = parseCpuinfoPerCpu(File('/proc/cpuinfo').readAsStringSync());
    } catch (_) {}
    return CpuTopology(freqs, perCpu.where((p) => p != 0).toSet(), readSysfsL3(), perCpu.length == n ? perCpu : const []);
  }

  /// Part number per `processor` block of /proc/cpuinfo (0 if a block has
  /// no part line).
  static List<int> parseCpuinfoPerCpu(String cpuinfo) {
    final out = <int>[];
    var implementer = 0x41;
    for (final line in cpuinfo.split('\n')) {
      final i = line.indexOf(':');
      if (i < 0) continue;
      final key = line.substring(0, i).trim();
      final value = line.substring(i + 1).trim();
      if (key == 'processor') {
        out.add(0);
      } else if (key == 'CPU implementer') {
        implementer = int.tryParse(value) ?? implementer;
      } else if (key == 'CPU part' && out.isNotEmpty) {
        final p = int.tryParse(value);
        if (p != null) out[out.length - 1] = (implementer << 12) | p;
      }
    }
    return out;
  }

  /// `CPU implementer` and `CPU part` lines from /proc/cpuinfo.
  static Set<int> parseCpuinfoParts(String cpuinfo) {
    final out = <int>{};
    var implementer = 0x41;
    for (final line in cpuinfo.split('\n')) {
      final i = line.indexOf(':');
      if (i < 0) continue;
      final key = line.substring(0, i).trim();
      final value = line.substring(i + 1).trim();
      if (key == 'CPU implementer') {
        implementer = int.tryParse(value) ?? implementer; // "0x41" parses as hex
      } else if (key == 'CPU part') {
        final p = int.tryParse(value);
        if (p != null) out.add((implementer << 12) | p);
      }
    }
    return out;
  }

  /// The level-3 cache size of cpu0 from sysfs (any index), 0 if absent.
  static int readSysfsL3() {
    for (var idx = 0; idx < 8; idx++) {
      final base = '/sys/devices/system/cpu/cpu0/cache/index$idx';
      try {
        if (File('$base/level').readAsStringSync().trim() != '3') continue;
        return parseCacheSize(File('$base/size').readAsStringSync());
      } catch (_) {
        continue;
      }
    }
    return 0;
  }

  static int parseCacheSize(String s) {
    s = s.trim();
    final n = int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (s.endsWith('K')) return n * 1024;
    if (s.endsWith('M')) return n * 1024 * 1024;
    return n;
  }

  static int _readInt(String path) {
    try {
      return int.parse(File(path).readAsStringSync().trim());
    } catch (_) {
      return 0;
    }
  }

  @override
  String toString() => '$logical CPUs, $bigCores big, L3 ${estimatedL3 >> 20} MiB'
      '${l3Bytes == 0 && estimatedL3 > 0 ? ' (estimated)' : ''}, $recommendedThreads mining threads';
}
