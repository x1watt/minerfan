import 'dart:convert';

/// Hardware a mining algorithm is best suited to.
enum MinerHardware {
  cpu('CPU'),
  gpu('GPU'),
  disk('Disk'),
  other('Other (ASIC, FPGA)');

  final String label;
  const MinerHardware(this.label);

  static MinerHardware parse(String s) => values.asNameMap()[s] ?? other;
}

class MiningAlgorithm {
  final String id;
  final String name;
  final MinerHardware hardware;
  final List<MinerHardware> alsoRunsOn;
  final String? memory;
  final String notes;

  const MiningAlgorithm(this.id, this.name, this.hardware, this.alsoRunsOn, this.memory, this.notes);

  factory MiningAlgorithm.fromJson(Map<String, Object?> m) => MiningAlgorithm(
        m['id']! as String,
        m['name']! as String,
        MinerHardware.parse(m['hardware']! as String),
        [for (final h in (m['alsoRunsOn'] as List? ?? const [])) MinerHardware.parse(h as String)],
        m['memory'] as String?,
        (m['notes'] as String?) ?? '',
      );
}

class CatalogCoin {
  final String symbol;
  final String name;
  final String algorithm;

  /// Chain family for wallets (`monero`, later `ethereum`, ...), if any.
  final String? chain;

  /// The app's miner and wallet for this coin, if it has them.
  final String? minerId;
  final String? walletId;

  /// Price source ids: `kraken` pair, `kucoin` symbol, `coingecko` id.
  final Map<String, String> price;

  /// Where this coin is mined in practice when it differs from its
  /// algorithm's usual hardware (a small scrypt chain has no ASICs).
  final MinerHardware? hardware;
  final String notes;

  const CatalogCoin(this.symbol, this.name, this.algorithm, this.chain, this.minerId, this.walletId, this.price,
      {this.hardware, this.notes = ''});

  factory CatalogCoin.fromJson(Map<String, Object?> m) => CatalogCoin(
        m['symbol']! as String,
        m['name']! as String,
        m['algorithm']! as String,
        m['chain'] as String?,
        m['minerId'] as String?,
        m['walletId'] as String?,
        {for (final e in ((m['price'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        hardware: m['hardware'] == null ? null : MinerHardware.parse(m['hardware']! as String),
        notes: (m['notes'] as String?) ?? '',
      );
}

/// What can be mined with what hardware (`assets/mining_catalog.json`).
/// Categorization only: it will later feed a comparison of which coins are
/// worth mining on a machine, which does not exist yet.
class MiningCatalog {
  final int version;
  final String asOf;
  final Map<String, MiningAlgorithm> algorithms;
  final Map<String, CatalogCoin> coins;

  const MiningCatalog(this.version, this.asOf, this.algorithms, this.coins);

  static const empty = MiningCatalog(0, '', {}, {});

  factory MiningCatalog.parse(String json) {
    final m = jsonDecode(json) as Map<String, Object?>;
    final algorithms = {
      for (final a in m['algorithms']! as List) (a as Map<String, Object?>)['id']! as String: MiningAlgorithm.fromJson(a),
    };
    final coins = {
      for (final c in m['coins']! as List) (c as Map<String, Object?>)['symbol']! as String: CatalogCoin.fromJson(c),
    };
    return MiningCatalog(m['version']! as int, m['asOf']! as String, algorithms, coins);
  }

  MiningAlgorithm? algorithmOf(String coinSymbol) => algorithms[coins[coinSymbol]?.algorithm];

  /// The hardware a coin is mined on: its own override, else its
  /// algorithm's class.
  MinerHardware? hardwareOf(String coinSymbol) => coins[coinSymbol]?.hardware ?? algorithmOf(coinSymbol)?.hardware;

  List<CatalogCoin> coinsFor(String algorithmId) => [for (final c in coins.values) if (c.algorithm == algorithmId) c];

  List<MiningAlgorithm> byHardware(MinerHardware h) => [for (final a in algorithms.values) if (a.hardware == h) a];
}
