import 'dart:typed_data';

import '../levin/messages.dart' show CoreSyncData, ResponseChainEntry, mainnetGenesisId;
import '../p2pool/sidechain.dart' show MainChainBlock, MainChainView;
import '../p2pool/template.dart' show MinerData;
import '../util/bytes.dart';
import 'block.dart';
import 'checkpoint.g.dart';
import 'difficulty.dart';
import 'hardforks.dart';

/// A header-following Monero light chain.
///
/// It starts from a built-in checkpoint (735 headers with cumulative
/// difficulties), accepts blocks only in parent order, computes every later
/// difficulty with Monero's own algorithm and keeps a bounded window of
/// headers. Trust comes from three independent checks the node performs:
/// RandomX PoW of recent and seed blocks ([pendingPow]), agreement of our
/// computed cumulative difficulty with several peers ([crossCheck]), and the
/// checkpoint itself.
class LightHeader {
  final int height;
  final Uint8List id;
  final int timestamp;
  final BigInt cumulativeDifficulty;
  final BigInt difficulty;
  final int majorVersion;
  bool powVerified;

  LightHeader(this.height, this.id, this.timestamp, this.cumulativeDifficulty, this.difficulty, this.majorVersion,
      {this.powVerified = false});
}

/// A block whose PoW the node must check: RandomX(seed, blob) >= difficulty.
class PowCheck {
  final int height;
  final Uint8List id;
  final Uint8List hashingBlob;
  final Uint8List seedId;
  final BigInt difficulty;
  const PowCheck(this.height, this.id, this.hashingBlob, this.seedId, this.difficulty);
}

class LightChainError implements Exception {
  final String message;
  LightChainError(this.message);
  @override
  String toString() => message;
}

class MoneroLightChain implements MainChainView {
  /// Headers kept below the tip: enough for difficulty (735) and for the
  /// RandomX seeds and difficulties of every share in any PPLNS window.
  static const int keep = 4500;

  /// New blocks within this distance of the peer-advertised tip get their
  /// PoW checked.
  static const int powCheckDepth = 30;

  final Map<int, LightHeader> _byHeight = {};
  final Map<String, int> _heightById = {};
  int _tip = -1;
  int _bottom = 0;

  /// Blocks to fetch, in height order (from chain entries).
  final List<(int, Uint8List)> _toFetch = [];

  /// Highest height a peer advertised.
  int bestKnownHeight = 0;

  final List<PowCheck> _pow = [];

  /// Peers whose CORE_SYNC_DATA matched our computed cumulative difficulty
  /// at the same top id.
  final Set<int> agreeingPeers = {};

  MoneroLightChain.fromCheckpoint() {
    final start = checkpointEndHeight - checkpointHeaders.length + 1;
    BigInt? prevCd;
    for (var i = 0; i < checkpointHeaders.length; i++) {
      final (idHex, ts, cdStr) = checkpointHeaders[i];
      final cd = BigInt.parse(cdStr);
      final h = start + i;
      final diff = prevCd == null ? BigInt.zero : cd - prevCd;
      _put(LightHeader(h, fromHex(idHex), ts, cd, diff, majorVersionAt(h), powVerified: true));
      prevCd = cd;
    }
    _bottom = start;
  }

  /// Restores a saved window (see [export]).
  MoneroLightChain.restore(List<LightHeader> headers) {
    for (final h in headers) {
      _put(h);
    }
    _bottom = headers.first.height;
  }

  List<LightHeader> export() => [for (var h = _bottom; h <= _tip; h++) _byHeight[h]!];

  void _put(LightHeader h) {
    _byHeight[h.height] = h;
    _heightById[toHex(h.id)] = h.height;
    if (h.height > _tip) _tip = h.height;
  }

  int get tipHeight => _tip;
  LightHeader get tipHeader => _byHeight[_tip]!;
  bool get isSynced => _tip >= bestKnownHeight - 1 && _toFetch.isEmpty && bestKnownHeight > 0;
  int get pendingFetches => _toFetch.length;

  LightHeader? header(int height) => _byHeight[height];

  Uint8List? idAt(int height) => _byHeight[height]?.id;

