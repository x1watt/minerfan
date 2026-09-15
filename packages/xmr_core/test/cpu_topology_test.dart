import 'package:test/test.dart';
import 'package:xmr_core/src/randomx/jit/cpu_topology.dart';

// Frequencies (kHz) and CPU part numbers of real SoCs, as their sysfs and
// /proc/cpuinfo report them.
const a53 = 0x41d03, a55 = 0x41d05, a510 = 0x41d46, a76 = 0x41d0b, a78 = 0x41d41;
const a75 = 0x41d0a, a710 = 0x41d47, a715 = 0x41d4d, x1 = 0x41d44, x3 = 0x41d4e;

void main() {
  test('Snapdragon 8 Gen 2: 3 little, 4 big, 1 prime; L3 hidden', () {
    final t = CpuTopology([2016000, 2016000, 2016000, 2803200, 2803200, 2803200, 2803200, 3187200],
        {a510, a715, a710, x3}, 0);
    expect(t.bigCores, 5);
    expect(t.estimatedL3, 8 << 20);
    expect(t.recommendedThreads, 4); // 8 MiB / 2 MiB
  });

  test('Snapdragon 778G: 4 little, 4 A78', () {
    final t = CpuTopology([1804800, 1804800, 1804800, 1804800, 2419200, 2419200, 2419200, 2515200], {a55, a78}, 0);
    expect(t.bigCores, 4);
    expect(t.recommendedThreads, 2); // 4 MiB estimate
  });

  test('Tensor G1: 4 little, 2 A76, 2 X1', () {
    final t = CpuTopology([1803000, 1803000, 1803000, 1803000, 2253000, 2253000, 2802000, 2802000], {a55, a76, x1}, 0);
    expect(t.bigCores, 4);
    expect(t.recommendedThreads, 4);
  });

  test('budget octa-core A53: two threads at most', () {
    final t = CpuTopology(List.filled(8, 1804800), {a53}, 0);
    expect(t.allLittle, isTrue);
    expect(t.recommendedThreads, 2);
  });

  test('a reported L3 wins over the estimate', () {
    final t = CpuTopology([1804800, 1804800, 2419200, 2419200], {a55, a78}, 2 << 20);
    expect(t.recommendedThreads, 1);
  });

  test('unknown layout (no cpufreq, no ARM parts): all CPUs', () {
    const t = CpuTopology([0, 0, 0, 0], {}, 0);
    expect(t.recommendedThreads, 4);
  });

  test('Unisoc T606: 2 A75 and 6 A55 at the same frequency; types decide', () {
    final t = CpuTopology(List.filled(8, 1612000), {a55, a75}, 0, [a55, a55, a55, a55, a55, a55, a75, a75]);
    expect(t.bigCores, 2);
    expect(t.recommendedThreads, 2); // fast mode
    expect(t.recommendedLightThreads, 8); // measured: 81 H/s on 8 threads vs 31 on 2
  });

  test('parses /proc/cpuinfo implementer and part lines', () {
    const cpuinfo = '''
processor\t: 0
BogoMIPS\t: 38.40
CPU implementer\t: 0x41
CPU architecture: 8
CPU part\t: 0xd46

processor\t: 7
CPU implementer\t: 0x41
CPU part\t: 0xd4e

processor\t: 8
CPU implementer\t: 0x51
CPU part\t: 0x001
''';
    expect(CpuTopology.parseCpuinfoParts(cpuinfo), {a510, x3, 0x51001});
    expect(CpuTopology.parseCpuinfoPerCpu(cpuinfo), [a510, x3, 0x51001]);
    expect(CpuTopology.parseCacheSize('8192K\n'), 8 << 20);
    expect(CpuTopology.parseCacheSize('2M'), 2 << 20);
  });
}
