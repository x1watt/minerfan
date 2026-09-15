import 'dart:ffi';
import 'dart:io' show File, Platform;

import '../randomx/memory_ffi.dart' show allocateShared, freeShared;

/// CPU time of the whole machine (all CPUs) and of this process, in the same
/// unit, so the share taken by other programs can be told apart from ours.
class CpuTimes {
  /// Time the CPUs were not idle.
  final int busy;

  /// All time of all CPUs.
  final int total;

  /// Time this process used (user plus system).
  final int own;

  const CpuTimes(this.busy, this.total, this.own);
}

/// Reads [CpuTimes]: Linux from /proc, Windows through `GetSystemTimes` and
/// `GetProcessTimes`. Null elsewhere, and on Android, which hides
/// /proc/stat from apps.
abstract final class SystemLoad {
  static CpuTimes? cpuTimes() {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        return parseLinux(File('/proc/stat').readAsStringSync(), File('/proc/self/stat').readAsStringSync());
      }
      if (Platform.isWindows) return _windows();
    } catch (_) {}
    return null;
  }

  /// Cores' worth of CPU that other programs used between [a] and [b], on a
  /// machine with [cpus] logical CPUs.
  static double otherCores(CpuTimes a, CpuTimes b, int cpus) {
    final dt = b.total - a.total;
    if (dt <= 0) return 0;
    final other = (b.busy - a.busy) - (b.own - a.own);
    return (other / dt * cpus).clamp(0, cpus.toDouble());
  }

  /// The `cpu` line of /proc/stat (user nice system idle iowait irq softirq
  /// steal, in clock ticks) and utime/stime of /proc/self/stat (same ticks).
  static CpuTimes? parseLinux(String procStat, String selfStat) {
    final line = procStat.split('\n').firstWhere((l) => l.startsWith('cpu '), orElse: () => '');
    if (line.isEmpty) return null;
    final f = line.trim().split(RegExp(r'\s+')).skip(1).map(int.parse).toList();
    if (f.length < 5) return null;
    var total = 0;
    for (var i = 0; i < f.length && i < 8; i++) {
      total += f[i]; // guest time is already counted in user
    }
    final idle = f[3] + f[4];
    // Fields after the command name, which may contain spaces: state is
    // field 3, utime field 14 and stime field 15.
    final rest = selfStat.substring(selfStat.lastIndexOf(')') + 2).split(' ');
    if (rest.length < 13) return null;
    final own = int.parse(rest[11]) + int.parse(rest[12]);
    return CpuTimes(total - idle, total, own);
  }

  static CpuTimes? _windows() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final systemTimes = k32.lookupFunction<Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetSystemTimes');
    final currentProcess = k32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
    final processTimes = k32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes');
    final addr = allocateShared(8 * 8);
    try {
      Pointer<Uint64> slot(int i) => Pointer<Uint64>.fromAddress(addr + 8 * i);
      // FILETIMEs in 100 ns units; kernel time includes idle time.
      if (systemTimes(slot(0), slot(1), slot(2)) == 0) return null;
      if (processTimes(currentProcess(), slot(3), slot(4), slot(5), slot(6)) == 0) return null;
      final idle = slot(0).value, kernel = slot(1).value, user = slot(2).value;
      final total = kernel + user;
      return CpuTimes(total - idle, total, slot(5).value + slot(6).value);
    } finally {
      freeShared(addr);
    }
  }
}