  // ---- MainChainView -----------------------------------------------------

  @override
  BigInt? difficultyAt(int height) {
    final h = _byHeight[height];
    if (h == null || h.difficulty == BigInt.zero) return null;
    return h.difficulty;
  }

  @override
  MainChainBlock? byId(Uint8List id) {
    final h = _heightById[toHex(id)];
    if (h == null) return null;
    final hd = _byHeight[h]!;
    return MainChainBlock(hd.height, hd.timestamp, hd.id);
  }

  @override
  MainChainBlock? get tip => _tip < 0 ? null : MainChainBlock(_tip, tipHeader.timestamp, tipHeader.id);

  /// RandomX seed (block id) for a block at [height], if known.
  Uint8List? seedIdFor(int height) => idAt(seedHeight(height));

  // ---- syncing ------------------------------------------------------------

  /// Sparse id list for REQUEST_CHAIN: newest first, ending with genesis.
  List<Uint8List> sparseIds() {
    final out = <Uint8List>[];
    var i = 0, step = 1, h = _tip;
    while (h >= _bottom) {
      out.add(_byHeight[h]!.id);
      if (i >= 10) step *= 2;
      h -= step;
      i++;
    }
    if (out.isEmpty || !bytesEqual(out.last, _byHeight[_bottom]!.id)) out.add(_byHeight[_bottom]!.id);
    out.add(mainnetGenesisId);
    return out;
  }

  /// Records a peer's advertised tip.
  void noteRemoteTip(CoreSyncData sync) {
    final top = sync.currentHeight - 1;
    if (top > bestKnownHeight) bestKnownHeight = top;
  }

  /// Handles a chain entry: queues the ids above our tip. Returns false when
  /// the entry does not connect to our window (ask another peer).
  bool onChainEntry(ResponseChainEntry e) {
    if (e.blockIds.isEmpty) return false;
    final start = e.startHeight;
    if (start < _bottom || start > _tip) return false;
    if (!bytesEqual(e.blockIds.first, _byHeight[start]!.id)) return false;
    // Find the last id we already have; everything after it is new.
    var i = 0;
    while (i + 1 < e.blockIds.length && start + i + 1 <= _tip && bytesEqual(e.blockIds[i + 1], _byHeight[start + i + 1]!.id)) {
      i++;
    }
    final forkHeight = start + i;
    if (forkHeight < _tip) _rollback(forkHeight);
    _toFetch.clear();
    for (var k = i + 1; k < e.blockIds.length; k++) {
      _toFetch.add((start + k, e.blockIds[k]));
    }
    if (start + e.blockIds.length - 1 > bestKnownHeight) bestKnownHeight = start + e.blockIds.length - 1;
    return true;
  }

  /// Next ids to request with REQUEST_GET_OBJECTS.
  List<Uint8List> nextFetch([int max = 100]) => [for (final (_, id) in _toFetch.take(max)) id];

  void _rollback(int toHeight) {
    for (var h = _tip; h > toHeight; h--) {
      final hd = _byHeight.remove(h);
      if (hd != null) _heightById.remove(toHex(hd.id));
    }
    _tip = toHeight;
    _pow.removeWhere((p) => p.height > toHeight);
  }

  /// Timestamps and cumulative difficulties of the blocks before [height].
  BigInt _difficultyFor(int height) {
    final from = height - difficultyBlocksCount;
    final ts = <int>[], cd = <BigInt>[];
    for (var h = from < _bottom ? _bottom : from; h < height; h++) {
      final hd = _byHeight[h]!;
      ts.add(hd.timestamp);
      cd.add(hd.cumulativeDifficulty);
    }
    return nextDifficulty(ts, cd);
  }

