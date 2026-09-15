import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:net_core/net_core.dart';

import '../monero/address.dart';
import '../monero/block.dart';
import '../monero/light_chain.dart';
import '../node/monero_net.dart';
import '../node/store.dart';
import '../randomx/hash_pool.dart';
import '../randomx/jit/vm_jit.dart';
import '../randomx/memory.dart';
import '../util/bytes.dart';
import 'account.dart';
import 'decoys.dart';
import 'node_rpc.dart';
import 'scanner.dart';
import 'transaction.dart';
import 'tx_builder.dart';

/// The keys a wallet opens with: a full wallet from its seed, or a
/// view-only one (address and private view key; sees incoming payments).
class MoneroWalletKeys {
  final String id;
  final Uint8List? seed;
  final String? address;
  final Uint8List? viewSecret;

  /// First block that can hold its transactions; -1 for a new wallet
  /// (scanning starts at the tip once the chain is synced).
  final int birthday;
  const MoneroWalletKeys.full(this.id, Uint8List this.seed, this.birthday)
      : address = null,
        viewSecret = null;
  const MoneroWalletKeys.viewOnly(this.id, String this.address, Uint8List this.viewSecret, this.birthday) : seed = null;
}

class MoneroTxEntry {
  final String txid;
  final int? height;
  final int received;
  final int spent;
  final int fee;
  final bool coinbase;
  final int time;

  /// The transaction's public key R (hex), recorded for incoming payments.
  final String? txPub;

  /// The transaction private key r (hex), kept for transactions we sent.
  final String? txKey;
  const MoneroTxEntry(this.txid, this.height, this.received, this.spent, this.fee, this.coinbase, this.time,
      {this.txPub, this.txKey});
  int get net => received - spent;
}

class MoneroWalletStatus {
  final String id;
  final String address;
  final bool viewOnly;
  final int balance;
  final int unlocked;
  final int pendingIn;
  final int scanned;
  final List<MoneroTxEntry> history;
  const MoneroWalletStatus(
      this.id, this.address, this.viewOnly, this.balance, this.unlocked, this.pendingIn, this.scanned, this.history);
}

class MoneroChainStatus {
  final int tip;
  final int peers;
  final bool synced;
  final String node;
  final Map<String, MoneroWalletStatus> wallets;
  const MoneroChainStatus(this.tip, this.peers, this.synced, this.node, this.wallets);
}

class MoneroWalletServiceConfig {
  final String dataDir;
  final String node;
  const MoneroWalletServiceConfig({required this.dataDir, required this.node});
}

class MoneroWalletException implements Exception {
  final String message;
  const MoneroWalletException(this.message);
  @override
  String toString() => message;
}

/// Monero wallets in their own isolate: a light chain over our own P2P
/// peers (checkpoint, difficulty, RandomX checks of recent blocks) that
/// scans blocks for the wallets' outputs, and sends through a node's RPC
/// for decoys. Status every 2 seconds.
class MoneroWalletHandle {
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _inbox;
  final StreamController<MoneroChainStatus> _status = StreamController.broadcast();
  final StreamController<String> _log = StreamController.broadcast();
  final Map<int, Completer<Object?>> _pending = {};
  final Completer<void> _stopped = Completer();
  int _next = 0;
  MoneroChainStatus? last;

  MoneroWalletHandle._(this._isolate, this._commands, this._inbox, Stream<Object?> messages) {
    messages.listen((m) {
      final msg = m as List<Object?>;
      switch (msg[0]) {
        case 'status':
          last = msg[1]! as MoneroChainStatus;
          _status.add(last!);
        case 'log':
          _log.add(msg[1]! as String);
        case 'reply':
          final c = _pending.remove(msg[1]! as int);
          msg[3] != null ? c?.completeError(MoneroWalletException(msg[3]! as String)) : c?.complete(msg[2]);
        case 'stopped':
          if (!_stopped.isCompleted) _stopped.complete();
      }
    });
  }

  static Future<MoneroWalletHandle> spawn(MoneroWalletServiceConfig config) async {
    final inbox = ReceivePort();
    final iso = await Isolate.spawn(_main, [inbox.sendPort, config], debugName: 'monero-wallets');
    final messages = inbox.asBroadcastStream();
    final commands = await messages.first as SendPort;
    return MoneroWalletHandle._(iso, commands, inbox, messages);
  }

  Stream<MoneroChainStatus> get status => _status.stream;
  Stream<String> get log => _log.stream;

