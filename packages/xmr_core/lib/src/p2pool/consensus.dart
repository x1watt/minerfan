import 'dart:typed_data';

import '../util/bytes.dart';

/// P2Pool sidechain consensus parameters. The three public sidechains have
/// fixed ids; custom chains are not supported.
enum ShareVersion { none, v1, v2, v3 }

class P2PoolConsensus {
  final String name;
  final int targetBlockTime;
  final int minimumDifficulty;
  final int chainWindowSize;
  final int unclePenalty;
  final Uint8List id;
  final int defaultPort;
  final List<String> seedNodes;

  const P2PoolConsensus._(this.name, this.targetBlockTime, this.minimumDifficulty, this.chainWindowSize,
      this.unclePenalty, this.id, this.defaultPort, this.seedNodes);

  static final P2PoolConsensus main = P2PoolConsensus._('mainnet test 2', 10, 100000, 2160, 20,
      fromHex('22af7ee7b50b6892e399da6b2c6c4427b25104d4a9048e00b16e9df04407f918'), 37889,
      const ['seeds.p2pool.io', 'main.p2poolpeers.net']);

  static final P2PoolConsensus mini = P2PoolConsensus._('mini', 10, 100000, 2160, 20,
      fromHex('3982c91a95aec7fa4250bd126cd8c2dc88173f184071dd2cdb5627a335187ec4'), 37888,
      const ['seeds-mini.p2pool.io', 'mini.p2poolpeers.net']);

  static final P2PoolConsensus nano = P2PoolConsensus._('nano', 30, 100000, 2160, 10,
      fromHex('abf8ce94d2e27263fa91dd600dd8173f683581a8f4508d8a9dfa323625bd0559'), 37890,
      const ['seeds-nano.p2pool.io', 'nano.p2poolpeers.net']);

  static P2PoolConsensus byName(String n) => switch (n) {
        'main' || 'default' => main,
        'mini' => mini,
        _ => nano,
      };

  /// Share format by block timestamp (mainnet P2Pool hard forks).
  ShareVersion shareVersionAt(int timestamp) {
    if (timestamp >= 1728763200) return ShareVersion.v3;
    if (timestamp >= 1679173200) return ShareVersion.v2;
    return ShareVersion.v1;
  }

  /// Uncle weight and penalty (the penalty goes to the including block).
  (BigInt, BigInt) applyUnclePenalty(BigInt weight) {
    final penalty = weight * BigInt.from(unclePenalty) ~/ BigInt.from(100);
    return (weight - penalty, penalty);
  }

  /// Monero headers needed to judge alternative chains.
  int get blockHeadersRequired => chainWindowSize * 4 * targetBlockTime ~/ 120;

  /// Blocks older than this below the tip are dropped.
  int get pruneDistance => (chainWindowSize - 1) * 2 + uncleBlockDepth * 2 + 120 ~/ targetBlockTime + 1;
}

const int uncleBlockDepth = 3;
const int maxUncleCount = 5;
const int maxTxOutputReward = (1 << 56) - 1;
const int tailEmissionReward = 600000000000;
const int poolBlockMaxTemplateSize = 128 * 1024 - (1 + 4);
