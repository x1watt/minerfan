import 'dart:math';
import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../util/bytes.dart';
import '../util/u64.dart';
import '../util/varint.dart';
import 'consensus.dart';

/// Sans-IO P2Pool peer connection (outbound). Feed received bytes to
/// [receive], send what [takeOutgoing] returns. Protocol per DataHoarder's
/// P2Pool consensus `p2p` package (MIT) and P2Pool's p2p_server.

const int msgHandshakeChallenge = 0, msgHandshakeSolution = 1, msgListenPort = 2, msgBlockRequest = 3;
const int msgBlockResponse = 4, msgBlockBroadcast = 5, msgPeerListRequest = 6, msgPeerListResponse = 7;
const int msgBlockBroadcastCompact = 8, msgBlockNotify = 9, msgAuxJobDonation = 10, msgMoneroBlockBroadcast = 11;

const int protocolVersion12 = (1 << 16) | 2;
const int challengeDifficulty = 10000;
const int maxPeerListEntries = 16;
const int maxPendingRequests = 80;

sealed class PeerEvent {}

class PeerHandshakeDone extends PeerEvent {
  final int peerId;
  PeerHandshakeDone(this.peerId);
}

/// A share arrived. [requestedId] is the id we asked for (zero for a tip
/// request), null for a broadcast.
class PeerBlock extends PeerEvent {
  final Uint8List data;
  final bool compact;
  final bool broadcast;
  final Uint8List? requestedId;
  PeerBlock(this.data, {required this.compact, required this.broadcast, this.requestedId});
}

/// A BLOCK_RESPONSE with size 0: the peer does not have [requestedId].
class PeerBlockMissing extends PeerEvent {
  final Uint8List requestedId;
  PeerBlockMissing(this.requestedId);
}

class PeerBlockRequested extends PeerEvent {
  final Uint8List id; // zero = our tip
  PeerBlockRequested(this.id);
}

class PeerBlockNotify extends PeerEvent {
  final Uint8List id;
  PeerBlockNotify(this.id);
}

class PeerListRequested extends PeerEvent {}

class PeerAddresses extends PeerEvent {
  final List<(String host, int port)> peers;
  PeerAddresses(this.peers);
}

/// Protocol and software version the peer announced.
class PeerVersion extends PeerEvent {
  final int protocol, softwareVersion, softwareId;
  PeerVersion(this.protocol, this.softwareVersion, this.softwareId);
}

/// The connection must be dropped; [ban] when the peer misbehaved.
class PeerFailure extends PeerEvent {
  final String reason;
  final bool ban;
  PeerFailure(this.reason, {this.ban = true});
}

class P2PoolPeer {
  final P2PoolConsensus consensus;
  final int ourPeerId;
  final int listenPort;
  final Random _rng;

  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<int> _in = [];
  final Uint8List _challenge = Uint8List(8);

  bool handshakeComplete = false;
  bool _sentSolution = false;
  bool _receivedChallenge = false;
  bool _failed = false;
  int peerId = 0;
  int peerListenPort = 0;
  int protocol = 0, softwareVersion = 0, softwareId = 0;

  /// Ids we requested, answered in order.
  final List<Uint8List> _pending = [];

  /// Last ids this peer broadcast or notified (to pick BLOCK_NOTIFY).
  final List<String> broadcastedHashes = [];

  int lastActiveMs = 0;
  int lastBroadcastMs = 0;

  P2PoolPeer(this.consensus, this.ourPeerId, {this.listenPort = 0, Random? rng}) : _rng = rng ?? Random.secure();

  bool get isGood => handshakeComplete && peerListenPort > 0;
  int get pendingRequests => _pending.length;

  bool supports(int minProtocol) => protocol >= minProtocol;

  /// Bytes to send on connect.
  void start(int nowMs) {
    lastActiveMs = nowMs;
    for (var i = 0; i < 8; i++) {
      _challenge[i] = _rng.nextInt(256);
    }
    final b = Uint8List(16)..setRange(0, 8, _challenge);
    writeU64LE(b, 8, ourPeerId);
    _send(msgHandshakeChallenge, b);
  }

  Uint8List takeOutgoing() => _out.takeBytes();
  bool get hasOutgoing => _out.isNotEmpty;

  void _send(int id, [List<int>? payload]) {
    _out.addByte(id);
    if (payload != null) _out.add(payload);
  }

  // ---- outgoing messages ------------------------------------------------

  bool requestBlock(Uint8List id, {int bound = maxPendingRequests}) {
    if (_pending.length >= bound) return false;
    _pending.add(Uint8List.fromList(id));
    _send(msgBlockRequest, id);
    return true;
  }

  void sendBlockResponse(Uint8List? blob) {
    final n = Uint8List(4);
    if (blob == null) {
      _send(msgBlockResponse, n);
      return;
    }
    writeU32LE(n, 0, blob.length);
    _send(msgBlockResponse, concatBytes([n, blob]));
  }