  Future<Object?> _request(List<Object?> msg) {
    final id = _next++;
    final c = _pending[id] = Completer<Object?>();
    _commands.send([msg[0], id, ...msg.skip(1)]);
    return c.future;
  }

  Future<void> openWallet(MoneroWalletKeys keys) => _request(['open', keys]);
  Future<void> closeWallet(String id) => _request(['close', id]);
  Future<void> setNode(String url) => _request(['node', url]);

  /// Fee estimate for paying [amount] (piconero).
  Future<int> estimateFee(String walletId, int amount) async => await _request(['fee', walletId, amount]) as int;

  /// Signs and sends; returns (txid, fee).
  Future<(String, int)> send(String walletId, String address, int amount) async {
    final (txid, fee, _) = await sendKeyed(walletId, address, amount);
    return (txid, fee);
  }

  /// Signs and sends; returns (txid, fee, tx private key hex) for a
  /// tx-key proof (tx_key_proof.dart).
  Future<(String, int, String)> sendKeyed(String walletId, String address, int amount) async {
    final r = await _request(['send', walletId, address, amount]) as List<Object?>;
    return (r[0]! as String, r[1]! as int, r[2]! as String);
  }

  Future<void> stop() async {
    _commands.send(['stop', -1]);
    await _stopped.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    _isolate.kill();
    _inbox.close();
    for (final c in _pending.values) {
      c.completeError(const MoneroWalletException('stopped'));
    }
    await _status.close();
    await _log.close();
  }
}

Future<void> _main(List<Object?> args) async {
  final out = args[0]! as SendPort;
  final config = args[1]! as MoneroWalletServiceConfig;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final service = _Service(config, out);
  await service.start();
  await for (final m in inbox) {
    final msg = m as List<Object?>;
    final id = msg[1]! as int;
    try {
      final r = await service.handle(msg[0]! as String, msg.sublist(2));
      if (id >= 0) out.send(['reply', id, r, null]);
    } catch (e) {
      if (id >= 0) out.send(['reply', id, null, '$e']);
    }
    if (msg[0] == 'stop') {
      out.send(['stopped']);
      inbox.close();
    }
  }
}

class _Wallet {
  final String id;
  final MoneroAccount account;
  final MoneroScanner scanner;
  final File file;
  final int birthday;
  int scanned;
  Uint8List? lastId;
  final Map<String, OwnedOutput> outputs = {}; // id -> output
  final Map<String, OwnedOutput> byKeyImage = {};
  final Map<String, Map<String, Object?>> history = {}; // txid -> entry
  final Map<String, OwnedOutput> mempool = {};

  /// A new wallet: start at the tip once synced.
  bool fromTip = false;

  _Wallet(this.id, this.account, this.file, this.birthday)
      : scanner = MoneroScanner(account),
        scanned = birthday - 1;

  void add(OwnedOutput o) {
    outputs[o.id] = o;
    if (o.keyImage != null) byKeyImage[toHex(o.keyImage!)] = o;
  }

  Map<String, Object?> _entry(String txid, int? height, bool coinbase) =>
      history.putIfAbsent(txid, () => {'txid': txid, 'h': height, 'r': 0, 's': 0, 'f': 0, 'cb': coinbase, 't': DateTime.now().millisecondsSinceEpoch ~/ 1000});

  void save() {
    try {
      final tmp = File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode({
          'scanned': scanned,
          'lastId': lastId == null ? null : toHex(lastId!),
          'outputs': [for (final o in outputs.values) o.toJson()],
          'history': history.values.toList(),
        }));
      tmp.renameSync(file.path);
    } catch (_) {}
  }

  void load() {
    try {
      if (!file.existsSync()) return;
      final m = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      scanned = m['scanned']! as int;
      final l = m['lastId'] as String?;
      lastId = l == null ? null : fromHex(l);
      for (final o in (m['outputs']! as List).cast<Map<String, Object?>>()) {
        add(OwnedOutput.fromJson(o));
      }
      for (final h in (m['history']! as List).cast<Map<String, Object?>>()) {
        history[h['txid']! as String] = h;
      }
    } catch (_) {}
  }
}

class _Service {
  final MoneroWalletServiceConfig config;
  final SendPort out;
  late final NodeStore store;
  late final MoneroLightChain chain;
  late final HashPool hashes;
  late final MoneroNet net;
  final Map<String, _Wallet> wallets = {};
  String node;
  OutputDistribution? _dist;
  bool _scanning = false;
  bool _synced = false;
  Timer? _timer;
  int _lastSaveMs = 0;

  _Service(this.config, this.out) : node = config.node;

