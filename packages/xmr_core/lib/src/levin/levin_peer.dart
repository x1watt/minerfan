import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../monero/block.dart';
import '../util/bytes.dart';
import '../util/reader.dart';
import 'levin_frame.dart';
import 'messages.dart';

/// Sans-IO state machine for one OUTBOUND levin connection to a monerod peer.
///
/// The caller owns the socket: send [startHandshake]'s bytes after
/// connecting, pass every received chunk to [receive], call [tick]
/// periodically (every few seconds) and after each call flush
/// [takeOutgoing] to the socket. Once a [LevinClosed] event is returned the
/// socket must be closed and the object discarded.
///
/// The peer answers TIMED_SYNC, PING and REQUEST_SUPPORT_FLAGS invokes by
/// itself and sends its own TIMED_SYNC every [timedSyncIntervalMs] so both
/// sides keep learning each other's tip.

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class LevinEvent {
  const LevinEvent();
}

/// Handshake response accepted.
final class HandshakeDone extends LevinEvent {
  final BasicNodeData nodeData;
  final CoreSyncData coreSync;
  final List<PeerlistEntry> peers;
  const HandshakeDone(this.nodeData, this.coreSync, this.peers);
}

/// The peer's CORE_SYNC_DATA from a TIMED_SYNC (its request or its response
/// to ours). [peers] is only filled from responses.
final class CoreSyncUpdate extends LevinEvent {
  final CoreSyncData coreSync;
  final List<PeerlistEntry> peers;
  const CoreSyncUpdate(this.coreSync, [this.peers = const []]);
}

/// NOTIFY_RESPONSE_CHAIN_ENTRY.
final class ChainEntry extends LevinEvent {
  final ResponseChainEntry entry;
  const ChainEntry(this.entry);
}

/// One block of a RESPONSE_GET_OBJECTS or a new block notify, parsed when
/// possible. [block] is null (and [parseError] set) for blobs
/// [MoneroBlock.parse] does not understand, such as pre-RingCT blocks whose
/// miner transaction is version 1.
class ReceivedBlock {
  final BlockCompleteEntry entry;
  final MoneroBlock? block;
  final Object? parseError;
  const ReceivedBlock(this.entry, this.block, this.parseError);

  Uint8List get blob => entry.block;

  static ReceivedBlock parse(BlockCompleteEntry e) {
    try {
      return ReceivedBlock(e, MoneroBlock.parse(e.block), null);
    } on FormatError catch (err) {
      return ReceivedBlock(e, null, err);
    } on RangeError catch (err) {
      return ReceivedBlock(e, null, err);
    }
  }
}

/// NOTIFY_RESPONSE_GET_OBJECTS.
final class ObjectsResponse extends LevinEvent {
  final ResponseGetObjects response;
  final List<ReceivedBlock> blocks;
  const ObjectsResponse(this.response, this.blocks);
}

/// NOTIFY_NEW_FLUFFY_BLOCK ([fluffy] true) or legacy NOTIFY_NEW_BLOCK.
final class NewBlock extends LevinEvent {
  final bool fluffy;
  final ReceivedBlock block;
  final int currentBlockchainHeight;
  const NewBlock(this.fluffy, this.block, this.currentBlockchainHeight);
}

/// NOTIFY_NEW_TRANSACTIONS.
final class NewTransactions extends LevinEvent {
  final List<Uint8List> txs;
  final bool fluff;
  const NewTransactions(this.txs, this.fluff);
}

/// NOTIFY_REQUEST_FLUFFY_MISSING_TX: the peer wants transactions of a block we
/// broadcast. Answer with [LevinPeer.broadcastFluffyBlock] including them, or
/// ignore it.
final class FluffyMissingTx extends LevinEvent {
  final RequestFluffyMissingTx request;
  const FluffyMissingTx(this.request);
}

