import 'dart:typed_data';

import '../util/bytes.dart';
import '../util/reader.dart';
import 'portable_storage.dart';

/// Typed P2P (src/p2p/p2p_protocol_defs.h) and cryptonote protocol
/// (src/cryptonote_protocol/cryptonote_protocol_defs.h) messages.
///
/// Every message maps to one portable storage section. Encoding follows the
/// `KV_SERIALIZE*` rules monerod uses when storing:
///  - `KV_SERIALIZE_OPT(x, d)` fields are omitted when equal to `d`;
///  - empty containers (arrays and POD blobs) are omitted entirely;
///  - keys are written in `std::map` order, so bodies are byte-identical to
///    what monerod would produce for the same values.
/// Decoding is lenient like epee: missing fields take their defaults and any
/// integer wire width is accepted for integer fields.

// P2P commands (p2p_protocol_defs.h, P2P_COMMANDS_POOL_BASE = 1000).
const int cmdHandshake = 1001;
const int cmdTimedSync = 1002;
const int cmdPing = 1003;
const int cmdRequestSupportFlags = 1007;

// Cryptonote protocol commands (cryptonote_protocol_defs.h, BC_COMMANDS_POOL_BASE = 2000).
const int cmdNotifyNewBlock = 2001;
const int cmdNotifyNewTransactions = 2002;
const int cmdNotifyRequestGetObjects = 2003;
const int cmdNotifyResponseGetObjects = 2004;
const int cmdNotifyRequestChain = 2006;
const int cmdNotifyResponseChainEntry = 2007;
const int cmdNotifyNewFluffyBlock = 2008;
const int cmdNotifyRequestFluffyMissingTx = 2009;
const int cmdNotifyGetTxpoolComplement = 2010;

/// `P2P_SUPPORT_FLAG_FLUFFY_BLOCKS` (cryptonote_config.h:162).
const int p2pSupportFlagFluffyBlocks = 0x01;

/// `PING_OK_RESPONSE_STATUS_TEXT` (p2p_protocol_defs.h).
const String pingOkStatus = 'OK';

/// `CURRENCY_PROTOCOL_MAX_OBJECT_REQUEST_COUNT`
/// (cryptonote_protocol_handler.h:58). Larger REQUEST_GET_OBJECTS get the
/// connection dropped.
const int maxObjectRequestCount = 100;

/// `BLOCKS_IDS_SYNCHRONIZING_DEFAULT_COUNT` (cryptonote_config.h:95): the most
/// ids a RESPONSE_CHAIN_ENTRY carries.
const int blockIdsSynchronizingDefaultCount = 10000;

/// `P2P_DEFAULT_PORT` for mainnet (cryptonote_config.h:232).
const int mainnetP2pPort = 18080;

/// Mainnet `config::NETWORK_ID` (cryptonote_config.h:235).
final Uint8List mainnetNetworkId = fromHex('1230f171610441611731008216a1a110');

/// Mainnet genesis block id.
final Uint8List mainnetGenesisId = fromHex('418015bb9ae982a1975da7d79277c2705727a56894ba0fb246adaabb1f4632e3');

final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

BigInt _u64Big(int v) => BigInt.from(v).toUnsigned(64);

BigInt _wide(int low, int top) => (_u64Big(top) << 64) | _u64Big(low);

int _low64(BigInt v) => (v & _mask64).toSigned(64).toInt();

int _top64(BigInt v) => ((v >> 64) & _mask64).toSigned(64).toInt();

Uint8List _encode(Map<String, Object?> s) => encodePortableStorage(s, sortKeys: true);

Map<String, Object?> _req(Map<String, Object?> s, String key) =>
    psSection(s, key) ?? (throw FormatError('missing section $key'));

// ---------------------------------------------------------------------------
// P2P layer
// ---------------------------------------------------------------------------

/// `basic_node_data` (p2p_protocol_defs.h).
class BasicNodeData {
  final Uint8List networkId;
  final int peerId;