  void log(String line) => out.send(['log', '${DateTime.now().toIso8601String().substring(11, 19)} $line']);

  File get _distFile => File('${config.dataDir}/output_distribution.bin');

  Future<void> start() async {
    Directory(config.dataDir).createSync(recursive: true);
    store = NodeStore(config.dataDir);
    chain = store.loadChain() ?? MoneroLightChain.fromCheckpoint();
    final shared = RxBuffer.sharedSupported;
    hashes = HashPool(workers: 1, memory: shared ? RxMemoryKind.shared : RxMemoryKind.dart, jit: shared && RandomXJitVM.supported)
      ..log = log;
    await hashes.start();
    net = MoneroNet(IoTransport(), chain, hashes, log: log)
      ..onSynced = () {
        _synced = true;
        unawaited(_scan());
      }
      ..onNewTip = ((_) {
        unawaited(_scan());
      })
      ..onNewTransactions = _onMempool;
    net.addKnownPeers(store.loadPeers('monero_peers.txt').map((p) => '${p.$1}:${p.$2}'));
    net.start();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void _tick() {
    out.send(['status', _status()]);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveMs > 120000) {
      _lastSaveMs = now;
      try {
        store.saveChain(chain);
        store.savePeers('monero_peers.txt', net.knownPeers.take(200).map((k) {
          final i = k.lastIndexOf(':');
          return (k.substring(0, i), int.parse(k.substring(i + 1)));
        }));
      } catch (_) {}
    }
    if (_synced && !_scanning && wallets.values.any((w) => w.scanned < chain.tipHeight)) unawaited(_scan());
  }

  Future<Object?> handle(String cmd, List<Object?> a) async {
    switch (cmd) {
      case 'open':
        final k = a[0]! as MoneroWalletKeys;
        if (wallets.containsKey(k.id)) return null;
        MoneroAccount account;
        if (k.seed != null) {
          account = MoneroAccount.fromSeed(k.seed!);
        } else {
          final addr = MoneroAddress.parse(k.address!) ?? (throw const MoneroWalletException('not a Monero address'));
          account = MoneroAccount.viewOnly(addr, k.viewSecret!) ??
              (throw const MoneroWalletException('the view key does not belong to this address'));
        }
        // Blocks before the light chain's first header cannot be fetched by id.
        final bottom = chain.tipHeight - chain.export().length + 1;
        final w = _Wallet(k.id, account, File('${config.dataDir}/wallet-${k.id}.json'), k.birthday.clamp(bottom + 1, 1 << 40));
        w.fromTip = k.birthday < 0 && !w.file.existsSync();
        w.load();
        wallets[k.id] = w;
        log('wallet ${k.id}: ${account.canSpend ? 'full' : 'view-only'}, scanning from ${w.scanned + 1}');
        if (_synced) unawaited(_scan());
      case 'close':
        wallets.remove(a[0]! as String)?.save();
      case 'node':
        node = a[0]! as String;
      case 'fee':
        return _estimateFee(_wallet(a[0]), a[1]! as int);
      case 'send':
        return _send(_wallet(a[0]), a[1]! as String, a[2]! as int);
      case 'stop':
        _timer?.cancel();
        for (final w in wallets.values) {
          w.save();
        }
        try {
          store.saveChain(chain);
        } catch (_) {}
        await net.stop();
        await hashes.stop();
    }
    return null;
  }

  _Wallet _wallet(Object? id) => wallets[id] ?? (throw const MoneroWalletException('the wallet is not open'));

  // ---- scanning ----------------------------------------------------------

  Future<void> _scan() async {
    if (_scanning || !_synced) return;
    _scanning = true;
    try {
      for (final w in wallets.values.toList()) {
        if (w.fromTip) {
          w.fromTip = false;
          w.scanned = chain.tipHeight - 5;
          w.lastId = chain.idAt(w.scanned);
          w.save();
        }
        while (w.scanned < chain.tipHeight && wallets.containsKey(w.id)) {
          if (!await _scanBatch(w)) break;
        }
      }
    } catch (e) {
      log('wallet scan: $e');
    } finally {
      _scanning = false;
    }
  }

