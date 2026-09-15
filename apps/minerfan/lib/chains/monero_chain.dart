import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:xmr_core/xmr_core.dart';

import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';

/// The Monero wallet service (light chain over our own peers, block scans,
/// sends through a node for decoys), running while a Monero wallet is open.
class MoneroChain extends ChangeNotifier {
  final String dataDir;
  String node;
  MoneroWalletHandle? _handle;
  Future<MoneroWalletHandle>? _starting;
  final Set<String> _open = {};
  StreamSubscription<MoneroChainStatus>? _statusSub;
  StreamSubscription<String>? _logSub;
  MoneroChainStatus? status;
  final List<String> log = [];

  MoneroChain(this.dataDir, {required this.node});

  bool isOpen(String id) => _open.contains(id);
  MoneroWalletHandle? get handle => _handle;

  Future<MoneroWalletHandle> _acquire() {
    final h = _handle;
    if (h != null) return Future.value(h);
    return _starting ??= () async {
      try {
        final h = await MoneroWalletHandle.spawn(MoneroWalletServiceConfig(dataDir: dataDir, node: node));
        _handle = h;
        _statusSub = h.status.listen((s) {
          status = s;
          notifyListeners();
        });
        _logSub = h.log.listen((l) {
          log.add(l);
          if (log.length > 400) log.removeRange(0, log.length - 400);
        });
        return h;
      } finally {
        _starting = null;
      }
    }();
  }

  /// Opens [w] in the service; [password] when it has one. Throws for a
  /// wrong password.
  Future<void> open(MoneroWallet w, {String? password}) async {
    if (_open.contains(w.id)) return;
    final box = w.secret, key = w.deviceKey;
    final text = await Isolate.run(() => KeyedWallet.open(box, key, password));
    if (text == null) throw const MoneroWalletException('wrong password');
    final keys = w.viewOnly
        ? MoneroWalletKeys.viewOnly(w.id, w.address, _hex(text.trim()), w.birthday)
        : MoneroWalletKeys.full(w.id, MoneroMnemonic.toSeed(text) ?? (throw const MoneroWalletException('damaged recovery words')), w.birthday);
    final h = await _acquire();
    await h.openWallet(keys);
    _open.add(w.id);
    notifyListeners();
  }

  Future<void> close(String id) async {
    if (!_open.remove(id)) return;
    await _handle?.closeWallet(id);
    if (_open.isEmpty) await stop();
  }

  Future<void> setNode(String url) async {
    node = url;
    await _handle?.setNode(url);
  }

  Future<void> stop() async {
    final h = _handle ?? await _starting;
    _handle = null;
    _open.clear();
    await _statusSub?.cancel();
    await _logSub?.cancel();
    await h?.stop();
    status = null;
    notifyListeners();
  }

  static Uint8List _hex(String s) =>
      Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}
