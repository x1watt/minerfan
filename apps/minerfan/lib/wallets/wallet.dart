import 'package:flutter/foundation.dart';

/// One thing a wallet holds: the chain's own coin, or a token on the chain
/// (for example ERC-20 tokens on Ethereum, later).
class WalletAsset {
  final String symbol;
  final String name;

  /// Smallest units (piconero for XMR, wei for ETH); null while unknown.
  final BigInt? balance;
  final int decimals;

  /// Token contract, null for the chain's own coin.
  final String? contract;

  const WalletAsset(this.symbol, this.name, {this.balance, required this.decimals, this.contract});

  double? get amount => balance == null ? null : balance!.toDouble() / BigInt.from(10).pow(decimals).toDouble();
}

/// A wallet on one chain. Independent from the miners: a wallet is listed
/// whether or not a miner pays into it.
abstract class Wallet extends ChangeNotifier {
  String get id;

  /// Chain id: `monero`, `cryptoescudo`; `ethereum` and others later.
  String get chain;

  /// The chain's name for people, e.g. `Monero`.
  String get chainName;
  String get label;
  set label(String value);

  /// Ticker of the chain's own coin, e.g. `XMR`.
  String get symbol;
  String get address;

  /// The chain's coin first, then any tokens.
  List<WalletAsset> get assets;

  bool get canReceive;
  bool get canSend;

  /// Why sending is not possible, or null when it is.
  String? get sendUnavailable;

  Map<String, Object?> toJson();
}
