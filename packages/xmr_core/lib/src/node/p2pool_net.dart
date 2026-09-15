import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:net_core/net_core.dart';
import '../monero/difficulty.dart';
import '../monero/light_chain.dart';
import '../p2pool/consensus.dart';
import '../p2pool/p2p_peer.dart';
import '../p2pool/pool_block.dart';
import '../p2pool/sidechain.dart';
import '../randomx/hash_pool.dart';
import '../util/bytes.dart';
import '../util/reader.dart';

/// Keeps outbound connections to P2Pool peers and feeds their shares into
/// the sidechain. Shares near the tip are checked for PoW before they are
/// added; older ones are authenticated by the template ids of their
/// PoW-checked descendants (a template id commits to its parent).
class P2PoolNet {
  final Transport transport;
  final P2PoolConsensus consensus;
  final SideChain sidechain;
  final MoneroLightChain mainChain;
  final HashPool hashes;
  final int targetPeers;
  final void Function(String) log;

  /// A share (ours or a peer's) also meets the Monero difficulty.
  void Function(PoolBlock block)? onMoneroBlockFound;

  final int peerId = Random.secure().nextInt(1 << 32) << 31 | Random.secure().nextInt(1 << 31) | 1;
  final Map<String, _Conn> _conns = {};
  final Set<String> _known = {};
  final Map<String, int> _bannedUntil = {};
  final Random _rng = Random();
  Timer? _timer;
  bool _running = false;

  /// Highest side height any peer reported (tip requests and broadcasts).
  int bestPeerHeight = 0;

  /// Shares waiting for Monero data (seed or difficulty) before checks.
  final List<(PoolBlock, String)> _deferred = [];
  int _inFlightPow = 0;
  int _lastDiagMs = 0;

  /// Ids requested recently (hex -> ms) and ids received but not yet added
  /// (waiting for PoW), so the same share is not fetched over and over.
  final Map<String, int> _requested = {};
  final Set<String> _pendingIds = {};
  int _received = 0;

  P2PoolNet(this.transport, this.consensus, this.sidechain, this.mainChain, this.hashes,
      {this.targetPeers = 8, required this.log}) {
    sidechain.onBroadcast = broadcast;
    // Verify in slices so a big sync never blocks this isolate for long.
    sidechain.verifyBudgetMs = 40;
  }

  bool _pumping = false;

  /// Runs pending sidechain verification between other events.
  void _pumpVerification() {
    if (_pumping || !sidechain.verificationPending) return;
    _pumping = true;
    Timer.run(() {
      _pumping = false;
      if (!_running) return;
      sidechain.continueVerification();
      _pumpVerification();
    });
  }

  int get peerCount => _conns.values.where((c) => c.peer.handshakeComplete).length;
  Iterable<String> get knownPeers => _known;

  /// Synced when our tip is within a few shares of the best peer tip.
  bool get synced {
    final t = sidechain.tip;
    return t != null &&
        bestPeerHeight > 0 &&
        t.side.height + 3 >= bestPeerHeight &&
        _inFlightPow == 0 &&
        !sidechain.verificationPending;
  }

  /// Shares our tip is behind the best peer tip (0 when unknown).
  int get behind {
    final t = sidechain.tip;
    if (t == null) return 1 << 30;
    return bestPeerHeight > t.side.height ? bestPeerHeight - t.side.height : 0;
  }

  void addKnownPeers(Iterable<String> peers) => _known.addAll(peers);