  /// Our listening port. 0 means "do not dial me back" (no ping-back, not
  /// added to the peer's white list).
  final int myPort;
  final int rpcPort;
  final int rpcCreditsPerHash;
  final int supportFlags;

  BasicNodeData({
    required this.networkId,
    required this.peerId,
    this.myPort = 0,
    this.rpcPort = 0,
    this.rpcCreditsPerHash = 0,
    this.supportFlags = p2pSupportFlagFluffyBlocks,
  });

  Map<String, Object?> toSection() => {
    'network_id': PsString(networkId),
    'peer_id': PsU64(peerId),
    'my_port': PsU32(myPort),
    if (rpcPort != 0) 'rpc_port': PsU16(rpcPort),
    if (rpcCreditsPerHash != 0) 'rpc_credits_per_hash': PsU32(rpcCreditsPerHash),
    if (supportFlags != 0) 'support_flags': PsU32(supportFlags),
  };

  static BasicNodeData fromSection(Map<String, Object?> s) => BasicNodeData(
    // KV_SERIALIZE_VAL_POD_AS_BLOB(network_id): a 16-byte uuid.
    networkId: psPodBlob(s, 'network_id', 16) ?? Uint8List(16),
    peerId: psInt(s, 'peer_id') ?? 0,
    myPort: psInt(s, 'my_port') ?? 0,
    rpcPort: psInt(s, 'rpc_port') ?? 0,
    rpcCreditsPerHash: psInt(s, 'rpc_credits_per_hash') ?? 0,
    supportFlags: psInt(s, 'support_flags') ?? 0,
  );
}

/// `CORE_SYNC_DATA` (cryptonote_protocol_defs.h), the payload of handshake and
/// timed sync.
///
/// [currentHeight] is the chain height, i.e. the height of [topId] plus one
/// (`get_payload_sync_data` adds 1, cryptonote_protocol_handler.inl).
/// [topVersion] must equal the ideal hard fork version at
/// `currentHeight - 1`, or peers drop the connection once that version is at
/// least 6 (`process_payload_sync_data`).
class CoreSyncData {
  final int currentHeight;
  final BigInt cumulativeDifficulty;
  final Uint8List topId;
  final int topVersion;
  final int pruningSeed;

  CoreSyncData({
    required this.currentHeight,
    required this.cumulativeDifficulty,
    required this.topId,
    required this.topVersion,
    this.pruningSeed = 0,
  });

  /// What a node that only has the genesis block advertises. Every mainnet
  /// node has this block, so peers consider the connection synchronized.
  factory CoreSyncData.genesis() =>
      CoreSyncData(currentHeight: 1, cumulativeDifficulty: BigInt.one, topId: mainnetGenesisId, topVersion: 1);

  Map<String, Object?> toSection() => {
    'current_height': PsU64(currentHeight),
    'cumulative_difficulty': PsU64(_low64(cumulativeDifficulty)),
    // Always stored (the store branch uses plain KV_SERIALIZE).
    'cumulative_difficulty_top64': PsU64(_top64(cumulativeDifficulty)),
    'top_id': PsString(topId),
    if (topVersion != 0) 'top_version': PsU8(topVersion),
    if (pruningSeed != 0) 'pruning_seed': PsU32(pruningSeed),
  };

  static CoreSyncData fromSection(Map<String, Object?> s) => CoreSyncData(
    currentHeight: psInt(s, 'current_height') ?? 0,
    cumulativeDifficulty: _wide(psInt(s, 'cumulative_difficulty') ?? 0, psInt(s, 'cumulative_difficulty_top64') ?? 0),
    topId: psPodBlob(s, 'top_id', 32) ?? Uint8List(32),
    topVersion: psInt(s, 'top_version') ?? 0,
    pruningSeed: psInt(s, 'pruning_seed') ?? 0,
  );

  @override
  String toString() =>
      'CoreSyncData(height=$currentHeight, top=${toHex(topId)}, cumdiff=$cumulativeDifficulty, v=$topVersion, pruning=$pruningSeed)';
}

