import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:net_core/net_core.dart';

import 'block.dart';
import 'bytes.dart';
import 'header_chain.dart';
import 'params.dart';
import 'peer.dart';
import 'wire.dart';

/// A light node of a Bitcoin-family chain: keeps a few peers, follows the
/// best header chain from a checkpoint, and broadcasts blocks and
/// transactions. It stores headers only and trusts nothing it cannot check
/// from them.
class UtxoNode {
  final ChainParams params;
  final Transport transport;
  final HeaderCheckpoint checkpoint;
  final String? dataDir;
  final int targetPeers;
  final void Function(String line)? log;

  late HeaderChain chain;
  final Map<String, Peer> _peers = {};
  final Set<String> _known = {};
  final Set<String> _good = {}; // completed a handshake (now or in an earlier run)
  final Set<String> _dialing = {};
  final Map<String, int> _bannedUntil = {};
  final Random _rng = Random();
  final StreamController<int> _tip = StreamController.broadcast();
  final StreamController<(Peer, WireMessage)> _messages = StreamController.broadcast();
  final StreamController<Peer> _connected = StreamController.broadcast();
  Timer? _timer;
  bool _running = false;
  int _bestPeerHeight = 0;
  int _lastSaveMs = 0;

  UtxoNode({
    required this.params,
    required this.transport,
    required this.checkpoint,
    this.dataDir,
    this.targetPeers = 6,
    this.log,
  });

  /// Emits the new tip height whenever the best chain changes.
  Stream<int> get tipChanges => _tip.stream;

  /// Every message from every peer (for the wallet: merkleblock, tx).
  Stream<(Peer, WireMessage)> get messages => _messages.stream;

  /// Peers after their handshake (the wallet loads its filter into them).
  Stream<Peer> get peerConnected => _connected.stream;

  List<Peer> get peers => _peers.values.toList();
  int get peerCount => _peers.length;
  int get bestPeerHeight => max(_bestPeerHeight, chain.tipHeight);

  /// Caught up with the peers (within two blocks of the best one we know).
  bool get synced => _peers.isNotEmpty && chain.tipHeight >= _bestPeerHeight - 2;

  File? get _chainFile => dataDir == null ? null : File('$dataDir/headers.bin');
  File? get _peersFile => dataDir == null ? null : File('$dataDir/peers.txt');
  File? get _goodPeersFile => dataDir == null ? null : File('$dataDir/good-peers.txt');