  void sendBroadcast(Uint8List blob, {bool compact = false}) {
    final n = Uint8List(4);
    writeU32LE(n, 0, blob.length);
    _send(compact ? msgBlockBroadcastCompact : msgBlockBroadcast, concatBytes([n, blob]));
  }

  void sendNotify(Uint8List id) => _send(msgBlockNotify, id);

  void requestPeerList() => _send(msgPeerListRequest);

  /// Answers PEER_LIST_REQUEST; the first entry carries our version.
  void sendPeerList(List<(String, int)> peers, {bool includeVersion = true}) {
    final entries = <Uint8List>[];
    if (includeVersion) {
      final e = Uint8List(19);
      writeU32LE(e, 1, protocolVersion12);
      writeU32LE(e, 5, 0x00000100); // software version 0.1.0
      writeU32LE(e, 9, 0x44524d58); // "XMRD"
      writeU32LE(e, 13, 0xffffffff);
      e[17] = 0xff;
      e[18] = 0xff;
      entries.add(e);
    }
    for (final (host, port) in peers) {
      if (entries.length >= maxPeerListEntries) break;
      final ip = _parseIp(host);
      if (ip == null) continue;
      final e = Uint8List(19);
      e[0] = ip.$1 ? 1 : 0;
      e.setRange(1, 17, ip.$2);
      e[17] = port & 0xff;
      e[18] = (port >> 8) & 0xff;
      entries.add(e);
    }
    _send(msgPeerListResponse, concatBytes([
      [entries.length],
      ...entries
    ]));
  }

  static (bool, Uint8List)? _parseIp(String host) {
    final v4 = host.split('.');
    if (v4.length == 4) {
      final b = Uint8List(16);
      b[10] = 0xff;
      b[11] = 0xff;
      for (var i = 0; i < 4; i++) {
        final x = int.tryParse(v4[i]);
        if (x == null || x < 0 || x > 255) return null;
        b[12 + i] = x;
      }
      return (false, b);
    }
    return null; // IPv6 peers are learned but not re-advertised
  }

  // ---- incoming ---------------------------------------------------------

  List<PeerEvent> receive(Uint8List chunk, int nowMs) {
    if (_failed) return const [];
    _in.addAll(chunk);
    final events = <PeerEvent>[];
    while (_in.isNotEmpty && !_failed) {
      final consumed = _parseOne(events, nowMs);
      if (consumed == 0) break;
      _in.removeRange(0, consumed);
      lastActiveMs = nowMs;
    }
    return events;
  }

  PeerFailure _fail(List<PeerEvent> ev, String why, {bool ban = true}) {
    _failed = true;
    final f = PeerFailure(why, ban: ban);
    ev.add(f);
    return f;
  }

  int _need(int n) => _in.length >= n ? n : 0;

