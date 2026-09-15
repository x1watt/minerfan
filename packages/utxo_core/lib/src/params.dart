import 'dart:typed_data';

import 'package:pow_core/pow_core.dart';

/// Everything that makes one Bitcoin-family coin different from another.
/// A coin package fills this in; the rest of utxo_core only reads it.
class ChainParams {
  final String name;
  final String symbol;

  /// P2P message start bytes.
  final Uint8List magic;
  final int port;
  final List<String> dnsSeeds;
  final List<String> fixedPeers;
  final int protocolVersion;
  final String userAgent;

  /// Base58Check version bytes and the BIP44 coin type.
  final int pubKeyHashVersion;
  final int scriptHashVersion;
  final int wifVersion;
  final int bip44CoinType;

  /// A new PoW function (one per isolate: it may keep scratch memory).
  final HeaderPow Function() pow;
  final Retarget retarget;
  final int targetSpacingSeconds;

  /// Block subsidy in smallest units at a height (fees excluded).
  final int Function(int height) subsidy;
  final int coinbaseMaturity;

  /// Smallest units per coin (10^8 in the Bitcoin family).
  final int unitsPerCoin;
  final int minFeePerKb;

  /// Outputs below this cost one more base fee each (0 = no such rule).
  final int softDustLimit;

  /// Header version of new blocks, and whether the coinbase carries the
  /// height (BIP34).
  final int blockVersion;
  final bool bip34;

  /// Headers may be at most this far in the future.
  final int maxFutureSeconds;

  const ChainParams({
    required this.name,
    required this.symbol,
    required this.magic,
    required this.port,
    required this.dnsSeeds,
    this.fixedPeers = const [],
    required this.protocolVersion,
    required this.userAgent,
    required this.pubKeyHashVersion,
    required this.scriptHashVersion,
    required this.wifVersion,
    required this.bip44CoinType,
    required this.pow,
    required this.retarget,
    required this.targetSpacingSeconds,
    required this.subsidy,
    required this.coinbaseMaturity,
    this.unitsPerCoin = 100000000,
    required this.minFeePerKb,
    this.softDustLimit = 0,
    required this.blockVersion,
    required this.bip34,
    this.maxFutureSeconds = 2 * 60 * 60,
  });
}
