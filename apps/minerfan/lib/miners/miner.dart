import 'package:flutter/foundation.dart';

/// One miner the app runs (Monero on P2Pool today; more kinds later). The
/// dashboard and the Miners list only use this interface; each kind has its
/// own settings page and details.
abstract class Miner extends ChangeNotifier {
  /// Stable id, also the key of its settings.
  String get id;

  /// Coin or algorithm name, e.g. `Monero`.
  String get name;

  /// Ticker of the mined coin, e.g. `XMR`; its entry in the mining catalog
  /// gives the algorithm and the hardware class.
  String get symbol;

  /// Where it mines, e.g. `P2Pool mini`.
  String get detail;

  bool get running;
  bool get starting;

  /// False until the miner is configured (for example a wallet address).
  bool get canStart;

  /// Why it cannot start, or the last error; null when fine.
  String? get problem;

  /// Current hashrate in hashes per second (0 when stopped).
  double get hashrate;

  /// One line for lists and the dashboard.
  String get statusLine;

  /// Coins this miner has earned so far (found blocks, pool payouts), or
  /// null when unknown.
  MinedTotal? get mined => null;

  Future<void> start();
  Future<void> stop();
}

/// Coins mined: [amount] in whole coins over [count] blocks or payouts.
class MinedTotal {
  final double amount;
  final String symbol;
  final int count;

  /// What [count] counts: `blocks` or `payouts`.
  final String unit;
  const MinedTotal(this.amount, this.symbol, this.count, this.unit);
}