  /// Scans up to 20 blocks after [w.scanned]. False when nothing could be
  /// fetched now.
  Future<bool> _scanBatch(_Wallet w) async {
    // A reorganization below our scan point: step back and rescan.
    final known = chain.idAt(w.scanned);
    if (w.lastId != null && known != null && !bytesEqual(known, w.lastId!)) {
      _rewind(w, w.scanned - 10);
      return true;
    }
    final ids = <Uint8List>[];
    for (var h = w.scanned + 1; h <= chain.tipHeight && ids.length < 20; h++) {
      final id = chain.idAt(h);
      if (id == null) break;
      ids.add(id);
    }
    if (ids.isEmpty) return false;
    final res = await net.fetchBlocks(ids);
    if (res.blocks.length != ids.length) throw StateError('peer returned ${res.blocks.length} of ${ids.length} blocks');
    for (var i = 0; i < ids.length; i++) {
      final entry = res.blocks[i];
      final block = MoneroBlock.parse(entry.block);
      if (!bytesEqual(block.id(), ids[i])) throw StateError('a peer sent the wrong block');
      _scanBlock(w, block, entry.txs.map((t) => (t.blob, t.prunableHash)).toList(), w.scanned + 1);
      w.scanned++;
      w.lastId = ids[i];
    }
    w.save();
    return true;
  }

  void _scanBlock(_Wallet w, MoneroBlock block, List<(Uint8List, Uint8List?)> txBlobs, int height) {
    if (txBlobs.length != block.txHashes.length) throw StateError('block ${block.height} is missing transactions');
    final b = BytesBuilder();
    block.minerTx.write(b);
    final coinbase = MoneroTx.parse(b.takeBytes());
    var offset = 0;
    _scanTx(w, coinbase, toHex(coinbase.hash), height, offset);
    offset += coinbase.outputs.length;
    for (var i = 0; i < txBlobs.length; i++) {
      final (blob, prunable) = txBlobs[i];
      final tx = MoneroTx.parse(blob, pruned: prunable != null, prunableHash: prunable);
      final hash = tx.hash;
      if (!bytesEqual(hash, block.txHashes[i])) throw StateError('transaction ${toHex(block.txHashes[i])} does not match');
      _scanTx(w, tx, toHex(hash), height, offset);
      offset += tx.outputs.length;
    }
  }

  void _scanTx(_Wallet w, MoneroTx tx, String txid, int height, int offset) {
    for (final o in w.scanner.scan(tx, txid, height, firstOffset: offset)) {
      w.mempool.remove(o.id);
      final e = w._entry(txid, height, tx.isCoinbase);
      if (!w.outputs.containsKey(o.id)) e['r'] = (e['r']! as int) + o.amount;
      final pub = tx.txPublicKeys.$1;
      if (pub != null) e['R'] = toHex(pub);
      e['h'] = height;
      w.add(o);
      log('wallet ${w.id}: received ${o.amount} in $txid at $height');
    }
    for (final input in tx.inputs) {
      if (input is! TxInToKey) continue;
      final o = w.byKeyImage[toHex(input.keyImage)];
      if (o == null) continue;
      if (o.spentHeight == null) {
        final e = w._entry(txid, height, false);
        if (o.spentIn != txid) e['s'] = (e['s']! as int) + o.amount;
        e['h'] = height;
        if (tx.fee > 0) e['f'] = tx.fee;
      }
      o.spentIn = txid;
      o.spentHeight = height;
    }
  }

  void _rewind(_Wallet w, int to) {
    log('wallet ${w.id}: chain reorganized, rescanning from ${to + 1}');
    w.outputs.removeWhere((_, o) => o.height > to);
    w.byKeyImage.removeWhere((_, o) => o.height > to);
    for (final o in w.outputs.values) {
      if ((o.spentHeight ?? 0) > to) {
        o.spentHeight = null;
        o.spentIn = null;
      }
    }
    w.history.removeWhere((_, e) => ((e['h'] as int?) ?? 0) > to);
    w.scanned = to;
    w.lastId = chain.idAt(to);
  }

  void _onMempool(List<Uint8List> blobs) {
    for (final blob in blobs) {
      MoneroTx tx;
      try {
        tx = MoneroTx.parse(blob);
      } catch (_) {
        continue;
      }
      final txid = toHex(tx.hash);
      for (final w in wallets.values) {
        for (final o in w.scanner.scan(tx, txid, -1)) {
          if (!w.outputs.containsKey(o.id)) w.mempool[o.id] = o;
        }
      }
    }
  }

  // ---- status ------------------------------------------------------------

