import 'dart:io';

import 'package:test/test.dart';
import 'package:xmr_core/src/node/flex.dart';
import 'package:xmr_core/src/node/system_load.dart';

const gib = 1 << 30;
const dataset = 2080 << 20;

void main() {
  group('FlexGovernor CPU', () {
    test('unknown readings leave every thread on', () {
      final g = FlexGovernor(8);
      expect(g.update(const FlexReading(), 0), 8);
      expect(g.note, isEmpty);
    });

    test('other programs take threads off at once and give them back slowly', () {
      final g = FlexGovernor(8, upStepMs: 6000);
      expect(g.update(const FlexReading(otherCores: 2.6), 0), 6);
      expect(g.note, contains('other programs use 2.6 cores'));
      // Load gone: smoothing first, then one thread per 6 s.
      var t = 0;
      final seen = <int>[];
      while (t < 60000) {
        t += 2000;
        seen.add(g.update(const FlexReading(otherCores: 0), t));
      }
      expect(seen.last, 8);
      expect(seen.first, 6);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i] - seen[i - 1], inInclusiveRange(0, 1));
      }
      expect(g.note, isEmpty);
    });

    test('a load near a core boundary does not flap', () {
      final g = FlexGovernor(8, upStepMs: 6000);
      g.update(const FlexReading(otherCores: 2.9), 0);
      expect(g.threads, 5);
      for (var t = 2000; t < 60000; t += 2000) {
        g.update(FlexReading(otherCores: t % 4000 == 0 ? 2.5 : 2.9), t);
        expect(g.threads, 5);
      }
    });

    test('a machine full of other work pauses mining; light background use does not count', () {
      final g = FlexGovernor(8);
      expect(g.update(const FlexReading(otherCores: 0.5), 0), 8);
      expect(g.update(const FlexReading(otherCores: 16), 2000), 0);
    });
  });

  group('FlexGovernor RAM', () {
    test('low memory gives the dataset back; it comes back only with room to spare for minutes', () {
      final g = FlexGovernor(8, datasetBytes: dataset, datasetBackMs: 180000);
      const total = 16 * gib;
      expect(g.update(const FlexReading(availableBytes: 5 * gib, totalBytes: total), 0), 8);
      expect(g.datasetWanted, isTrue);
      g.update(const FlexReading(availableBytes: 2 * gib, totalBytes: total), 2000); // below 15%
      expect(g.datasetWanted, isFalse);
      expect(g.note, contains('fast mode off'));
      expect(g.threads, 8); // light mode keeps mining
      // Freed memory alone is not enough room to take it again.
      g.update(const FlexReading(availableBytes: 5 * gib, totalBytes: total), 4000);
      g.update(const FlexReading(availableBytes: 5 * gib, totalBytes: total), 400000);
      expect(g.datasetWanted, isFalse);
      g.update(const FlexReading(availableBytes: 8 * gib, totalBytes: total), 402000);
      g.update(const FlexReading(availableBytes: 8 * gib, totalBytes: total), 500000);
      expect(g.datasetWanted, isFalse);
      g.update(const FlexReading(availableBytes: 8 * gib, totalBytes: total), 582000);
      expect(g.datasetWanted, isTrue);
      expect(g.datasetRoom, isTrue);
    });

    test('a dataset never built for lack of room is reported as buildable once there is room', () {
      final g = FlexGovernor(8, datasetBytes: dataset, datasetBackMs: 180000);
      const total = 16 * gib;
      g.update(const FlexReading(availableBytes: 5 * gib, totalBytes: total), 0);
      expect(g.datasetRoom, isFalse);
      g.update(const FlexReading(availableBytes: 6 * gib, totalBytes: total), 2000);
      g.update(const FlexReading(availableBytes: 6 * gib, totalBytes: total), 100000);
      expect(g.datasetRoom, isFalse);
      g.update(const FlexReading(availableBytes: 6 * gib, totalBytes: total), 182000);
      expect(g.datasetRoom, isTrue);
      expect(g.datasetWanted, isTrue);
    });

    test('critical memory pauses mining until there is some room again', () {
      final g = FlexGovernor(4, upStepMs: 6000);
      const total = 16 * gib;
      expect(g.update(const FlexReading(availableBytes: 1 * gib + (512 << 20), totalBytes: total), 0), 0);
      expect(g.note, contains('paused'));
      expect(g.update(const FlexReading(availableBytes: 2 * gib, totalBytes: total), 2000), 0); // hysteresis
      var t = 2000;
      while (g.threads < 4 && t < 60000) {
        t += 2000;
        g.update(const FlexReading(availableBytes: 3 * gib, totalBytes: total), t);
      }
      expect(g.threads, 4);
    });
  });

  group('SystemLoad', () {
    test('parses /proc/stat and /proc/self/stat', () {
      const stat = 'cpu  100 20 30 800 50 0 0 0 0 0\ncpu0 1 2 3 4 5 6 7 8 9 10\n';
      const self = '1234 (node cli (x)) S 1 2 3 4 5 6 7 8 9 10 40 5 0 0 20 0 9 0 0 0';
      final t = SystemLoad.parseLinux(stat, self)!;
      expect(t.total, 1000);
      expect(t.busy, 150);
      expect(t.own, 45);
    });

    test('other programs = machine busy time minus ours', () {
      const a = CpuTimes(100, 1000, 40);
      const b = CpuTimes(700, 2000, 340); // 600 busy, 300 of it ours, of 1000
      expect(SystemLoad.otherCores(a, b, 16), closeTo(4.8, 1e-9));
    });

    test('reads real CPU times here', () {
      final a = SystemLoad.cpuTimes();
      expect(a, isNotNull);
      expect(a!.total, greaterThan(a.busy));
    }, skip: Platform.isLinux || Platform.isWindows ? null : 'Linux and Windows only');
  });
}