/// A notification this light peer does not act on (REQUEST_CHAIN,
/// REQUEST_GET_OBJECTS, GET_TXPOOL_COMPLEMENT, unknown commands). Receiving
/// REQUEST_CHAIN usually means the peer does not know the top id we
/// advertise and considers us a sync source; see [LevinPeer.setLocalSync].
final class UnhandledNotify extends LevinEvent {
  final int command;
  final Uint8List body;
  const UnhandledNotify(this.command, this.body);
}

/// A non-fatal problem, for logging.
final class LevinWarning extends LevinEvent {
  final String message;
  const LevinWarning(this.message);
}

/// The connection must be closed. No further events follow.
final class LevinClosed extends LevinEvent {
  final String reason;

  /// False for an orderly local close.
  final bool isError;
  const LevinClosed(this.reason, {this.isError = true});
}

// ---------------------------------------------------------------------------
// Peer
// ---------------------------------------------------------------------------

enum LevinPeerState { idle, handshaking, ready, closed }

class _PendingInvoke {
  final int command;
  final int sentAtMs;
  const _PendingInvoke(this.command, this.sentAtMs);
}

class LevinPeer {
  /// Our random peer id. monerod drops a handshake whose peer id equals its
  /// own ("connection to self").
  final int peerId;
  final Uint8List networkId;
  final int supportFlags;

  /// `P2P_DEFAULT_HANDSHAKE_INVOKE_TIMEOUT` is 5 s; we allow a bit more.
  final int handshakeTimeoutMs;

  /// `P2P_DEFAULT_INVOKE_TIMEOUT` (cryptonote_config.h:149), 2 minutes.
  final int invokeTimeoutMs;

  /// `P2P_DEFAULT_HANDSHAKE_INTERVAL` (cryptonote_config.h:142), 60 s.
  final int timedSyncIntervalMs;

  /// Close when nothing arrived for this long. monerod sends a TIMED_SYNC
  /// every 60 s, so a silent peer is gone.
  final int idleTimeoutMs;

  final LevinDeframer _deframer = LevinDeframer();
  final BytesBuilder _out = BytesBuilder(copy: false);
  final ListQueue<_PendingInvoke> _pending = ListQueue();

  LevinPeerState _state = LevinPeerState.idle;
  CoreSyncData _localSync;
  CoreSyncData? _remoteSync;
  BasicNodeData? _remoteNode;
  int _nowMs = 0;
  int _lastRecvMs = 0;
  int _lastTimedSyncMs = 0;

  LevinPeer({
    int? peerId,
    Uint8List? networkId,
    CoreSyncData? localSync,
    this.supportFlags = p2pSupportFlagFluffyBlocks,
    this.handshakeTimeoutMs = 10000,
    this.invokeTimeoutMs = 120000,
    this.timedSyncIntervalMs = 60000,
    this.idleTimeoutMs = 300000,
  }) : peerId = peerId ?? _randomPeerId(),
       networkId = networkId ?? mainnetNetworkId,
       _localSync = localSync ?? CoreSyncData.genesis();

  static int _randomPeerId() {
    final r = Random.secure();
    return (r.nextInt(1 << 32) << 32) | r.nextInt(1 << 32);
  }

  LevinPeerState get state => _state;
  bool get isReady => _state == LevinPeerState.ready;
  bool get isClosed => _state == LevinPeerState.closed;

  /// Latest CORE_SYNC_DATA the peer sent (handshake or timed sync).
  CoreSyncData? get remoteSync => _remoteSync;
  BasicNodeData? get remoteNode => _remoteNode;
  CoreSyncData get localSync => _localSync;

  /// Bytes queued for the socket; clears the queue.
  Uint8List takeOutgoing() => _out.takeBytes();
  bool get hasOutgoing => _out.isNotEmpty;