/// `epee::net_utils::address_type` (contrib/epee/include/net/enums.h).
const int addressTypeIpv4 = 1;
const int addressTypeIpv6 = 2;
const int addressTypeI2p = 3;
const int addressTypeTor = 4;

/// One `peerlist_entry`. Only IPv4 and IPv6 addresses are decoded; other
/// address types (Tor, I2P) are skipped by [parsePeerlist].
class PeerlistEntry {
  final int addressType;

  /// 4 bytes for IPv4 (network order), 16 for IPv6.
  final Uint8List ip;
  final int port;
  final int id;
  final int lastSeen;
  final int pruningSeed;
  final int rpcPort;
  final int rpcCreditsPerHash;

  PeerlistEntry({
    required this.ip,
    required this.port,
    this.id = 0,
    this.lastSeen = 0,
    this.pruningSeed = 0,
    this.rpcPort = 0,
    this.rpcCreditsPerHash = 0,
  }) : addressType = ip.length == 4 ? addressTypeIpv4 : addressTypeIpv6;

  bool get isIpv6 => addressType == addressTypeIpv6;

  /// Dotted quad for IPv4, uncompressed colon hex for IPv6.
  String get host {
    if (!isIpv6) return ip.join('.');
    final parts = <String>[];
    for (var i = 0; i < 16; i += 2) {
      parts.add(((ip[i] << 8) | ip[i + 1]).toRadixString(16));
    }
    return parts.join(':');
  }

  @override
  String toString() => isIpv6 ? '[$host]:$port' : '$host:$port';

  Map<String, Object?> toSection() {
    final Map<String, Object?> addr;
    if (isIpv6) {
      addr = {'addr': PsString(ip), 'm_port': PsU16(port)};
    } else {
      // ipv4_network_address stores m_ip in network byte order in memory and
      // serializes it as a little-endian u32 (net_utils_base.h:100), so the
      // first octet is the low byte.
      addr = {'m_ip': PsU32(readU32LE(ip, 0)), 'm_port': PsU16(port)};
    }
    return {
      'adr': {'addr': addr, 'type': PsU8(addressType)},
      'id': PsU64(id),
      if (lastSeen != 0) 'last_seen': PsI64(lastSeen),
      if (pruningSeed != 0) 'pruning_seed': PsU32(pruningSeed),
      if (rpcPort != 0) 'rpc_port': PsU16(rpcPort),
      if (rpcCreditsPerHash != 0) 'rpc_credits_per_hash': PsU32(rpcCreditsPerHash),
    };
  }

  /// Returns null for address types other than IPv4/IPv6.
  static PeerlistEntry? fromSection(Map<String, Object?> s) {
    final adr = psSection(s, 'adr');
    if (adr == null) return null;
    final type = psInt(adr, 'type');
    final addr = psSection(adr, 'addr');
    if (addr == null) return null;
    final Uint8List ip;
    if (type == addressTypeIpv4) {
      final m = psInt(addr, 'm_ip');
      if (m == null) return null;
      ip = Uint8List(4);
      writeU32LE(ip, 0, m);
    } else if (type == addressTypeIpv6) {
      final a = psBytes(addr, 'addr');
      if (a == null || a.length != 16) return null;
      ip = a;
    } else {
      return null;
    }
    return PeerlistEntry(
      ip: ip,
      port: (psInt(addr, 'm_port') ?? 0) & 0xffff,
      id: psInt(s, 'id') ?? 0,
      lastSeen: psInt(s, 'last_seen') ?? 0,
      pruningSeed: psInt(s, 'pruning_seed') ?? 0,
      rpcPort: psInt(s, 'rpc_port') ?? 0,
      rpcCreditsPerHash: psInt(s, 'rpc_credits_per_hash') ?? 0,
    );
  }
}

/// Decodes `local_peerlist_new`, skipping unsupported address types.
List<PeerlistEntry> parsePeerlist(Map<String, Object?> s) => [
  for (final e in psSectionList(s, 'local_peerlist_new')) ?PeerlistEntry.fromSection(e),
];