  Future<void> start() async {
    _running = true;
    for (final seed in consensus.seedNodes) {
      for (final ip in await transport.resolve(seed)) {
        _known.add('$ip:${consensus.defaultPort}');
      }
    }
    log('p2pool: ${_known.length} known peers');
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
      final idleLimit = c.peer.handshakeComplete ? 300000 : 15000;
      if (now - c.peer.lastActiveMs > idleLimit) _drop(c.key, ban: false, why: 'idle');
    }
    // Saved peer lists go stale, so dial wider until a few peers answer.
    final live = _conns.values.where((c) => c.peer.handshakeComplete).length;
    final dialLimit = live < 3 ? targetPeers * 3 : targetPeers;
    if (_conns.length < dialLimit) {
      final candidates = _known.where((k) => !_conns.containsKey(k) && (_bannedUntil[k] ?? 0) < now).toList()
        ..shuffle(_rng);
      for (final k in candidates.take(dialLimit - _conns.length)) {
        unawaited(_connect(k));
      }
    }
    if (now - _lastDiagMs > 30000) {
      _lastDiagMs = now;
      log('p2pool: ${sidechain.blockCount} shares stored, tip ${sidechain.tip?.side.height ?? '-'}, '
          'best peer $bestPeerHeight, deferred ${_deferred.length}, PoW in flight $_inFlightPow, '
          'missing ${sidechain.missingBlocks().length}, received $_received');
    }
    _retryDeferred();
    _pumpVerification();
    if (sidechain.tip != null || sidechain.blockCount > 0) {
      for (final id in sidechain.missingBlocks().take(20)) {
        _requestFromSomeone(id);
      }
    }
  }

  Future<void> _connect(String key) async {
    final i = key.lastIndexOf(':');
    final host = key.substring(0, i), port = int.parse(key.substring(i + 1));
    final peer = P2PoolPeer(consensus, peerId);
    final c = _Conn(key, null, peer);
    _conns[key] = c;
    try {
      final conn = await transport.connect(host, port, timeout: const Duration(seconds: 8));
      if (!_running) {
        await conn.close();
        return;
      }
      c.conn = conn;
      peer.start(DateTime.now().millisecondsSinceEpoch);
      _flush(c);
      conn.data.listen(
        (d) => _handle(c, peer.receive(d, DateTime.now().millisecondsSinceEpoch)),
        onDone: () => _drop(key, ban: false, why: 'closed'),
        onError: (Object _) => _drop(key, ban: false, why: 'error'),
        cancelOnError: true,
      );
    } catch (_) {
      _conns.remove(key);
      _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + 300000;
    }
  }

  void _drop(String key, {required bool ban, required String why}) {
    final c = _conns.remove(key);
    if (c == null) return;
    unawaited(c.conn?.close());
    // Failed dials to stale peers are routine; log bans and lost peers only.
    if (ban || c.peer.handshakeComplete) log('p2pool: dropping $key: $why');
    _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + (ban ? 600000 : 60000);
  }

  void _flush(_Conn c) {
    if (c.peer.hasOutgoing) c.conn?.add(c.peer.takeOutgoing());
  }

  void _handle(_Conn c, List<PeerEvent> events) {
    for (final e in events) {
      switch (e) {
        case PeerHandshakeDone():
          if (peerCount <= 3) log('p2pool: connected to ${c.key}');
        case PeerBlock(:final data, :final compact, :final broadcast, :final requestedId):
          _onBlock(c, data, compact: compact, broadcast: broadcast, requestedId: requestedId);
        case PeerBlockMissing():
          break;
        case PeerBlockRequested(:final id):
          _answerRequest(c, id);
        case PeerListRequested():
          final peers = [
            for (final o in _conns.values)
              if (o.peer.isGood && o.key != c.key) _split(o.key)
          ]..shuffle(_rng);
          c.peer.sendPeerList(peers.take(8).toList());
        case PeerAddresses(:final peers):
          if (_known.length < 1000) {
            for (final (h, p) in peers) {
              _known.add('$h:$p');
            }
          }
        case PeerVersion():
          break;
        case PeerBlockNotify(:final id):
          if (_shouldRequest(id)) c.peer.requestBlock(id, bound: 25);
        case PeerFailure(:final reason, :final ban):
          _drop(c.key, ban: ban, why: reason);
          return;
      }
    }
    _flush(c);
  }

  static (String, int) _split(String key) {
    final i = key.lastIndexOf(':');
    return (key.substring(0, i), int.parse(key.substring(i + 1)));
  }

  void _answerRequest(_Conn c, Uint8List id) {
    PoolBlock? b;
    if (isZeroHash(id)) {
      b = sidechain.tip;
      final mt = mainChain.tip;
      if (b != null && mt != null && b.main.genHeight + 2 < mt.height) b = null;
    } else {
      b = sidechain.byId(id);
    }
    if (b != null && c.peer.supports(protocolVersion12)) {
      c.peer.sendNotify(b.side.parent);
      for (final u in b.side.uncles) {
        c.peer.sendNotify(u);
      }
    }
    c.peer.sendBlockResponse(b?.serialize());
  }

  void _onBlock(_Conn c, Uint8List data, {required bool compact, required bool broadcast, Uint8List? requestedId}) {
    _received++;
    PoolBlock block;
    try {
      block = PoolBlock.parse(data, consensus, compact: compact);
    } on FormatError catch (e) {
      _drop(c.key, ban: true, why: 'bad share: $e');
      return;
    }
    if (block.side.height > bestPeerHeight && (broadcast || (requestedId != null && isZeroHash(requestedId)))) {
      bestPeerHeight = block.side.height;
    }
    if (broadcast) {
      c.peer.noteBroadcast(block.fastTemplateId(consensus));
      final mt = mainChain.tip;
      if (mt != null && block.main.genHeight + 5 < mt.height) {
        _drop(c.key, ban: true, why: 'broadcast of a stale share');
        return;
      }
    }
    _process(block, c.key, requestedId);
  }

  void _process(PoolBlock block, String from, [Uint8List? requestedId]) {
    if (sidechain.blockSeen(block)) return;
    final v = sidechain.externalVerify(block);
    if (v.invalid != null) {
      sidechain.blockUnsee(block);
      _drop(from, ban: true, why: 'invalid share: ${v.invalid}');
      return;
    }
    for (final id in v.missing) {
      _requestFrom(from, id);
    }
    if (!v.canAdd) {
      sidechain.blockUnsee(block);
      if (v.cantVerify?.startsWith('cannot fill outputs') ?? false) {
        // Probably waiting on Monero data; retry once it is there.
        if (_deferred.length < 5000) _deferred.add((block, from));
      }
      return;
    }
    if (requestedId != null && !isZeroHash(requestedId) && !bytesEqual(block.templateId(consensus), requestedId)) {
      _drop(from, ban: true, why: 'sent a different share than requested');
      return;
    }
    final needsPow = block.side.height + consensus.chainWindowSize >= max(bestPeerHeight, sidechain.tip?.side.height ?? 0);
    if (!needsPow) {
      _add(block);
      return;
    }
    final seed = mainChain.seedIdFor(block.main.genHeight);
    if (seed == null) {
      sidechain.blockUnsee(block);
      if (_deferred.length < 5000) _deferred.add((block, from));
      return;
    }
    _inFlightPow++;
    final pid = toHex(block.templateId(consensus));
    _pendingIds.add(pid);
    unawaited(() async {
      try {
        await hashes.addVerificationSeed(seed);
        final pow = await hashes.hash(seed, block.main.hashingBlob());
        block.powHash = pow;
        final mainDiff = mainChain.difficultyAt(block.main.genHeight);
        // Relay to Monero only blocks that would extend its chain; shares
        // fetched while syncing can be Monero blocks mined long ago.
        final tip = mainChain.tip;
        if (mainDiff != null && checkPow(pow, mainDiff) && (tip == null || block.main.genHeight > tip.height)) {
          log('p2pool: share at ${block.side.height} is a Monero block at ${block.main.genHeight}');
          onMoneroBlockFound?.call(block);
        }
        if (!checkPow(pow, block.side.difficulty)) {
          sidechain.blockUnsee(block);
          _drop(from, ban: true, why: 'not enough PoW');
          return;
        }
        _add(block);
      } catch (e) {
        sidechain.blockUnsee(block);
        log('p2pool: PoW check failed: $e');
      } finally {
        _inFlightPow--;
        _pendingIds.remove(pid);
      }
    }());
  }

  void _add(PoolBlock block) {
    final r = sidechain.addBlock(block);
    if (r.invalid != null) log('p2pool: share at ${block.side.height} invalid: ${r.invalid}');
    for (final id in r.missing) {
      _requestFromSomeone(id);
    }
    _pumpVerification();
  }

  void _retryDeferred() {
    if (_deferred.isEmpty) return;
    final items = List.of(_deferred);
    _deferred.clear();
    for (final (b, from) in items) {
      _process(b, from);
    }
  }

  bool _shouldRequest(Uint8List id) {
    if (sidechain.byId(id) != null) return false;
    final k = toHex(id);
    if (_pendingIds.contains(k)) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _requested[k];
    if (last != null && now - last < 15000) return false;
    _requested[k] = now;
    if (_requested.length > 20000) _requested.removeWhere((_, t) => now - t > 60000);
    return true;
  }

  void _requestFrom(String key, Uint8List id) {
    final c = _conns[key];
    if (c == null || !c.peer.handshakeComplete) {
      _requestFromSomeone(id);
      return;
    }
    if (!_shouldRequest(id)) return;
    c.peer.requestBlock(id);
    _flush(c);
  }

  void _requestFromSomeone(Uint8List id) {
    if (!_shouldRequest(id)) return;
    final good = _conns.values.where((c) => c.peer.isGood && c.peer.pendingRequests < 20).toList();
    if (good.isEmpty) return;
    final c = good[_rng.nextInt(good.length)];
    c.peer.requestBlock(id);
    _flush(c);
  }

  /// Relays [block] to every peer in the cheapest format it can use.
  void broadcast(PoolBlock block) {
    final id = block.templateId(consensus);
    final idHex = toHex(id);
    Uint8List? full, pruned, compact;
    for (final c in _conns.values) {
      if (!c.peer.isGood) continue;
      final seen = c.peer.broadcastedHashes;
      final hasAncestors =
          seen.contains(toHex(block.side.parent)) && block.side.uncles.every((u) => seen.contains(toHex(u)));
      if (hasAncestors && seen.contains(idHex) && c.peer.supports(protocolVersion12)) {
        c.peer.sendNotify(id);
      } else if (hasAncestors && c.peer.supports((1 << 16) | 1)) {
        compact ??= block.serialize(pruned: true, compact: true);
        pruned ??= block.serialize(pruned: true);
        if (compact.length < pruned.length) {
          c.peer.sendBroadcast(compact, compact: true);
        } else {
          c.peer.sendBroadcast(pruned);
        }
      } else if (hasAncestors) {
        pruned ??= block.serialize(pruned: true);
        c.peer.sendBroadcast(pruned);
      } else {
        full ??= block.serialize();
        c.peer.sendBroadcast(full);
      }
      _flush(c);
    }
  }

  /// Adds a share we mined and relays it.
  VerifyResult submitOwnShare(PoolBlock block) {
    sidechain.blockSeen(block);
    block.wantBroadcast = true; // relayed by the sidechain once verified
    final r = sidechain.addBlock(block);
    _pumpVerification();
    return r;
  }
}

class _Conn {
  final String key;
  Connection? conn;
  final P2PoolPeer peer;
  _Conn(this.key, this.conn, this.peer);
}