  /// Adds a block. It must extend our tip, possibly replacing it (a reorg of
  /// depth one is handled here; deeper reorgs arrive via [onChainEntry]).
  /// Returns the new header, or throws [LightChainError].
  LightHeader addBlock(MoneroBlock b) {
    final prevHeight = _heightById[toHex(b.header.prevId)];
    if (prevHeight == null) throw LightChainError('unknown parent ${toHex(b.header.prevId)}');
    final height = prevHeight + 1;
    if (b.height != height) throw LightChainError('coinbase height ${b.height} != $height');
    if (b.header.majorVersion != majorVersionAt(height)) throw LightChainError('wrong major version');
    final id = b.id();
    final existing = _byHeight[height];
    if (existing != null && bytesEqual(existing.id, id)) {
      _dropFetched(height, id);
      return existing;
    }
    if (height <= _tip) _rollback(prevHeight);
    final diff = _difficultyFor(height);
    final cd = _byHeight[prevHeight]!.cumulativeDifficulty + diff;
    final hd = LightHeader(height, id, b.header.timestamp, cd, diff, b.header.majorVersion);
    _put(hd);
    _dropFetched(height, id);
    // Check PoW for blocks near the known tip and for seed blocks.
    final nearTip = height >= bestKnownHeight - powCheckDepth;
    final isSeed = height % 2048 == 0;
    if (nearTip || isSeed) {
      final seed = seedIdFor(height);
      if (seed != null) _pow.add(PowCheck(height, id, b.hashingBlob(), seed, diff));
    }
    _prune();
    return hd;
  }

  void _dropFetched(int height, Uint8List id) {
    if (_toFetch.isNotEmpty && _toFetch.first.$1 == height && bytesEqual(_toFetch.first.$2, id)) {
      _toFetch.removeAt(0);
    } else {
      _toFetch.removeWhere((e) => e.$1 <= height);
    }
  }

  void _prune() {
    while (_tip - _bottom > keep) {
      final hd = _byHeight.remove(_bottom);
      if (hd != null) _heightById.remove(toHex(hd.id));
      _bottom++;
    }
  }

  /// PoW checks waiting to be run by the node.
  List<PowCheck> takePowChecks() {
    final out = List<PowCheck>.of(_pow);
    _pow.clear();
    return out;
  }

  /// Result of a PoW check. A failure rolls the chain back below it.
  void powResult(PowCheck c, bool ok) {
    final hd = _byHeight[c.height];
    if (hd == null || !bytesEqual(hd.id, c.id)) return;
    if (ok) {
      hd.powVerified = true;
    } else {
      _rollback(c.height - 1);
      throw LightChainError('PoW check failed at height ${c.height}');
    }
  }

  /// Compares a peer's advertised tip with ours: true (agrees), false
  /// (disagrees at the same top id), null (different tip, no information).
  bool? crossCheck(int peerKey, CoreSyncData sync) {
    final top = sync.currentHeight - 1;
    final hd = _byHeight[top];
    if (hd == null || !bytesEqual(hd.id, sync.topId)) return null;
    final agree = hd.cumulativeDifficulty == sync.cumulativeDifficulty;
    if (agree) {
      agreeingPeers.add(peerKey);
    } else {
      agreeingPeers.remove(peerKey);
    }
    return agree;
  }

  /// Median timestamp of the last 60 blocks (Monero's future-timestamp rule).
  int get medianTimestamp {
    final ts = <int>[];
    for (var h = _tip; h > _tip - 60 && h >= _bottom; h--) {
      ts.add(_byHeight[h]!.timestamp);
    }
    ts.sort();
    return ts.isEmpty ? 0 : ts[ts.length ~/ 2];
  }

  /// What a template for the next block needs.
  MinerData? get minerData {
    if (_tip < 0) return null;
    final next = _tip + 1;
    final seed = seedIdFor(next);
    if (seed == null) return null;
    return MinerData(
      majorVersion: majorVersionAt(next),
      height: next,
      prevId: tipHeader.id,
      seedHash: seed,
      difficulty: _difficultyFor(next),
      medianTimestamp: medianTimestamp,
    );
  }

  /// What we advertise to Monero peers: our tip once it is PoW-checked (a
  /// block every peer has), otherwise genesis.
  CoreSyncData get localSync {
    final hd = _byHeight[_tip];
    if (hd == null || !hd.powVerified) return CoreSyncData.genesis();
    return CoreSyncData(
      currentHeight: _tip + 1,
      cumulativeDifficulty: hd.cumulativeDifficulty,
      topId: hd.id,
      topVersion: hd.majorVersion,
    );
  }
}