PsArray? _peerlistArray(List<PeerlistEntry> peers) =>
    peers.isEmpty ? null : PsArray(psTypeObject, [for (final p in peers) p.toSection()]);

/// COMMAND_HANDSHAKE request.
class HandshakeRequest {
  final BasicNodeData nodeData;
  final CoreSyncData payload;
  HandshakeRequest(this.nodeData, this.payload);

  Map<String, Object?> toSection() => {'node_data': nodeData.toSection(), 'payload_data': payload.toSection()};
  Uint8List encode() => _encode(toSection());

  static HandshakeRequest fromSection(Map<String, Object?> s) => HandshakeRequest(
    BasicNodeData.fromSection(_req(s, 'node_data')),
    CoreSyncData.fromSection(_req(s, 'payload_data')),
  );
  static HandshakeRequest decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// COMMAND_HANDSHAKE response.
class HandshakeResponse {
  final BasicNodeData nodeData;
  final CoreSyncData payload;
  final List<PeerlistEntry> peers;
  HandshakeResponse(this.nodeData, this.payload, [this.peers = const []]);

  Map<String, Object?> toSection() => {
    'local_peerlist_new': _peerlistArray(peers),
    'node_data': nodeData.toSection(),
    'payload_data': payload.toSection(),
  };
  Uint8List encode() => _encode(toSection());

  static HandshakeResponse fromSection(Map<String, Object?> s) => HandshakeResponse(
    BasicNodeData.fromSection(_req(s, 'node_data')),
    CoreSyncData.fromSection(_req(s, 'payload_data')),
    parsePeerlist(s),
  );
  static HandshakeResponse decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// COMMAND_TIMED_SYNC request.
class TimedSyncRequest {
  final CoreSyncData payload;
  TimedSyncRequest(this.payload);

  Map<String, Object?> toSection() => {'payload_data': payload.toSection()};
  Uint8List encode() => _encode(toSection());

  static TimedSyncRequest fromSection(Map<String, Object?> s) =>
      TimedSyncRequest(CoreSyncData.fromSection(_req(s, 'payload_data')));
  static TimedSyncRequest decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// COMMAND_TIMED_SYNC response.
class TimedSyncResponse {
  final CoreSyncData payload;
  final List<PeerlistEntry> peers;
  TimedSyncResponse(this.payload, [this.peers = const []]);

  Map<String, Object?> toSection() => {
    'local_peerlist_new': _peerlistArray(peers),
    'payload_data': payload.toSection(),
  };
  Uint8List encode() => _encode(toSection());

  static TimedSyncResponse fromSection(Map<String, Object?> s) =>
      TimedSyncResponse(CoreSyncData.fromSection(_req(s, 'payload_data')), parsePeerlist(s));
  static TimedSyncResponse decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// COMMAND_PING response (the request is an empty section).
class PingResponse {
  final String status;
  final int peerId;
  PingResponse(this.peerId, [this.status = pingOkStatus]);

  Map<String, Object?> toSection() => {'peer_id': PsU64(peerId), 'status': PsString.utf8(status)};
  Uint8List encode() => _encode(toSection());

  static PingResponse fromSection(Map<String, Object?> s) {
    final st = s['status'];
    return PingResponse(psInt(s, 'peer_id') ?? 0, st is PsString ? st.text : '');
  }

  static PingResponse decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// COMMAND_REQUEST_SUPPORT_FLAGS response (the request is an empty section).
class SupportFlagsResponse {
  final int supportFlags;
  SupportFlagsResponse(this.supportFlags);

  Map<String, Object?> toSection() => {'support_flags': PsU32(supportFlags)};
  Uint8List encode() => _encode(toSection());

