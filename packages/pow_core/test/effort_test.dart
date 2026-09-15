import 'package:pow_core/pow_core.dart';
import 'package:test/test.dart';

/// A toy network: the difficulty follows the total hashrate with a lag,
/// like a retarget; the controller should settle near its target share.
double simulate(double share, {double others = 50e3, double full = 600e3, int steps = 400}) {
  final c = EffortController(share);
  var network = others; // what the difficulty says, lagging
  var ours = 0.0;
  for (var i = 0; i < steps; i++) {
    final d = c.duty(networkHashrate: network, fullSpeed: full, currentSpeed: ours);
    ours = full * d;
    network += ((others + ours) - network) * 0.1;
  }
  return EffortController.shareOf(ours, others);
}

void main() {
  test('settles near the target share on a small network', () {
    for (final s in [0.1, 0.25, 0.5]) {
      expect(simulate(s), closeTo(s, 0.02), reason: 'share $s');
    }
  });

  test('100% means full speed, 0% means stop', () {
    expect(EffortController(1).duty(networkHashrate: 50e3, fullSpeed: 600e3, currentSpeed: 0), 1);
    expect(EffortController(0).duty(networkHashrate: 50e3, fullSpeed: 600e3, currentSpeed: 0), 0);
    expect(simulate(1), greaterThan(0.9));
  });

  test('on a big network even full speed is a small share', () {
    expect(simulate(0.25, others: 50e9), lessThan(0.001));
  });
}