  MoneroChainStatus _status() {
    final height = chain.tipHeight + 1;
    return MoneroChainStatus(chain.tipHeight, net.peerCount, _synced, node, {
      for (final w in wallets.values)
        w.id: () {
          final unspent = w.outputs.values.where((o) => o.spentIn == null);
          final history = [
            for (final e in w.history.values)
              MoneroTxEntry(e['txid']! as String, e['h'] as int?, e['r']! as int, e['s']! as int, (e['f'] as int?) ?? 0,
                  e['cb'] == true, (e['t'] as int?) ?? 0,
                  txPub: e['R'] as String?, txKey: e['k'] as String?),
          ]..sort((a, b) => (b.height ?? 1 << 40).compareTo(a.height ?? 1 << 40));
          return MoneroWalletStatus(
            w.id,
            w.account.address.encode(),
            !w.account.canSpend,
            unspent.fold(0, (a, o) => a + o.amount),
            unspent.where((o) => isUnlocked(o, height)).fold(0, (a, o) => a + o.amount),
            w.mempool.values.fold(0, (a, o) => a + o.amount),
            w.scanned,
            history.take(200).toList(),
          );
        }(),
    });
  }

  // ---- sending -----------------------------------------------------------

  List<OwnedOutput> _spendable(_Wallet w) {
    final height = chain.tipHeight + 1;
    return w.outputs.values
        .where((o) => o.spentIn == null && o.blockOffset != null && isUnlocked(o, height))
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
  }

  static int _estimateBytes(int inputs) => 1500 + (inputs - 1) * 720;

  Future<int> _estimateFee(_Wallet w, int amount) async {
    final rpc = MoneroRpc(node);
    try {
      final (fees, mask) = await rpc.feeEstimate();
      final coins = _spendable(w);
      var n = 0, sum = 0;
      for (final c in coins) {
        n++;
        sum += c.amount;
        if (sum >= amount + fees.first * _estimateBytes(n)) break;
      }
      final fee = (fees.first * _estimateBytes(n == 0 ? 1 : n) + mask - 1) ~/ mask * mask;
      if (sum < amount + fee) throw MoneroWalletException('not enough unlocked funds (${sum / 1e12} XMR)');
      return fee;
    } finally {
      rpc.close();
    }
  }

  Future<List<Object?>> _send(_Wallet w, String to, int amount) async {
    if (!w.account.canSpend) throw const MoneroWalletException('a view-only wallet cannot send');
    final dest = MoneroAddress.parse(to);
    if (dest == null || dest.network != MoneroNetwork.mainnet) throw const MoneroWalletException('not a Monero address');
    if (amount <= 0) throw const MoneroWalletException('the amount must be positive');
    final rpc = MoneroRpc(node);
    try {
      log('send: updating the output distribution from $node');
      _dist ??= OutputDistribution.load(_distFile);
      final dist = _dist = await OutputDistribution.update(rpc, _dist);
      dist.save(_distFile);
      final (fees, mask) = await rpc.feeEstimate();
      final coins = _spendable(w);
      final chosen = <OwnedOutput>[];
      var sum = 0;
      for (final c in coins) {
        chosen.add(c);
        sum += c.amount;
        if (sum >= amount + fees.first * _estimateBytes(chosen.length) + mask) break;
      }
      if (sum < amount + fees.first * _estimateBytes(chosen.length)) {
        throw MoneroWalletException('not enough unlocked funds (${sum / 1e12} XMR)');
      }
      for (final o in chosen) {
        o.globalIndex = (o.height == 0 ? 0 : dist.cumulative[o.height - 1]) + o.blockOffset!;
      }
      log('send: picking decoys for ${chosen.length} inputs');
      final rings = await buildRings(rpc, dist,
          [for (final o in chosen) (globalIndex: o.globalIndex!, key: o.key, commitment: o.commitment)]);
      final inputs = [for (var i = 0; i < chosen.length; i++) SpendInput(chosen[i], w.scanner.outputSecret(chosen[i]), rings[i])];
      final built = await Isolate.run(() => buildTransaction(
            inputs: inputs,
            destinations: [Destination(dest, amount)],
            change: w.account.address,
            feePerByte: fees.first,
            quantization: mask,
          ));
      await rpc.submit(built.blob);
      final peers = net.relayTransaction(built.blob);
      log('send: ${built.hash} accepted by $node, relayed to $peers peers, fee ${built.fee}');
      final e = w._entry(built.hash, null, false);
      e['s'] = chosen.fold<int>(0, (a, o) => a + o.amount);
      e['f'] = built.fee;
      e['k'] = toHex(built.txKey);
      for (final o in chosen) {
        o.spentIn = built.hash;
      }
      w.save();
      return [built.hash, built.fee, toHex(built.txKey)];
    } finally {
      rpc.close();
    }
  }
}