  static SupportFlagsResponse fromSection(Map<String, Object?> s) =>
      SupportFlagsResponse(psInt(s, 'support_flags') ?? 0);
  static SupportFlagsResponse decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// Body of requests without fields (PING, REQUEST_SUPPORT_FLAGS).
Uint8List encodeEmptySection() => _encode(const {});

// ---------------------------------------------------------------------------
// Cryptonote protocol
// ---------------------------------------------------------------------------

/// `NOTIFY_REQUEST_CHAIN`. [blockIds] is a sparse chain, newest first: the
/// first ten ids are consecutive, then offsets grow as powers of two, and
/// the LAST id must be the genesis block or the peer answers nothing
/// (`Blockchain::find_blockchain_supplement`, blockchain.cpp:2421).
class RequestChain {
  final List<Uint8List> blockIds;

  /// True returns the full id list even from a pruned peer; false makes a
  /// pruned peer clip the list to its unpruned stripe (`clip_pruned = !prune`).
  final bool prune;
  RequestChain(this.blockIds, {this.prune = false});

  Map<String, Object?> toSection() => {
    if (blockIds.isNotEmpty) 'block_ids': PsString(packHashes(blockIds)),
    if (prune) 'prune': const PsBool(true),
  };
  Uint8List encode() => _encode(toSection());

  static RequestChain fromSection(Map<String, Object?> s) =>
      RequestChain(psHashList(s, 'block_ids'), prune: psBool(s, 'prune') ?? false);
  static RequestChain decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `NOTIFY_RESPONSE_CHAIN_ENTRY`. [blockIds] starts at [startHeight], which is
/// the height of the newest id of the request that the peer knows.
/// [totalHeight] is the peer's chain height and [cumulativeDifficulty] that of
/// its top block. [firstBlock] is the blob of `blockIds[1]` when at least two
/// ids are returned.
class ResponseChainEntry {
  final int startHeight;
  final int totalHeight;
  final BigInt cumulativeDifficulty;
  final List<Uint8List> blockIds;
  final List<int> blockWeights;
  final Uint8List? firstBlock;

  ResponseChainEntry({
    required this.startHeight,
    required this.totalHeight,
    required this.cumulativeDifficulty,
    required this.blockIds,
    this.blockWeights = const [],
    this.firstBlock,
  });

  Map<String, Object?> toSection() => {
    'cumulative_difficulty': PsU64(_low64(cumulativeDifficulty)),
    'cumulative_difficulty_top64': PsU64(_top64(cumulativeDifficulty)),
    // A plain std::string: always stored, empty when absent.
    'first_block': PsString(firstBlock ?? Uint8List(0)),
    if (blockIds.isNotEmpty) 'm_block_ids': PsString(packHashes(blockIds)),
    if (blockWeights.isNotEmpty) 'm_block_weights': PsString(packU64s(blockWeights)),
    'start_height': PsU64(startHeight),
    'total_height': PsU64(totalHeight),
  };
  Uint8List encode() => _encode(toSection());

  static ResponseChainEntry fromSection(Map<String, Object?> s) {
    final fb = psBytes(s, 'first_block');
    return ResponseChainEntry(
      startHeight: psInt(s, 'start_height') ?? 0,
      totalHeight: psInt(s, 'total_height') ?? 0,
      cumulativeDifficulty: _wide(psInt(s, 'cumulative_difficulty') ?? 0, psInt(s, 'cumulative_difficulty_top64') ?? 0),
      blockIds: psHashList(s, 'm_block_ids'),
      blockWeights: psU64List(s, 'm_block_weights'),
      firstBlock: (fb == null || fb.isEmpty) ? null : fb,
    );
  }

  static ResponseChainEntry decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `NOTIFY_REQUEST_GET_OBJECTS`: at most [maxObjectRequestCount] block ids.
class RequestGetObjects {
  final List<Uint8List> blocks;

  /// Ask for pruned transactions (`tx_blob_entry` with prunable hash). Also
  /// makes the peer fill `block_weight`.
  final bool prune;
  RequestGetObjects(this.blocks, {this.prune = false});

