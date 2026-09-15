import 'dart:math' as math;

import 'target.dart';

/// What a retarget algorithm needs from the chain: the `nBits` and time of
/// a header by height (heights at or below the last block).
abstract class HeaderHistory {
  int bitsAt(int height);
  int timeAt(int height);

  /// Lowest height available (older headers are not kept).
  int get firstHeight;
}

/// Computes `nBits` for the block after [lastHeight].
abstract class Retarget {
  int next(HeaderHistory chain, int lastHeight);

  /// How many headers before the tip [next] may read.
  int get window;
}

/// Kimoto Gravity Well, as in Megacoin and the coins that took it: the average
/// target of the last blocks, scaled by how fast they came, over a window
/// that ends early once the rate leaves the "event horizon".
class KimotoGravityWell implements Retarget {
  final int spacingSeconds;
  final int pastBlocksMin;
  final int pastBlocksMax;
  final BigInt powLimit;

  const KimotoGravityWell({
    required this.spacingSeconds,
    required this.pastBlocksMin,
    required this.pastBlocksMax,
    required this.powLimit,
  });

  /// The usual parametrization: windows given in seconds (Megacoin style,
  /// `TimeDaySeconds * 0.25` to `TimeDaySeconds * 7`).
  factory KimotoGravityWell.fromSeconds({
    required int spacingSeconds,
    required int pastSecondsMin,
    required int pastSecondsMax,
    required BigInt powLimit,
  }) =>
      KimotoGravityWell(
        spacingSeconds: spacingSeconds,
        pastBlocksMin: pastSecondsMin ~/ spacingSeconds,
        pastBlocksMax: pastSecondsMax ~/ spacingSeconds,
        powLimit: powLimit,
      );

  @override
  int get window => pastBlocksMax + 1;

  @override
  int next(HeaderHistory chain, int lastHeight) {
    if (lastHeight == 0 || lastHeight < pastBlocksMin) return CompactTarget.encode(powLimit);
    final lastTime = chain.timeAt(lastHeight);
    var mass = 0;
    var actual = 0;
    var targetSeconds = 0;
    BigInt average = BigInt.zero, averagePrev = BigInt.zero;
    for (var i = 1, h = lastHeight; h > 0; i++, h--) {
      if (pastBlocksMax > 0 && i > pastBlocksMax) break;
      mass++;
      final bits = CompactTarget.decode(chain.bitsAt(h));
      // CBigNum division truncates toward zero, as BigInt ~/ does.
      average = i == 1 ? bits : ((bits - averagePrev) ~/ BigInt.from(i)) + averagePrev;
      averagePrev = average;
      actual = lastTime - chain.timeAt(h);
      targetSeconds = spacingSeconds * mass;
      var ratio = 1.0;
      if (actual < 0) actual = 0;
      if (actual != 0 && targetSeconds != 0) ratio = targetSeconds / actual;
      final horizon = 1 + (0.7084 * math.pow(mass / 144, -1.228));
      if (mass >= pastBlocksMin && (ratio <= 1 / horizon || ratio >= horizon)) break;
      if (h - 1 < chain.firstHeight) {
        // The original stops at the genesis block; a light chain must keep
        // enough history (window) that this never happens past genesis.
        if (h - 1 > 0) throw StateError('KGW needs headers below height $h');
        break;
      }
    }
    var next = average;
    if (actual != 0 && targetSeconds != 0) {
      next = next * BigInt.from(actual);
      next = next ~/ BigInt.from(targetSeconds);
    }
    if (next > powLimit) next = powLimit;
    return CompactTarget.encode(next);
  }
}
