import 'dart:async';

import 'package:cesc_core/cesc_core.dart';
import 'package:flutter/foundation.dart';
import 'package:utxo_core/utxo_core.dart';

/// A Bitcoin-family coin the app knows: its parameters and checkpoint.
/// Adding a coin (Litecoin, Dogecoin, ...) means adding one of these.
class UtxoCoin {
  /// Miner id, wallet chain id and data folder name.
  final String id;
  final ChainParams params;
  final HeaderCheckpoint Function() checkpoint;

  UtxoCoin(this.id, this.params, this.checkpoint);

  /// First block after the built-in checkpoint's height: wallets see
  /// transactions from there on.
  late final int checkpointHeight = checkpoint().height;
  late final int _checkpointTime = checkpoint().times.last;

  /// A height the chain has certainly reached by now (blocks counted at
  /// half their target rate since the checkpoint): a new wallet's scan
  /// starts there without missing anything.
  int heightNowAtMost() {
    final elapsed = DateTime.now().millisecondsSinceEpoch ~/ 1000 - _checkpointTime;
    return checkpointHeight + (elapsed ~/ (params.targetSpacingSeconds * 2)).clamp(0, 1 << 30);
  }

  String get name => params.name;
  String get symbol => params.symbol;
  int get decimals => params.unitsPerCoin.toString().length - 1;

  /// BIP44 account 0 of the coin.
  String get accountPath => "m/44'/${params.bip44CoinType}'/0'";
}

final cryptoescudoCoin = UtxoCoin('cryptoescudo', Cryptoescudo.params, cryptoescudoCheckpoint);

/// The chain service of one coin (its light node, solo miner and SPV
/// wallets in one isolate), running while its miner or any of its wallets
/// needs it.
class UtxoChain extends ChangeNotifier {
  final UtxoCoin coin;
  final String dataDir;

  ChainHandle? _handle;
  Future<ChainHandle>? _starting;
  final Set<Object> _users = {};
  final Map<String, (String, int)> _wallets = {}; // id -> (xpub, birthday)
  StreamSubscription<ChainStatus>? _statusSub;
  StreamSubscription<String>? _logSub;

  ChainStatus? status;
  final List<String> log = [];

  UtxoChain(this.coin, this.dataDir);

  bool get running => _handle != null;
  ChainHandle? get handle => _handle;

  /// Starts the service if needed and counts [user] as needing it.
  Future<ChainHandle> acquire(Object user) {
    _users.add(user);
    final h = _handle;
    if (h != null) return Future.value(h);
    return _starting ??= _spawn();
  }

  Future<ChainHandle> _spawn() async {
    try {
      final h = await ChainHandle.spawn(ChainServiceConfig(params: coin.params, checkpoint: coin.checkpoint(), dataDir: dataDir));
      _handle = h;
      _statusSub = h.status.listen((s) {
        status = s;
        notifyListeners();
      });
      _logSub = h.log.listen((line) {
        log.add(line);
        if (log.length > 400) log.removeRange(0, log.length - 400);
      });
      for (final e in _wallets.entries) {
        await h.openWallet(e.key, e.value.$1, e.value.$2);
      }
      notifyListeners();
      return h;
    } finally {
      _starting = null;
    }
  }

  /// Stops the service once nothing needs it any more.
  Future<void> release(Object user) async {
    _users.remove(user);
    if (_users.isNotEmpty) return;
    final h = _handle ?? await _starting;
    if (_users.isNotEmpty || h == null) return;
    _handle = null;
    await _statusSub?.cancel();
    await _logSub?.cancel();
    await h.stop();
    status = null;
    notifyListeners();
  }

  /// Watches a wallet's account (keeps the chain running while it is open).
  Future<void> openWallet(String id, String xpub, int birthday) async {
    _wallets[id] = (xpub, birthday);
    final h = await acquire('wallet:$id');
    await h.openWallet(id, xpub, birthday);
  }

  Future<void> closeWallet(String id) async {
    if (_wallets.remove(id) == null) return;
    await _handle?.closeWallet(id);
    await release('wallet:$id');
  }

  Future<void> stop() async {
    _users.clear();
    await release(this);
  }
}