  Map<String, Object?> toSection() => {
    if (blocks.isNotEmpty) 'blocks': PsString(packHashes(blocks)),
    if (prune) 'prune': const PsBool(true),
  };
  Uint8List encode() => _encode(toSection());

  static RequestGetObjects fromSection(Map<String, Object?> s) =>
      RequestGetObjects(psHashList(s, 'blocks'), prune: psBool(s, 'prune') ?? false);
  static RequestGetObjects decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `tx_blob_entry`. [prunableHash] is set for pruned entries.
class TxBlobEntry {
  final Uint8List blob;
  final Uint8List? prunableHash;
  TxBlobEntry(this.blob, [this.prunableHash]);

  Map<String, Object?> toSection() => {
    'blob': PsString(blob),
    'prunable_hash': PsString(prunableHash ?? Uint8List(32)),
  };

  static TxBlobEntry fromSection(Map<String, Object?> s) =>
      TxBlobEntry(psBytes(s, 'blob') ?? Uint8List(0), psPodBlob(s, 'prunable_hash', 32));
}

/// `block_complete_entry`. When [pruned] is false the transactions travel as
/// an array of plain blobs, otherwise as an array of `tx_blob_entry` sections.
class BlockCompleteEntry {
  final bool pruned;
  final Uint8List block;
  final int blockWeight;
  final List<TxBlobEntry> txs;

  BlockCompleteEntry({required this.block, this.pruned = false, this.blockWeight = 0, this.txs = const []});

  Map<String, Object?> toSection() => {
    'block': PsString(block),
    if (blockWeight != 0) 'block_weight': PsU64(blockWeight),
    if (pruned) 'pruned': const PsBool(true),
    if (txs.isNotEmpty)
      'txs': pruned
          ? PsArray(psTypeObject, [for (final t in txs) t.toSection()])
          : PsArray(psTypeString, [for (final t in txs) PsString(t.blob)]),
  };

  static BlockCompleteEntry fromSection(Map<String, Object?> s) {
    final pruned = psBool(s, 'pruned') ?? false;
    final raw = s['txs'];
    final txs = <TxBlobEntry>[];
    if (raw is PsArray && raw.elementType == psTypeObject) {
      for (final t in raw.items) {
        txs.add(TxBlobEntry.fromSection(t as Map<String, Object?>));
      }
    } else if (raw is PsArray && raw.elementType == psTypeString) {
      for (final t in raw.items) {
        txs.add(TxBlobEntry((t as PsString).bytes));
      }
    } else if (raw != null) {
      throw FormatError('block_complete_entry.txs has unexpected type');
    }
    return BlockCompleteEntry(
      block: psBytes(s, 'block') ?? Uint8List(0),
      pruned: pruned,
      blockWeight: psInt(s, 'block_weight') ?? 0,
      txs: txs,
    );
  }
}

/// `NOTIFY_RESPONSE_GET_OBJECTS`.
class ResponseGetObjects {
  final List<BlockCompleteEntry> blocks;
  final List<Uint8List> missedIds;
  final int currentBlockchainHeight;

  ResponseGetObjects({required this.blocks, this.missedIds = const [], required this.currentBlockchainHeight});

  Map<String, Object?> toSection() => {
    if (blocks.isNotEmpty) 'blocks': PsArray(psTypeObject, [for (final b in blocks) b.toSection()]),
    'current_blockchain_height': PsU64(currentBlockchainHeight),
    if (missedIds.isNotEmpty) 'missed_ids': PsString(packHashes(missedIds)),
  };
  Uint8List encode() => _encode(toSection());

  static ResponseGetObjects fromSection(Map<String, Object?> s) => ResponseGetObjects(
    blocks: [for (final b in psSectionList(s, 'blocks')) BlockCompleteEntry.fromSection(b)],
    missedIds: psHashList(s, 'missed_ids'),
    currentBlockchainHeight: psInt(s, 'current_blockchain_height') ?? 0,
  );
  static ResponseGetObjects decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `NOTIFY_NEW_BLOCK` and `NOTIFY_NEW_FLUFFY_BLOCK` (same layout).
/// [currentBlockchainHeight] is the sender's chain height including this
/// block (block height + 1 for a new tip).
class NewBlockNotify {
  final BlockCompleteEntry b;
  final int currentBlockchainHeight;
  NewBlockNotify(this.b, this.currentBlockchainHeight);

