import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';

/// Runs the GPU miner at a fixed duty with new work every few seconds and
/// prints the measured speed: it must be about duty x full speed.
///   dart run tool/duty_check.dart [DUTY] [WORK_EVERY_MS] [SECONDS]
Future<void> main(List<String> args) async {
  final duty = args.isNotEmpty ? double.parse(args[0]) : 0.02;
  final every = args.length > 1 ? int.parse(args[1]) : 3000;
  final secs = args.length > 2 ? int.parse(args[2]) : 40;
  final m = GpuScryptMiner();
  await m.start();
  m.setDuty(duty);
  var id = 0;
  void work() => m.work(MiningWork(++id, Uint8List.fromList(List.generate(80, (i) => (i + id) & 0xff)), BigInt.one));
  work();
  final t = Timer.periodic(Duration(milliseconds: every), (_) {
    work();
    m.setDuty(duty);
  });
  for (var i = 0; i < secs ~/ 5; i++) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final s = m.stats;
    stdout.writeln('hashrate ${(s.hashrate / 1000).toStringAsFixed(1)} kH/s, full ${(s.fullSpeed / 1000).toStringAsFixed(0)} kH/s, duty ${s.duty}');
  }
  t.cancel();
  await m.stop();
  exit(0);
}