  /// Returns the COMMAND_HANDSHAKE invoke to write to the socket (it is not
  /// added to [takeOutgoing]). [nowMs] starts the handshake timeout.
  Uint8List startHandshake([int? nowMs]) {
    if (_state != LevinPeerState.idle) throw StateError('handshake already started');
    if (nowMs != null) _nowMs = nowMs;
    _lastRecvMs = _nowMs;
    _state = LevinPeerState.handshaking;
    final node = BasicNodeData(networkId: networkId, peerId: peerId, supportFlags: supportFlags);
    final pkt = encodeLevinInvoke(cmdHandshake, HandshakeRequest(node, _localSync).encode());
    _pending.add(_PendingInvoke(cmdHandshake, _nowMs));
    return pkt;
  }

  /// Changes what we advertise in TIMED_SYNC from now on. [height] is the
  /// chain height (top block height + 1) and [topVersion] must be the hard
  /// fork version of the block at `height - 1`.
  ///
  /// Only advertise a top block the peer already has: for an unknown top id
  /// monerod marks the connection as synchronizing, sends us REQUEST_CHAIN
  /// (which we cannot answer) and ignores our NEW_FLUFFY_BLOCK notifies until
  /// it gives up on us. Also never lower the advertised height; monerod
  /// penalizes that (`hit_score` in process_payload_sync_data).
  void setLocalSync(int height, BigInt cumulativeDifficulty, Uint8List topId, int topVersion) {
    if (topId.length != 32) throw ArgumentError('top id must be 32 bytes');
    _localSync = CoreSyncData(
      currentHeight: height,
      cumulativeDifficulty: cumulativeDifficulty,
      topId: topId,
      topVersion: topVersion,
    );
  }

  /// Feeds received bytes. [nowMs] updates the clock used for timeouts.
  List<LevinEvent> receive(Uint8List chunk, [int? nowMs]) {
    if (nowMs != null) _nowMs = nowMs;
    if (_state == LevinPeerState.closed) return const [];
    _lastRecvMs = _nowMs;
    final events = <LevinEvent>[];
    try {
      _deframer.add(chunk);
      for (var p = _deframer.next(); p != null; p = _deframer.next()) {
        _handle(p, events);
        if (_state == LevinPeerState.closed) break;
      }
    } on FormatError catch (e) {
      _close(events, 'protocol error: ${e.message}');
    } on ArgumentError catch (e) {
      _close(events, 'protocol error: ${e.message}');
    }
    return events;
  }

  /// Advances the clock: enforces timeouts and sends our periodic TIMED_SYNC.
  List<LevinEvent> tick(int nowMs) {
    _nowMs = nowMs;
    final events = <LevinEvent>[];
    if (_state == LevinPeerState.closed || _state == LevinPeerState.idle) return events;
    if (_pending.isNotEmpty) {
      final p = _pending.first;
      final limit = p.command == cmdHandshake ? handshakeTimeoutMs : invokeTimeoutMs;
      if (nowMs - p.sentAtMs > limit) {
        _close(events, 'invoke ${p.command} timed out');
        return events;
      }
    }
    if (nowMs - _lastRecvMs > idleTimeoutMs) {
      _close(events, 'idle timeout');
      return events;
    }
    if (_state == LevinPeerState.ready &&
        nowMs - _lastTimedSyncMs >= timedSyncIntervalMs &&
        !_pending.any((p) => p.command == cmdTimedSync)) {
      sendTimedSync();
    }
    return events;
  }

  /// Queues a TIMED_SYNC invoke carrying our current [localSync].
  void sendTimedSync() {
    _requireReady();
    _lastTimedSyncMs = _nowMs;
    _pending.add(_PendingInvoke(cmdTimedSync, _nowMs));
    _out.add(encodeLevinInvoke(cmdTimedSync, TimedSyncRequest(_localSync).encode()));
  }

  /// Queues NOTIFY_REQUEST_CHAIN. [sparseIds] is newest first and must end
  /// with the genesis id (see [sparseChainHistory]). The answer arrives as a
  /// [ChainEntry] event. [prune] true asks for the full id list even from a
  /// pruned peer.
  void requestChain(List<Uint8List> sparseIds, {bool prune = true}) {
    _requireReady();
    if (sparseIds.isEmpty) throw ArgumentError('sparse chain must not be empty');
    _out.add(encodeLevinNotify(cmdNotifyRequestChain, RequestChain(sparseIds, prune: prune).encode()));
  }