  Map<String, Object?> toSection() => {'b': b.toSection(), 'current_blockchain_height': PsU64(currentBlockchainHeight)};
  Uint8List encode() => _encode(toSection());

  static NewBlockNotify fromSection(Map<String, Object?> s) =>
      NewBlockNotify(BlockCompleteEntry.fromSection(_req(s, 'b')), psInt(s, 'current_blockchain_height') ?? 0);
  static NewBlockNotify decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `NOTIFY_NEW_TRANSACTIONS`. [padding] is the `_` field monerod fills with
/// random bytes to hide the message size; it is always written, even empty.
class NotifyNewTransactions {
  final List<Uint8List> txs;
  final Uint8List padding;

  /// False means Dandelion++ stem. Default true (backwards compatible fluff).
  final bool dandelionppFluff;

  NotifyNewTransactions(this.txs, {Uint8List? padding, this.dandelionppFluff = true})
    : padding = padding ?? Uint8List(0);

  Map<String, Object?> toSection() => {
    '_': PsString(padding),
    if (!dandelionppFluff) 'dandelionpp_fluff': const PsBool(false),
    if (txs.isNotEmpty) 'txs': PsArray(psTypeString, [for (final t in txs) PsString(t)]),
  };
  Uint8List encode() => _encode(toSection());

  static NotifyNewTransactions fromSection(Map<String, Object?> s) => NotifyNewTransactions(
    psBytesList(s, 'txs'),
    padding: psBytes(s, '_'),
    dandelionppFluff: psBool(s, 'dandelionpp_fluff') ?? true,
  );
  static NotifyNewTransactions decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// `NOTIFY_REQUEST_FLUFFY_MISSING_TX`: the peer lacks these transactions (by
/// index into the block's tx hash list) of a fluffy block we sent; monerod
/// answers with a `NOTIFY_NEW_FLUFFY_BLOCK` that carries them.
class RequestFluffyMissingTx {
  final Uint8List blockHash;
  final int currentBlockchainHeight;
  final List<int> missingTxIndices;

  RequestFluffyMissingTx(this.blockHash, this.currentBlockchainHeight, this.missingTxIndices);

  Map<String, Object?> toSection() => {
    'block_hash': PsString(blockHash),
    'current_blockchain_height': PsU64(currentBlockchainHeight),
    if (missingTxIndices.isNotEmpty) 'missing_tx_indices': PsString(packU64s(missingTxIndices)),
  };
  Uint8List encode() => _encode(toSection());

  static RequestFluffyMissingTx fromSection(Map<String, Object?> s) => RequestFluffyMissingTx(
    psPodBlob(s, 'block_hash', 32) ?? Uint8List(32),
    psInt(s, 'current_blockchain_height') ?? 0,
    psU64List(s, 'missing_tx_indices'),
  );
  static RequestFluffyMissingTx decode(Uint8List body) => fromSection(decodePortableStorage(body));
}

/// Builds the sparse chain list monerod sends in REQUEST_CHAIN
/// (`Blockchain::get_short_chain_history`): the ten newest ids, then ids at
/// power-of-two distances, then genesis. [idAtHeight] returns the id of the
/// block at a height in `[0, topHeight]`.
List<Uint8List> sparseChainHistory(int topHeight, Uint8List Function(int height) idAtHeight) {
  final out = <Uint8List>[];
  if (topHeight < 0) return out;
  var i = 0;
  var mul = 1;
  var current = topHeight;
  while (current > 0) {
    out.add(idAtHeight(current));
    if (i < 10) {
      current -= 1;
    } else {
      mul *= 2;
      current -= mul;
    }
    i++;
  }
  out.add(idAtHeight(0));
  return out;
}
