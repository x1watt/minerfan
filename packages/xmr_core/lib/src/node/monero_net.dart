import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:net_core/net_core.dart';
import '../levin/levin_peer.dart';
import '../levin/messages.dart';
import '../monero/block.dart';
import '../monero/difficulty.dart';
import '../monero/light_chain.dart';
import '../randomx/hash_pool.dart';

/// Keeps a few levin connections to Monero peers and drives the light chain:
/// initial sync from the checkpoint or the saved window, following new
/// blocks, PoW checks, cumulative difficulty cross-checks and block
/// submission.
class MoneroNet {
  static const List<String> seedNodes = [
    '176.9.0.187:18080',
    '88.198.163.90:18080',
    '192.99.8.110:18080',
    '37.187.74.171:18080',
    '88.99.195.15:18080',
    '5.104.84.64:18080',
  ];

  final Transport transport;
  final MoneroLightChain chain;
  final HashPool hashes;
  final int targetPeers;
  final void Function(String) log;

  /// A new block became the tip (after the initial sync too).
  void Function(MoneroBlock block)? onNewTip;

  /// The chain reached the peers' tip for the first time.
  void Function()? onSynced;

  /// Transactions peers relay (the mempool), for wallets.
  void Function(List<Uint8List> txBlobs)? onNewTransactions;

  /// Requests a wallet made on a connection (one at a time per connection),
  /// answered by its next objects or chain entry.
  final Map<String, Completer<Object>> _walletRequests = {};

  final Map<String, _Conn> _conns = {};
  final Set<String> _known = {...seedNodes};
  final Map<String, int> _bannedUntil = {};
  String? _fetcher;
  int _fetchStartedMs = 0;
  bool _wasSynced = false;
  int _lastSyncCheckMs = 0;
  Timer? _timer;
  bool _running = false;
  final Random _rng = Random();

  MoneroNet(this.transport, this.chain, this.hashes, {this.targetPeers = 3, required this.log});

  int get peerCount => _conns.values.where((c) => c.peer.isReady).length;
  bool get synced => chain.isSynced && chain.agreeingPeers.isNotEmpty;
  Iterable<String> get knownPeers => _known;

  void addKnownPeers(Iterable<String> peers) => _known.addAll(peers);