  Future<void> start() async {
    _running = true;
    chain = HeaderChain(params, checkpoint);
    final f = _chainFile;
    if (f != null && f.existsSync()) {
      final restored = HeaderChain.restore(params, checkpoint, f.readAsBytesSync());
      if (restored != null) {
        chain = restored;
        log?.call('loaded ${chain.tipHeight - checkpoint.height} headers after the checkpoint, tip ${chain.tipHeight}');
      }
    }
    _known.addAll(params.fixedPeers);
    final pf = _peersFile;
    if (pf != null && pf.existsSync()) _known.addAll(pf.readAsLinesSync().where((l) => l.contains(':')));
    final gf = _goodPeersFile;
    if (gf != null && gf.existsSync()) _good.addAll(gf.readAsLinesSync().where((l) => l.contains(':')));
    unawaited(_resolveSeeds());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _maintain());
    _maintain();
  }

  Future<void> _resolveSeeds() async {
    for (final s in params.dnsSeeds) {
      for (final ip in await transport.resolve(s)) {
        _known.add('$ip:${params.port}');
      }
    }
  }

  void _maintain() {
    if (!_running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in _peers.values.toList()) {
      if (now - p.lastActiveMs > 180000) {
        p.send('ping', Msg.ping(_rng.nextInt(1 << 32)));
      }
      if (now - p.lastActiveMs > 300000) _drop(p, 'idle');
    }
    // Gossiped addresses are mostly gone (home connections), so dial
    // known-good ones first and more at once while there are no peers.
    final want = (_peers.isEmpty ? targetPeers * 2 : targetPeers) - _peers.length - _dialing.length;
    if (want > 0) {
      bool free(String k) => !_peers.containsKey(k) && !_dialing.contains(k) && (_bannedUntil[k] ?? 0) < now;
      final trusted = {..._good, ...params.fixedPeers}.where(free).toList()..shuffle(_rng);
      final others = _known.where((k) => free(k) && !trusted.contains(k)).toList()..shuffle(_rng);
      for (final k in [...trusted, ...others].take(want)) {
        unawaited(_connect(k));
      }
    }
    if (now - _lastSaveMs > 60000) _save();
  }

  Future<void> _connect(String key) async {
    _dialing.add(key);
    try {
      final (host, port) = splitHostPort(key, params.port);
      final p = await Peer.connect(transport, params, host, port, startHeight: chain.tipHeight);
      if (!_running) {
        await p.close();
        return;
      }
      _peers[key] = p;
      _good.add(key);
      _bestPeerHeight = max(_bestPeerHeight, p.startHeight);
      log?.call('connected to $p');
      p.messages.listen((m) => _onMessage(key, p, m));
      unawaited(p.closed.then((_) {
        if (_peers[key] == p) _peers.remove(key);
      }));
      p.send('getaddr');
      _requestHeaders(p);
      if (!_connected.isClosed) _connected.add(p);
    } catch (_) {
      // Retry known-good peers soon, gossiped addresses much later.
      final wait = _good.contains(key) || params.fixedPeers.contains(key) ? 60000 : 1800000;
      _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + wait;
    } finally {
      _dialing.remove(key);
    }
  }

  void _drop(Peer p, String why, {bool ban = false}) {
    final key = _peers.entries.firstWhere((e) => e.value == p, orElse: () => MapEntry('', p)).key;
    if (ban && key.isNotEmpty) _bannedUntil[key] = DateTime.now().millisecondsSinceEpoch + 3600000;
    log?.call('dropping ${p.address}: $why');
    unawaited(p.close());
    _peers.remove(key);
  }

  void _requestHeaders(Peer p) => p.send('getheaders', Msg.getHeaders(params.protocolVersion, chain.locator()));

  void _onMessage(String key, Peer p, WireMessage m) {
    if (!_messages.isClosed) _messages.add((p, m));
    switch (m.command) {
      case 'headers':
        _onHeaders(p, m.payload);
      case 'inv':
        try {
          if (Msg.parseInv(m.payload).any((i) => i.type == InvType.block)) _requestHeaders(p);
        } on FormatException {
          _drop(p, 'bad inv', ban: true);
        }
      case 'addr':
        try {
          _known.addAll(Msg.parseAddr(m.payload).where((a) => a.endsWith(':${params.port}')).take(1000));
        } on FormatException {
          // ignore
        }
      case 'block':
        // A full block (ours echoed, or unrequested): its header is enough.
        try {
          final b = Block.read(ByteReader(m.payload));
          _onHeaderList(p, [b.header]);
        } on FormatException {
          // ignore
        }
    }
  }

  void _onHeaders(Peer p, Uint8List payload) {
    List<BlockHeader> headers;
    try {
      headers = Msg.parseHeaders(payload);
    } on FormatException {
      _drop(p, 'bad headers', ban: true);
      return;
    }
    _onHeaderList(p, headers);
    if (headers.length == 2000) _requestHeaders(p);
  }

  void _onHeaderList(Peer p, List<BlockHeader> headers) {
    if (headers.isEmpty) return;
    // Headers we already have (a peer answering an old locator) are fine.
    final fresh = headers.skipWhile((h) => chain.heightOf(h.hash) != null).toList();
    if (fresh.isEmpty) return;
    if (chain.heightOf(fresh.first.prevHash) == null) {
      // Does not connect yet (a new block after one we lack): ask again.
      _requestHeaders(p);
      return;
    }
    final before = chain.tipHeight;
    try {
      final added = chain.add(fresh);
      if (added > 0) {
        _bestPeerHeight = max(_bestPeerHeight, chain.tipHeight);
        if (chain.tipHeight != before || added > 0) _tip.add(chain.tipHeight);
      }
    } on HeaderRejected catch (e) {
      _drop(p, '$e', ban: true);
    }
  }

  /// Adds the header of a block we made ourselves, so the next work builds
  /// on it at once instead of competing with it. False if it does not fit.
  bool addOwnHeader(BlockHeader h) {
    if (chain.heightOf(h.hash) != null) return true;
    try {
      if (chain.add([h]) > 0) {
        _bestPeerHeight = max(_bestPeerHeight, chain.tipHeight);
        if (!_tip.isClosed) _tip.add(chain.tipHeight);
        return true;
      }
    } on HeaderRejected catch (e) {
      log?.call('our own block does not fit the chain: $e');
    }
    return false;
  }

  /// Sends a block to every peer. Returns how many peers it went to.
  int broadcastBlock(Block b) {
    final payload = b.serialize();
    for (final p in _peers.values) {
      p.send('block', payload);
    }
    return _peers.length;
  }

  int broadcastTransaction(Transaction t) {
    final payload = t.serialize();
    for (final p in _peers.values) {
      p.send('tx', payload);
    }
    return _peers.length;
  }

  /// Asks every peer for headers now (after a found block, for example).
  void refresh() {
    for (final p in _peers.values) {
      _requestHeaders(p);
    }
  }

  void _save() {
    _lastSaveMs = DateTime.now().millisecondsSinceEpoch;
    final dir = dataDir;
    if (dir == null) return;
    try {
      Directory(dir).createSync(recursive: true);
      chain.save(_chainFile!);
      _goodPeersFile!.writeAsStringSync({..._peers.keys, ..._good}.take(100).join('\n'));
      _peersFile!.writeAsStringSync(_known.take(500).join('\n'));
    } catch (_) {}
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _save();
    for (final p in _peers.values.toList()) {
      await p.close();
    }
    _peers.clear();
    await _tip.close();
    await _messages.close();
    await _connected.close();
  }
}