  /// Queues NOTIFY_REQUEST_GET_OBJECTS for up to [maxObjectRequestCount]
  /// block ids. The answer arrives as an [ObjectsResponse] event. With
  /// [prune] (default) transactions come pruned, which is all a light peer
  /// needs and works against pruned nodes too.
  void requestObjects(List<Uint8List> ids, {bool prune = true}) {
    _requireReady();
    if (ids.isEmpty) throw ArgumentError('no block ids');
    if (ids.length > maxObjectRequestCount) {
      throw ArgumentError('at most $maxObjectRequestCount ids per request (peer drops the connection)');
    }
    _out.add(encodeLevinNotify(cmdNotifyRequestGetObjects, RequestGetObjects(ids, prune: prune).encode()));
  }

  /// Queues NOTIFY_NEW_TRANSACTIONS (fluff: relayed at once, not through a
  /// Dandelion++ stem).
  void sendTransactions(List<Uint8List> txs) {
    _requireReady();
    _out.add(encodeLevinNotify(cmdNotifyNewTransactions, NotifyNewTransactions(txs).encode()));
  }

  /// Queues NOTIFY_NEW_FLUFFY_BLOCK. [txBlobs] are full (unpruned)
  /// transaction blobs to include; transactions the peer lacks and that are
  /// not included make it send a [FluffyMissingTx] request.
  /// [currentHeight] is our chain height including this block, i.e. block
  /// height + 1. The peer ignores the block unless it considers this
  /// connection synchronized (it has our advertised top id).
  void broadcastFluffyBlock(Uint8List blockBlob, List<Uint8List> txBlobs, int currentHeight) {
    _requireReady();
    final entry = BlockCompleteEntry(block: blockBlob, txs: [for (final t in txBlobs) TxBlobEntry(t)]);
    _out.add(encodeLevinNotify(cmdNotifyNewFluffyBlock, NewBlockNotify(entry, currentHeight).encode()));
  }

  /// Local close; returns the final event.
  LevinClosed close([String reason = 'closed locally']) {
    final ev = LevinClosed(reason, isError: false);
    _state = LevinPeerState.closed;
    _pending.clear();
    return ev;
  }

  void _requireReady() {
    if (_state != LevinPeerState.ready) throw StateError('levin peer not ready (${_state.name})');
  }

  void _close(List<LevinEvent> events, String reason) {
    if (_state == LevinPeerState.closed) return;
    _state = LevinPeerState.closed;
    _pending.clear();
    events.add(LevinClosed(reason));
  }

  void _handle(LevinPacket p, List<LevinEvent> events) {
    final h = p.header;
    if (h.protocolVersion == levinProtocolVersion1 && h.isResponse) {
      _handleResponse(p, events);
    } else if (h.expectResponse) {
      _handleInvoke(p, events);
    } else {
      _handleNotify(p, events);
    }
  }

