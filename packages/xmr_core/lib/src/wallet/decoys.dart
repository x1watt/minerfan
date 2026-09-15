import 'dart:math';
import 'dart:typed_data';

import '../util/bytes.dart';
import 'clsag.dart';
import 'node_rpc.dart';

/// Decoy selection as wallet2 does it (src/wallet/wallet2.cpp gamma_picker,
/// BSD-3): an output age drawn from a gamma distribution over log seconds
/// (Moeser et al.), mapped to an output through the average time between
/// recent outputs, then a random output of that block.
class GammaPicker {
  static const shape = 19.28, scale = 1 / 1.61;
  static const spendableAge = 10, targetSeconds = 120;
  static const recentSpendWindow = 15 * targetSeconds;
  static const unlockSeconds = spendableAge * targetSeconds;

  final List<int> offsets; // cumulative RingCT outputs per block
  final Random _rng;
  late final int _end = offsets.length - (spendableAge - 1);
  late final int numOutputs = offsets[_end - 1];
  late final double _averageOutputTime;

  GammaPicker(this.offsets, [Random? rng]) : _rng = rng ?? Random.secure() {
    const blocksInAYear = 86400 * 365 ~/ targetSeconds;
    final blocks = min(offsets.length, blocksInAYear);
    final outputs = offsets.last - (blocks < offsets.length ? offsets[offsets.length - blocks - 1] : 0);
    _averageOutputTime = targetSeconds * blocks / outputs;
  }

  double _normal() {
    final u1 = 1.0 - _rng.nextDouble(), u2 = _rng.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }

  /// Marsaglia and Tsang's method (shape >= 1).
  double _gamma() {
    const d = shape - 1 / 3;
    final c = 1 / sqrt(9 * d);
    while (true) {
      double x, v;
      do {
        x = _normal();
        v = 1 + c * x;
      } while (v <= 0);
      v = v * v * v;
      final u = _rng.nextDouble();
      if (u < 1 - 0.0331 * x * x * x * x) return d * v * scale;
      if (log(u) < 0.5 * x * x + d * (1 - v + log(v))) return d * v * scale;
    }
  }

  /// A global output index, or null for a pick to discard.
  int? pick() {
    var x = exp(_gamma());
    if (x > unlockSeconds) {
      x -= unlockSeconds;
    } else {
      x = _rng.nextInt(recentSpendWindow).toDouble();
    }
    var index = x ~/ _averageOutputTime;
    if (index >= numOutputs) return null;
    index = numOutputs - 1 - index;
    // First block whose cumulative count is above the index.
    var lo = 0, hi = _end;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (offsets[mid] < index) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo >= _end) return null;
    final first = lo == 0 ? 0 : offsets[lo - 1];
    final n = offsets[lo] - first;
    if (n <= 0) return null;
    return first + _rng.nextInt(n);
  }
}

/// A ring for one real output: 16 members sorted by global index.
class Ring {
  final List<int> indices;
  final List<RingMember> members;
  final int realPosition;
  Ring(this.indices, this.members, this.realPosition);

  /// Relative offsets as the transaction stores them.
  List<int> get keyOffsets => [for (var i = 0; i < indices.length; i++) i == 0 ? indices[0] : indices[i] - indices[i - 1]];
}

/// Picks decoys for each real output (global index, key, commitment) and
/// fetches the ring members from the node. The node's copy of each real
/// output must match ours.
Future<List<Ring>> buildRings(
  MoneroRpc rpc,
  OutputDistribution dist,
  List<({int globalIndex, Uint8List key, Uint8List commitment})> real, {
  int ringSize = 16,
}) async {
  final picker = GammaPicker(dist.cumulative);
  final rings = <Ring>[];
  for (final r in real) {
    final chosen = <int>{r.globalIndex};
    final members = <int, RingMember>{};
    // Decoys must be unlocked; ask for extra and drop the locked ones.
    for (var attempt = 0; attempt < 20 && chosen.length < ringSize; attempt++) {
      final want = <int>{};
      var guard = 0;
      while (want.length < (ringSize - chosen.length) * 3 ~/ 2 + 1 && guard++ < 10000) {
        final p = picker.pick();
        if (p != null && !chosen.contains(p)) want.add(p);
      }
      final list = want.toList();
      final outs = await rpc.outputs(list);
      for (var i = 0; i < list.length && chosen.length < ringSize; i++) {
        if (!outs[i].unlocked) continue;
        chosen.add(list[i]);
        members[list[i]] = (key: outs[i].key, commitment: outs[i].mask);
      }
    }
    if (chosen.length < ringSize) throw StateError('could not find enough decoys');
    final mine = (await rpc.outputs([r.globalIndex])).single;
    if (!bytesEqual(mine.key, r.key) || !bytesEqual(mine.mask, r.commitment)) {
      throw StateError('the node has a different output at index ${r.globalIndex}');
    }
    members[r.globalIndex] = (key: r.key, commitment: r.commitment);
    final sorted = chosen.toList()..sort();
    rings.add(Ring(sorted, [for (final i in sorted) members[i]!], sorted.indexOf(r.globalIndex)));
  }
  return rings;
}