  /// Parses one message; returns bytes consumed, 0 if incomplete.
  int _parseOne(List<PeerEvent> ev, int nowMs) {
    final id = _in[0];
    if (!handshakeComplete) {
      final expected = _receivedChallenge ? msgHandshakeSolution : msgHandshakeChallenge;
      if (id != expected) {
        _fail(ev, 'unexpected pre-handshake message $id');
        return 1;
      }
    }
    Uint8List body(int from, int len) => Uint8List.fromList(_in.sublist(from, from + len));
    int sized(int maxSize) {
      if (_in.length < 5) return 0;
      final n = readU32LE(_in, 1);
      if (n > maxSize) {
        _fail(ev, 'message $id too large ($n)');
        return 1;
      }
      return _in.length >= 5 + n ? 5 + n : 0;
    }

    switch (id) {
      case msgHandshakeChallenge:
        final n = _need(17);
        if (n == 0) return 0;
        if (handshakeComplete || _receivedChallenge) {
          _fail(ev, 'repeated handshake challenge');
          return n;
        }
        final challenge = body(1, 8);
        final pid = readU64LE(_in, 9);
        if (pid == 0) {
          _fail(ev, 'invalid peer id');
          return n;
        }
        if (pid == ourPeerId) {
          _fail(ev, 'connected to self', ban: false);
          return n;
        }
        peerId = pid;
        _receivedChallenge = true;
        _sendSolution(challenge);
        return n;
      case msgHandshakeSolution:
        final n = _need(41);
        if (n == 0) return 0;
        final hash = body(1, 32);
        final salt = readU64LE(_in, 33);
        final expect = _challengeHash(_challenge, salt);
        if (!bytesEqual(hash, expect)) {
          _fail(ev, 'wrong handshake solution hash');
          return n;
        }
        handshakeComplete = true;
        if (_sentSolution) _afterHandshake(ev, nowMs);
        return n;
      case msgListenPort:
        final n = _need(5);
        if (n == 0) return 0;
        final port = readU32LE(_in, 1);
        if (peerListenPort != 0 || port == 0 || port >= 65536) {
          _fail(ev, 'bad LISTEN_PORT');
          return n;
        }
        peerListenPort = port;
        return n;
      case msgBlockRequest:
        final n = _need(33);
        if (n == 0) return 0;
        ev.add(PeerBlockRequested(body(1, 32)));
        return n;
      case msgBlockResponse:
        final n = sized(poolBlockMaxTemplateSize);
        if (n <= 1) return n;
        if (_pending.isEmpty) {
          _fail(ev, 'unexpected BLOCK_RESPONSE');
          return n;
        }
        final req = _pending.removeAt(0);
        if (n == 5) {
          ev.add(PeerBlockMissing(req));
        } else {
          ev.add(PeerBlock(body(5, n - 5), compact: false, broadcast: false, requestedId: req));
        }
        return n;
      case msgBlockBroadcast || msgBlockBroadcastCompact:
        final n = sized(poolBlockMaxTemplateSize);
        if (n <= 1) return n;
        lastBroadcastMs = nowMs;
        if (n > 5) ev.add(PeerBlock(body(5, n - 5), compact: id == msgBlockBroadcastCompact, broadcast: true));
        return n;
      case msgPeerListRequest:
        ev.add(PeerListRequested());
        return 1;
      case msgPeerListResponse:
        if (_in.length < 2) return 0;
        final count = _in[1];
        if (count > maxPeerListEntries) {
          _fail(ev, 'too many peers in list');
          return 2;
        }
        final n = _need(2 + 19 * count);
        if (n == 0) return 0;
        final peers = <(String, int)>[];
        for (var i = 0; i < count; i++) {
          final o = 2 + 19 * i;
          final isV6 = _in[o] != 0;
          final ip = _in.sublist(o + 1, o + 17);
          final port = _in[o + 17] | (_in[o + 18] << 8);
          if (!isV6) {
            if (ip[12] == 0 || ip[12] >= 224) {
              if (readU32LE(ip, 12) == 0xffffffff && port == 0xffff) {
                protocol = readU32LE(ip, 0);
                softwareVersion = readU32LE(ip, 4);
                softwareId = readU32LE(ip, 8);
                ev.add(PeerVersion(protocol, softwareVersion, softwareId));
              }
              continue;
            }
            peers.add(('${ip[12]}.${ip[13]}.${ip[14]}.${ip[15]}', port));
          } else {
            final parts = [for (var k = 0; k < 16; k += 2) ((ip[k] << 8) | ip[k + 1]).toRadixString(16)];
            peers.add(('[${parts.join(':')}]', port));
          }
        }
        if (peers.isNotEmpty) ev.add(PeerAddresses(peers));
        return n;
      case msgBlockNotify:
        final n = _need(33);
        if (n == 0) return 0;
        final nid = body(1, 32);
        _rememberBroadcast(nid);
        ev.add(PeerBlockNotify(nid));
        return n;
      case msgAuxJobDonation || msgMoneroBlockBroadcast:
        // Not advertised (protocol 1.2), but tolerate and skip.
        return sized(poolBlockMaxTemplateSize);
      default:
        _fail(ev, 'unknown message id $id');
        return 1;
    }
  }

  void _rememberBroadcast(Uint8List id) {
    broadcastedHashes.add(toHex(id));
    if (broadcastedHashes.length > 8) broadcastedHashes.removeAt(0);
  }

  /// Records a block id this peer sent us (so we can answer with NOTIFY).
  void noteBroadcast(Uint8List templateId) => _rememberBroadcast(templateId);

  Uint8List _challengeHash(Uint8List challenge, int salt) {
    final s = Uint8List(8);
    writeU64LE(s, 0, salt);
    return Keccak.hash256(concatBytes([challenge, consensus.id, s]));
  }

  void _sendSolution(Uint8List challenge) {
    var salt = _rng.nextInt(1 << 32) << 32 | _rng.nextInt(1 << 32);
    final buf = Uint8List(48)..setRange(0, 8, challenge);
    buf.setRange(8, 40, consensus.id);
    while (true) {
      writeU64LE(buf, 40, salt);
      final h = Keccak.hash256(buf);
      if (mulhU64(readU64LE(h, 24), challengeDifficulty) == 0) {
        _send(msgHandshakeSolution, concatBytes([h, Uint8List.sublistView(buf, 40, 48)]));
        break;
      }
      salt++;
    }
    _sentSolution = true;
    if (handshakeComplete) _afterHandshake(null, 0);
  }

  void _afterHandshake(List<PeerEvent>? ev, int nowMs) {
    final port = Uint8List(4);
    writeU32LE(port, 0, listenPort == 0 ? consensus.defaultPort : listenPort);
    _send(msgListenPort, port);
    requestBlock(Uint8List(32)); // peer's tip
    requestPeerList();
    ev?.add(PeerHandshakeDone(peerId));
    _handshakeEventPending = ev == null;
  }

  bool _handshakeEventPending = false;

  /// Emits a pending handshake event (when the handshake finished while
  /// sending our solution).
  List<PeerEvent> drainHandshake() {
    if (!_handshakeEventPending) return const [];
    _handshakeEventPending = false;
    return [PeerHandshakeDone(peerId)];
  }
}

/// Encodes a varint-prefixed internal helper (kept for symmetry).
Uint8List encodeLenPrefixed(List<int> data) => concatBytes([encodeVarint(data.length), data]);