  void _handleResponse(LevinPacket p, List<LevinEvent> events) {
    // levin_protocol_handler_async.h:298 validate_response_command: a response
    // must match the oldest outstanding invoke.
    if (_pending.isEmpty) {
      _close(events, 'unexpected response to command ${p.command}');
      return;
    }
    final inv = _pending.removeFirst();
    if (inv.command != p.command) {
      _close(events, 'response command ${p.command} while waiting for ${inv.command}');
      return;
    }
    final code = p.header.returnCode;
    switch (p.command) {
      case cmdHandshake:
        if (code <= 0) {
          _close(events, 'handshake rejected (return code $code)');
          return;
        }
        final rsp = HandshakeResponse.decode(p.body);
        if (!bytesEqual(rsp.nodeData.networkId, networkId)) {
          _close(events, 'wrong network id ${toHex(rsp.nodeData.networkId)}');
          return;
        }
        if (rsp.nodeData.peerId == peerId) {
          _close(events, 'connection to self');
          return;
        }
        _remoteNode = rsp.nodeData;
        _remoteSync = rsp.payload;
        _state = LevinPeerState.ready;
        // 256 KiB until the handshake completes, then the default limit
        // (levin_protocol_handler_async.h). Packets still buffered are
        // checked against the new limit as they are pulled.
        _deframer.maxPacketSize = levinDefaultMaxPacketSize;
        _lastTimedSyncMs = _nowMs;
        events.add(HandshakeDone(rsp.nodeData, rsp.payload, rsp.peers));
      case cmdTimedSync:
        if (code <= 0) {
          events.add(LevinWarning('timed sync failed (return code $code)'));
          return;
        }
        final rsp = TimedSyncResponse.decode(p.body);
        _remoteSync = rsp.payload;
        events.add(CoreSyncUpdate(rsp.payload, rsp.peers));
      default:
        events.add(LevinWarning('ignored response to command ${p.command}'));
    }
  }

  void _handleInvoke(LevinPacket p, List<LevinEvent> events) {
    switch (p.command) {
      case cmdTimedSync:
        final req = TimedSyncRequest.decode(p.body);
        _remoteSync = req.payload;
        events.add(CoreSyncUpdate(req.payload));
        // Handlers return 1 on success; the invoker treats <= 0 as failure.
        _respond(p.command, TimedSyncResponse(_localSync).encode(), 1);
      case cmdPing:
        _respond(p.command, PingResponse(peerId).encode(), 1);
      case cmdRequestSupportFlags:
        _respond(p.command, SupportFlagsResponse(supportFlags).encode(), 1);
      case cmdHandshake:
        // net_node.inl handle_handshake: a handshake on an outgoing
        // connection is a protocol violation.
        _close(events, 'peer sent a handshake on our outgoing connection');
      default:
        // END_INVOKE_MAP2: unknown invoke gets an empty body and
        // LEVIN_ERROR_CONNECTION_HANDLER_NOT_DEFINED.
        _respond(p.command, Uint8List(0), levinErrorConnectionHandlerNotDefined);
        events.add(LevinWarning('unknown invoke ${p.command}'));
    }
  }

  void _respond(int command, Uint8List body, int code) {
    _out.add(encodeLevinResponse(command, body, code));
  }

  void _handleNotify(LevinPacket p, List<LevinEvent> events) {
    if (_state != LevinPeerState.ready) {
      events.add(LevinWarning('notify ${p.command} before handshake ignored'));
      return;
    }
    switch (p.command) {
      case cmdNotifyNewFluffyBlock:
      case cmdNotifyNewBlock:
        final n = NewBlockNotify.decode(p.body);
        events.add(NewBlock(p.command == cmdNotifyNewFluffyBlock, ReceivedBlock.parse(n.b), n.currentBlockchainHeight));
      case cmdNotifyNewTransactions:
        final n = NotifyNewTransactions.decode(p.body);
        events.add(NewTransactions(n.txs, n.dandelionppFluff));
      case cmdNotifyResponseGetObjects:
        final r = ResponseGetObjects.decode(p.body);
        events.add(ObjectsResponse(r, [for (final b in r.blocks) ReceivedBlock.parse(b)]));
      case cmdNotifyResponseChainEntry:
        final r = ResponseChainEntry.decode(p.body);
        if (r.blockIds.isNotEmpty && r.startHeight + r.blockIds.length - 1 > r.totalHeight) {
          // cryptonote_protocol_handler.inl:2568, the same check monerod does.
          _close(events, 'chain entry beyond total height');
          return;
        }
        events.add(ChainEntry(r));
      case cmdNotifyRequestFluffyMissingTx:
        events.add(FluffyMissingTx(RequestFluffyMissingTx.decode(p.body)));
      default:
        events.add(UnhandledNotify(p.command, p.body));
    }
  }
}
