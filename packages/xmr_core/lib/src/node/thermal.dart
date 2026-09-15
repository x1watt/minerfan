/// One thermal reading from the operating system (Android today).
class ThermalReading {
  /// Android `PowerManager` thermal status: 0 none, 1 light, 2 moderate,
  /// 3 severe, 4 critical, 5 emergency, 6 shutdown; -1 when unknown.
  final int status;

  /// Android thermal headroom forecast: 1.0 is where severe throttling
  /// starts; negative or NaN when unknown.
  final double headroom;

  /// Battery temperature in degrees Celsius; NaN when unknown.
  final double batteryC;

  const ThermalReading({this.status = -1, this.headroom = double.nan, this.batteryC = double.nan});

  bool get _hasHeadroom => !headroom.isNaN && headroom >= 0;
  bool get _hasBattery => !batteryC.isNaN;

  @override
  String toString() => [
        if (status >= 0) 'status $status',
        if (_hasHeadroom) 'headroom ${headroom.toStringAsFixed(2)}',
        if (_hasBattery) 'battery ${batteryC.toStringAsFixed(1)} C',
      ].join(', ');
}

/// Chooses how many mining threads to run from thermal readings, so a phone
/// keeps a steady hashrate instead of heating up, throttling hard, and
/// running slower overall.
///
/// Steps down at once when it gets hot (one thread per reading, more when
/// very hot, a pause when critical) and steps up slowly: one thread per
/// [coolStepMs] of continuously cool readings.
class ThermalGovernor {
  final int maxThreads;
  final int coolStepMs;
  int threads;
  int _coolSinceMs = -1;
  ThermalReading last = const ThermalReading();

  ThermalGovernor(this.maxThreads, {this.coolStepMs = 60000}) : threads = maxThreads;

  /// 0 cool, 1 warm (hold), 2 hot (step down), 3 very hot (cut hard),
  /// 4 critical (pause).
  static int level(ThermalReading r) {
    final h = r._hasHeadroom ? r.headroom : 0.0;
    final t = r._hasBattery ? r.batteryC : 0.0;
    if (r.status >= 4 || t >= 48) return 4;
    if (r.status == 3 || h >= 0.95 || t >= 45) return 3;
    if (r.status == 2 || h >= 0.85 || t >= 42) return 2;
    if (r.status == 1 || h >= 0.70 || t >= 39) return 1;
    return 0;
  }

  /// Returns the thread count to use after reading [r] at [nowMs].
  int update(ThermalReading r, int nowMs) {
    last = r;
    final lv = level(r);
    if (lv != 0) _coolSinceMs = -1;
    switch (lv) {
      case 4:
        threads = 0;
      case 3:
        threads = threads <= 1 ? 1 : (threads * 6) ~/ 10;
        if (threads < 1) threads = 1;
      case 2:
        if (threads > 1) threads--;
        if (threads < 1) threads = 1;
      case 1:
        if (threads == 0) threads = 1; // out of critical: resume on one thread
      default:
        if (threads == 0) threads = 1;
        if (_coolSinceMs < 0) {
          _coolSinceMs = nowMs;
        } else if (nowMs - _coolSinceMs >= coolStepMs && threads < maxThreads) {
          threads++;
          _coolSinceMs = nowMs;
        }
    }
    return threads;
  }
}