  void start() {
    _running = true;
    _maintain();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _maintain());
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    for (final c in _conns.values.toList()) {
      await c.conn?.close();
    }
    _conns.clear();
  }

  void _maintain() {
    if (!_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final c in _conns.values.toList()) {
      _handle(c, c.peer.tick(now));
    }
    if (_fetcher != null && now - _fetchStartedMs > 60000) {
      log('monero: fetch from $_fetcher stalled, switching peer');
      _drop(_fetcher!, ban: false);
    }
    final pending = _conns.length;
    if (pending < targetPeers) {
      final candidates = _known.where((k) => !_conns.containsKey(k) && (_bannedUntil[k] ?? 0) < now).toList()
        ..shuffle(_rng);
      for (final k in candidates.take(targetPeers - pending)) {
        unawaited(_connect(k));
      }
    }
    _syncStep();
  }

  Future<void> _connect(String key) async {
    final i = key.lastIndexOf(':');
    final host = key.substring(0, i), port = int.parse(key.substring(i + 1));
    final peer = LevinPeer(localSync: chain.localSync);
    final placeholder = _Conn(key, null, peer);
    _conns[key] = placeholder;
    try {
      final conn = await transport.connect(host, port, timeout: const Duration(seconds: 8));
      if (!_running) {
        await conn.close();
        return;
      }
      placeholder.conn = conn;
      conn.add(peer.startHandshake(DateTime.now().millisecondsSinceEpoch));
      conn.data.listen(
        (d) => _handle(placeholder, peer.receive(d, DateTime.now().millisecondsSinceEpoch)),
        onDone: () => _drop(key, ban: false),
        onError: (Object _) => _drop(key, ban: false),
        cancelOnError: true,
      );
    } catch (_) {
      _conns.remove(key);
      _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + 120000;
    }
  }

  void _drop(String key, {required bool ban}) {
    final c = _conns.remove(key);
    _walletRequests.remove(key)?.completeError(StateError('peer $key closed'));
    if (c == null) return;
    unawaited(c.conn?.close());
    if (_fetcher == key) _fetcher = null;
    _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + (ban ? 3600000 : 60000);
  }

  void _flush(_Conn c) {
    if (c.peer.hasOutgoing) c.conn?.add(c.peer.takeOutgoing());
  }

  void _handle(_Conn c, List<LevinEvent> events) {
    for (final e in events) {
      switch (e) {
        case HandshakeDone(:final coreSync, :final peers):
          chain.noteRemoteTip(coreSync);
          chain.crossCheck(c.key.hashCode, coreSync);
          _learn(peers);
        case CoreSyncUpdate(:final coreSync, :final peers):
          chain.noteRemoteTip(coreSync);
          if (chain.crossCheck(c.key.hashCode, coreSync) == false) {
            log('monero: ${c.key} disagrees on cumulative difficulty');
          }
          _learn(peers);
        case ChainEntry(:final entry) when _walletRequests.containsKey(c.key):
          _walletRequests.remove(c.key)!.complete(entry);
        case ObjectsResponse(:final response) when _walletRequests.containsKey(c.key):
          _walletRequests.remove(c.key)!.complete(response);
        case NewTransactions(:final txs):
          onNewTransactions?.call(txs);
        case ChainEntry(:final entry):
          if (_fetcher == c.key) {
            if (!chain.onChainEntry(entry)) {
              log('monero: chain entry from ${c.key} does not connect');
              _fetcher = null;
            } else {
              _requestObjects(c);
            }
          }
        case ObjectsResponse(:final blocks):
          if (_fetcher == c.key) {
            for (final rb in blocks) {
              final b = rb.block;
              if (b == null) continue;
              try {
                chain.addBlock(b);
              } on LightChainError catch (err) {
                log('monero: bad block from ${c.key}: $err');
                _drop(c.key, ban: true);
                return;
              }
            }
            _runPowChecks(c.key);
            if (chain.pendingFetches > 0) {
              _requestObjects(c);
            } else {
              _fetcher = null;
            }
          }
        case NewBlock(:final block):
          final b = block.block;
          if (b == null) break;
          final wasTip = chain.tipHeight;
          try {
            chain.addBlock(b);
          } on LightChainError {
            // Unknown parent: we are behind; the sync step catches up.
            break;
          }
          _runPowChecks(c.key);
          if (chain.tipHeight > wasTip && _wasSynced) onNewTip?.call(b);
        case LevinClosed(:final reason, :final isError):
          if (isError) log('monero: ${c.key} closed: $reason');
          _drop(c.key, ban: false);
        default:
          break;
      }
    }
    _flush(c);
    _syncStep();
  }

  void _learn(List<PeerlistEntry> peers) {
    if (_known.length > 2000) return;
    for (final p in peers) {
      if (p.ip.length == 4) _known.add('${p.ip[0]}.${p.ip[1]}.${p.ip[2]}.${p.ip[3]}:${p.port}');
    }
  }

  void _requestObjects(_Conn c) {
    final ids = chain.nextFetch();
    if (ids.isEmpty) {
      _fetcher = null;
      return;
    }
    _fetchStartedMs = DateTime.now().millisecondsSinceEpoch;
    c.peer.requestObjects(ids);
    _flush(c);
  }

  void _syncStep() {
    if (!_running) return;
    final ready = _conns.values.where((c) => c.peer.isReady).toList();
    for (final c in ready) {
      final s = chain.localSync;
      final cur = c.peer.localSync;
      if (s.currentHeight > cur.currentHeight) c.peer.setLocalSync(s.currentHeight, s.cumulativeDifficulty, s.topId, s.topVersion);
    }
    if (_fetcher == null && chain.tipHeight < chain.bestKnownHeight && ready.isNotEmpty) {
      // Ask the peer with the highest advertised tip.
      ready.sort((a, b) => (b.peer.remoteSync?.currentHeight ?? 0).compareTo(a.peer.remoteSync?.currentHeight ?? 0));
      final c = ready.first;
      _fetcher = c.key;
      _fetchStartedMs = DateTime.now().millisecondsSinceEpoch;
      c.peer.requestChain(chain.sparseIds());
      _flush(c);
    }
    if (!_wasSynced && chain.isSynced && chain.agreeingPeers.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSyncCheckMs > 15000) {
        _lastSyncCheckMs = now;
        for (final c in ready) {
          c.peer.sendTimedSync();
          _flush(c);
        }
      }
    }
    if (!_wasSynced && chain.isSynced && chain.agreeingPeers.isNotEmpty) {
      _wasSynced = true;
      log('monero: synced at height ${chain.tipHeight}');
      onSynced?.call();
    }
  }

  Future<void> _runPowChecks(String source) async {
    for (final check in chain.takePowChecks()) {
      try {
        await hashes.addVerificationSeed(check.seedId);
        final pow = await hashes.hash(check.seedId, check.hashingBlob);
        chain.powResult(check, checkPow(pow, check.difficulty));
      } on LightChainError catch (e) {
        log('monero: $e (from $source)');
        _drop(source, ban: true);
      } catch (e) {
        log('monero: PoW check error: $e');
      }
    }
  }

  _Conn _walletPeer() {
    final ready = _conns.values.where((c) => c.peer.isReady && !_walletRequests.containsKey(c.key)).toList();
    if (ready.isEmpty) throw StateError('no Monero peer free');
    // Leave the chain's fetcher alone when another peer is free.
    ready.sort((a, b) => (a.key == _fetcher ? 1 : 0).compareTo(b.key == _fetcher ? 1 : 0));
    return ready.first;
  }

  Future<T> _walletRequest<T extends Object>(void Function(_Conn c) send) async {
    final c = _walletPeer();
    final done = Completer<Object>();
    _walletRequests[c.key] = done;
    send(c);
    _flush(c);
    try {
      return await done.future.timeout(const Duration(seconds: 90)) as T;
    } on TimeoutException {
      _walletRequests.remove(c.key);
      _drop(c.key, ban: false);
      rethrow;
    }
  }

  /// Blocks by id with their transactions (pruned: prefix and RingCT base,
  /// which is all a wallet scan needs), for wallets.
  Future<ResponseGetObjects> fetchBlocks(List<Uint8List> ids) =>
      _walletRequest<ResponseGetObjects>((c) => c.peer.requestObjects(ids, prune: true));

  /// The block ids after the newest of [sparseIds] (ending with genesis).
  Future<ResponseChainEntry> fetchChainEntry(List<Uint8List> sparseIds) =>
      _walletRequest<ResponseChainEntry>((c) => c.peer.requestChain(sparseIds));

  /// Relays a transaction to every connected peer.
  int relayTransaction(Uint8List txBlob) {
    var n = 0;
    for (final c in _conns.values) {
      if (!c.peer.isReady) continue;
      c.peer.sendTransactions([txBlob]);
      _flush(c);
      n++;
    }
    return n;
  }

  /// Sends a found block to every connected Monero peer.
  void submitBlock(Uint8List blockBlob, int height) {
    for (final c in _conns.values) {
      if (!c.peer.isReady) continue;
      c.peer.broadcastFluffyBlock(blockBlob, const [], height + 1);
      _flush(c);
    }
    log('monero: submitted block at height $height to $peerCount peers');
  }
}

class _Conn {
  final String key;
  Connection? conn;
  final LevinPeer peer;
  _Conn(this.key, this.conn, this.peer);
}
