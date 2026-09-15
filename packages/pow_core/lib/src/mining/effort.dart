/// Keeps a miner at a chosen share of its network instead of taking over a
/// small chain. The network's hashrate comes from the difficulty (which
/// includes us once the retarget has caught up); the others' hashrate is
/// that minus ours. The miner then runs at the speed that makes its share
/// `target`, as a duty cycle of its full speed.
class EffortController {
  /// Target share of the network, 0 to 1. 1 means no cap.
  double targetShare;

  /// Smoothing of the network estimate (difficulty moves block by block).
  final double smoothing;

  double? _network;

  EffortController(this.targetShare, {this.smoothing = 0.2});

  /// Share of full speed to run at (0 to 1), from the network hashrate
  /// implied by the current difficulty, our full speed and the speed we
  /// actually ran at recently.
  double duty({required double networkHashrate, required double fullSpeed, required double currentSpeed}) {
    if (targetShare >= 1) return 1;
    if (targetShare <= 0 || fullSpeed <= 0) return 0;
    _network = _network == null ? networkHashrate : _network! * (1 - smoothing) + networkHashrate * smoothing;
    // Others never count as less than a tenth of the network, so a stale
    // estimate cannot send us to zero or to full speed on its own.
    final others = (_network! - currentSpeed).clamp(_network! * 0.1, double.infinity);
    final want = others * targetShare / (1 - targetShare);
    return (want / fullSpeed).clamp(0.0, 1.0);
  }

  /// The share our speed would give against [others].
  static double shareOf(double ours, double others) => ours + others <= 0 ? 0 : ours / (ours + others);
}
