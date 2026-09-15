import 'dart:typed_data';

import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../crypto/monero_keys.dart';
import '../monero/block.dart' show TxOutput;
import '../monero/hardforks.dart';
import '../util/bytes.dart';
import '../util/u64.dart';
import 'consensus.dart';
import 'merkle.dart';
import 'pool_block.dart';

/// The P2Pool sidechain: storage, verification, PPLNS, difficulty and fork
/// choice. Ported from DataHoarder's P2Pool consensus `sidechain` package
/// (MIT) for Monero v16. Single-threaded: owned by the node isolate.

/// What the sidechain needs to know about the Monero chain.
abstract class MainChainView {
  /// Monero difficulty of the block at [height], if known.
  BigInt? difficultyAt(int height);

  /// Height and timestamp of the Monero block with [id], if known.
  MainChainBlock? byId(Uint8List id);

  /// Current Monero tip, if known.
  MainChainBlock? get tip;
}

class MainChainBlock {
  final int height;
  final int timestamp;
  final Uint8List id;
  const MainChainBlock(this.height, this.timestamp, this.id);
}

class Share {
  final Uint8List spend;
  final Uint8List view;
  BigInt weight;
  Share(this.spend, this.view, this.weight);
}

int compareAddress(Share a, Share b) {
  final c = compareHash(a.spend, b.spend);
  return c != 0 ? c : compareHash(a.view, b.view);
}

class SideChainError implements Exception {
  final String message;
  SideChainError(this.message);
  @override
  String toString() => message;
}

/// Result of checking a block: fine, not yet checkable (missing data), or
/// invalid (the sender should be banned).
class VerifyResult {
  final String? cantVerify;
  final String? invalid;
  final List<Uint8List> missing;

  /// For [externalVerify]: the block is sound and can be added now even
  /// though [missing] ancestors still have to be fetched.
  final bool canAdd;
  const VerifyResult._(this.cantVerify, this.invalid, this.missing, [this.canAdd = false]);
  static const ok = VerifyResult._(null, null, [], true);
  factory VerifyResult.pending(String why, [List<Uint8List> missing = const []]) => VerifyResult._(why, null, missing);
  factory VerifyResult.addable(List<Uint8List> missing) =>
      VerifyResult._('missing ancestors', null, missing, true);
  factory VerifyResult.bad(String why) => VerifyResult._(null, why, const []);
  bool get isOk => cantVerify == null && invalid == null;
}

/// Caches the expensive curve operations shared across shares.
class DerivationCache {
  final Map<String, Uint8List> _derivations = {};
  final Map<String, (Uint8List, int)> _ephemeral = {};
  final Map<String, Uint8List> _txPub = {};

  Uint8List derivation(Uint8List viewPub, Uint8List txKey) {
    final k = '${toHex(viewPub)}${toHex(txKey)}';
    return _derivations[k] ??= generateKeyDerivation(viewPub, txKey)!;
  }

  /// One-time output key and view tag for output [index].
  (Uint8List, int) ephemeral(Uint8List spend, Uint8List view, Uint8List txKey, int index) {
    final k = '${toHex(spend)}${toHex(view)}${toHex(txKey)}$index';
    final hit = _ephemeral[k];
    if (hit != null) return hit;
    final d = derivation(view, txKey);
    final r = (derivePublicKey(d, index, spend)!, deriveViewTag(d, index));
    _ephemeral[k] = r;
    return r;
  }

  Uint8List txPublicKey(Uint8List txKey) => _txPub[toHex(txKey)] ??= scalarMultBase(txKey).encode();

  void clear() {
    _derivations.clear();
    _ephemeral.clear();
    _txPub.clear();
  }
}

int xorShift64Star(int x) {
  x ^= x >>> 12;
  x ^= x << 25;
  x ^= x >>> 27;
  return x * 0x2545F4914F6CDD1D;
}

/// P2Pool's deterministic shuffle of the PPLNS shares (v2+ shares).
void shuffleShares<T>(List<T> items, ShareVersion version, Uint8List txKeySeed) {
  final n = items.length;
  if (version.index < ShareVersion.v2.index || n <= 1) return;
  final h = Keccak.hash256(txKeySeed);
  var seed = readU64LE(h, 0);
  if (seed == 0) seed = 1;
  for (var i = 0; i < n - 1; i++) {
    seed = xorShift64Star(seed);
    final k = mulhU64(seed, n - i);
    final t = items[i];
    items[i] = items[i + k];
    items[i + k] = t;
  }
}

/// Splits [reward] proportionally to share weights (P2Pool `split_reward`).
/// Returns null when the split is impossible.
List<int>? splitReward(int reward, List<Share> shares) {
  if (shares.isEmpty) return null;
  var total = BigInt.zero;
  for (final s in shares) {
    total += s.weight;
  }
  if (total == BigInt.zero) return null;
  final r = BigInt.from(reward);
  var w = BigInt.zero;
  var given = 0;
  final out = List<int>.filled(shares.length, 0);
  for (var i = 0; i < shares.length; i++) {
    w += shares[i].weight;
    final next = (w * r ~/ total).toInt();
    out[i] = next - given;
    given = next;
  }
  for (final x in out) {
    if (x > maxTxOutputReward || x < 0) return null;
  }
  if (given != reward) return null;
  return out;
}

class SideChain {
  final P2PoolConsensus consensus;
  final MainChainView mainChain;
  final DerivationCache derivations = DerivationCache();

  final Map<String, PoolBlock> _byId = {};
  final Map<int, List<PoolBlock>> _byHeight = {};
  final Map<String, PoolBlock> _byMerkleRoot = {};
  final Set<String> _seen = {};

  PoolBlock? _tip;
  late BigInt _difficulty = BigInt.from(consensus.minimumDifficulty);

  /// Called when the chain tip changes.
  void Function(PoolBlock tip)? onNewTip;

  /// Called for blocks that should be relayed to peers.
  void Function(PoolBlock block)? onBroadcast;

  /// Optional log sink.
  void Function(String line)? log;

  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  SideChain(this.consensus, this.mainChain);

  PoolBlock? get tip => _tip;
  BigInt get difficulty => _difficulty;
  int get blockCount => _byId.length;

  PoolBlock? byId(Uint8List id) => _byId[toHex(id)];
  PoolBlock? byMerkleRoot(Uint8List root) => _byMerkleRoot[toHex(root)];
  List<PoolBlock> byHeight(int h) => _byHeight[h] ?? const [];
  Iterable<PoolBlock> get allBlocks => _byId.values;

  PoolBlock? parentOf(PoolBlock b) => b.parentCache ?? _byId[toHex(b.side.parent)];

  /// Uncles of [b], or null if any is missing.
  List<PoolBlock>? unclesOf(PoolBlock b) {
    if (b.side.uncles.isEmpty) return const [];
    if (b.unclesCache != null) return b.unclesCache;
    final out = <PoolBlock>[];
    for (final id in b.side.uncles) {
      final u = _byId[toHex(id)];
      if (u == null) return null;
      out.add(u);
    }
    return out;
  }

  /// True if this (template id, nonce, extra nonce) was already seen.
  bool blockSeen(PoolBlock b) {
    final t = _tip;
    if (t != null &&
        t.side.height > b.side.height + consensus.chainWindowSize * 2 &&
        b.side.cumulativeDifficulty < t.side.cumulativeDifficulty) {
      return true;
    }
    return !_seen.add(toHex(b.fullId(consensus)));
  }

  void blockUnsee(PoolBlock b) => _seen.remove(toHex(b.fullId(consensus)));

  // ---- PPLNS ----------------------------------------------------------

  /// Shares paid by a block on top of [tip] (P2Pool `get_shares`), already
  /// merged by wallet and shuffled, or throws [SideChainError].
  List<Share> getShares(PoolBlock tip) {
    final raw = <Share>[];
    _blocksInWindow(tip, (b, w) => raw.add(Share(b.side.spendKey, b.side.viewKey, w)));
    raw.sort(compareAddress);
    final merged = <Share>[];
    for (final s in raw) {
      if (merged.isNotEmpty && compareAddress(merged.last, s) == 0) {
        merged.last.weight += s.weight;
      } else {
        merged.add(Share(s.spend, s.view, s.weight));
      }
    }
    shuffleShares(merged, tip.shareVersion, tip.side.txKeySeed);
    return merged;
  }

  static final BigInt _maxDifficulty = (BigInt.one << 128) - BigInt.one;

  /// Walks the PPLNS window from [tip]; returns the bottom height.
  int _blocksInWindow(PoolBlock tip, void Function(PoolBlock b, BigInt weight) add) {
    var maxWeight = _maxDifficulty;
    if (!isZeroHash(tip.side.parent)) {
      final sh = seedHeight(tip.main.genHeight);
      final d = mainChain.difficultyAt(sh);
      if (d == null || d == BigInt.zero) {
        throw SideChainError('no Monero difficulty for height $sh');
      }
      if (tip.shareVersion.index >= ShareVersion.v2.index) maxWeight = d * BigInt.two;
    }
    var cur = tip;
    var depth = 0;
    var weight = BigInt.zero;
    var bottom = tip.side.height;
    while (true) {
      var curWeight = cur.side.difficulty;
      final uncles = unclesOf(cur);
      if (uncles == null) throw SideChainError('missing uncle of ${toHex(cur.templateId(consensus))}');
      for (final u in uncles) {
        if (tip.side.height - u.side.height >= consensus.chainWindowSize) continue;
        final (uw, penalty) = consensus.applyUnclePenalty(u.side.difficulty);
        final nw = weight + uw;
        if (nw > maxWeight) continue;
        curWeight += penalty;
        add(u, uw);
        weight = nw;
      }
      bottom = cur.side.height;
      add(cur, curWeight);
      weight += curWeight;
      if (weight > maxWeight) break;
      depth++;
      if (depth >= consensus.chainWindowSize) break;
      if (cur.side.height == 0) break;
      final p = parentOf(cur);
      if (p == null) throw SideChainError('missing parent ${toHex(cur.side.parent)}');
      cur = p;
    }
    return bottom;
  }

  /// Coinbase outputs a block on top of [block]'s parent must contain.
  List<TxOutput> calculateOutputs(PoolBlock block) {
    final shares = getShares(block);
    final rewards = splitReward(block.main.totalReward, shares);
    if (rewards == null || rewards.length != shares.length) {
      throw SideChainError('could not split reward');
    }
    return [
      for (var i = 0; i < shares.length; i++)
        () {
          final (key, tag) = derivations.ephemeral(shares[i].spend, shares[i].view, block.side.txPrivateKey, i);
          return TxOutput(rewards[i], key, block.main.majorVersion >= 15 ? tag : null);
        }(),
    ];
  }

  // ---- difficulty ------------------------------------------------------

  /// Difficulty of the next block on top of [tip] (P2Pool `get_difficulty`).
  BigInt difficultyAfter(PoolBlock tip) {
    final timestamps = <int>[];
    final cumDiffs = <(int, BigInt)>[];
    var cur = tip;
    var depth = 0;
    while (true) {
      timestamps.add(cur.main.timestamp);
      cumDiffs.add((cur.main.timestamp, cur.side.cumulativeDifficulty));
      final uncles = unclesOf(cur);
      if (uncles == null) throw SideChainError('missing uncle');
      for (final u in uncles) {
        if (tip.side.height - u.side.height >= consensus.chainWindowSize) continue;
        timestamps.add(u.main.timestamp);
        cumDiffs.add((u.main.timestamp, u.side.cumulativeDifficulty));
      }
      depth++;
      if (depth >= consensus.chainWindowSize) break;
      if (cur.side.height == 0) break;
      final p = parentOf(cur);
      if (p == null) throw SideChainError('missing parent ${toHex(cur.side.parent)}');
      cur = p;
    }
    return _nextDifficulty(timestamps, cumDiffs);
  }

  BigInt _nextDifficulty(List<int> timestamps, List<(int, BigInt)> data) {
    final n = timestamps.length;
    final cutSize = (n + 9) ~/ 10;
    final low = cutSize - 1;
    final up = n - cutSize;
    var oldest = timestamps[0];
    for (final t in timestamps) {
      if (t < oldest) oldest = t;
    }
    final deltas = <int>[];
    for (final t in timestamps) {
      final dt = t - oldest;
      if (dt > 0xffffffff) throw SideChainError('timestamp delta too large');
      deltas.add(dt);
    }
    deltas.sort();
    final lowerBound = oldest + deltas[low];
    final upperBound = oldest + deltas[up];
    final deltaIndex = up > low ? up - low : 1;
    var deltaT = upperBound > lowerBound ? upperBound - lowerBound : 0;
    if (deltaT < deltaIndex) deltaT = deltaIndex;
    BigInt? minD, maxD;
    for (final (ts, cd) in data) {
      if (lowerBound <= ts && ts <= upperBound) {
        if (minD == null || cd < minD) minD = cd;
        if (maxD == null || cd > maxD) maxD = cd;
      }
    }
    final delta = (maxD ?? BigInt.zero) - (minD ?? BigInt.zero);
    final d = delta * BigInt.from(consensus.targetBlockTime) ~/ BigInt.from(deltaT);
    final minDiff = BigInt.from(consensus.minimumDifficulty);
    return d < minDiff ? minDiff : d;
  }

  // ---- external blocks ------------------------------------------------

  /// Checks a block received from a peer before its PoW is known. Pruned
  /// blocks get their outputs filled in; compact blocks their transactions.
  /// Returns missing ancestors to request, or an invalid reason.
  VerifyResult externalVerify(PoolBlock block) {
    if (block.main.totalReward < tailEmissionReward) return VerifyResult.bad('block reward too low');
    final major = block.main.majorVersion;
    if (major < 14 || major > supportedMajorVersion) return VerifyResult.bad('unsupported version $major');

    if (major >= 15) {
      final pub = block.coinbasePubKey;
      if (pub == null || !bytesEqual(pub, derivations.txPublicKey(block.side.txPrivateKey))) {
        return VerifyResult.bad('invalid deterministic transaction keys');
      }
    }
    if (!checkKey(block.side.spendKey) || !checkKey(block.side.viewKey)) {
      return VerifyResult.bad('invalid wallet address');
    }

    final pre = _preProcess(block);
    if (!pre.isOk) return pre;

    for (final o in block.main.outputs) {
      if ((major >= 15) != (o.viewTag != null)) return VerifyResult.bad('unexpected output type');
      if (o.amount > maxTxOutputReward) return VerifyResult.bad('reward too high');
    }
    if (block.serialize().length > poolBlockMaxTemplateSize) return VerifyResult.bad('block too large');

    final templateId = block.templateId(consensus);
    if (block.shareVersion.index >= ShareVersion.v3.index) {
      if (!bytesEqual(templateId, block.fastTemplateId(consensus))) return VerifyResult.bad('invalid template id');
      final tag = block.mergeMiningTag!;
      final slot = auxiliarySlot(consensus.id, tag.nonce, tag.numberAuxiliaryChains);
      if (!verifyMerkleProof(block.side.merkleProof, templateId, slot, tag.numberAuxiliaryChains, tag.rootHash)) {
        return VerifyResult.bad('merkle proof does not verify');
      }
    } else if (!bytesEqual(templateId, block.main.tag(extraTagMergeMining)!.data)) {
      return VerifyResult.bad('invalid template id');
    }

    if (block.side.difficulty < BigInt.from(consensus.minimumDifficulty)) {
      return VerifyResult.bad('difficulty below minimum');
    }
    var tooLow = block.side.difficulty < _difficulty;
    if (tooLow) {
      final diff2 = block.side.difficulty * BigInt.two;
      final t = _tip;
      for (var tmp = t; tmp != null && tmp.side.height + consensus.chainWindowSize > t!.side.height; tmp = parentOf(tmp)) {
        if (diff2 >= tmp.side.difficulty) {
          tooLow = false;
          break;
        }
      }
    }
    if (tooLow) return VerifyResult.pending('difficulty too low');

    final known = mainChain.byId(block.main.prevId);
    if (known != null && known.height + 1 != block.main.genHeight) {
      return VerifyResult.bad('wrong Monero height ${block.main.genHeight}, expected ${known.height + 1}');
    }

    final missing = <Uint8List>[];
    if (!isZeroHash(block.side.parent) && byId(block.side.parent) == null) missing.add(block.side.parent);
    for (final u in block.side.uncles) {
      if (!isZeroHash(u) && byId(u) == null) missing.add(u);
    }
    return missing.isEmpty ? VerifyResult.ok : VerifyResult.addable(missing);
  }

  VerifyResult _preProcess(PoolBlock block) {
    if (block.needsCompactFill) {
      final parent = byId(block.side.parent);
      if (parent == null) return VerifyResult.pending('parent of compact block missing', [block.side.parent]);
      for (var i = 0; i < block.main.txParentIndices.length; i++) {
        final p = block.main.txParentIndices[i];
        if (p == 0) continue;
        if (p - 1 >= parent.main.txHashes.length) return VerifyResult.bad('compact tx index out of range');
        block.main.txHashes[i] = parent.main.txHashes[p - 1];
      }
      block.resetCaches();
    }
    if (block.isPruned) {
      final existing = byId(block.fastTemplateId(consensus));
      try {
        final outputs = existing != null ? existing.main.outputs : calculateOutputs(block);
        block.main.outputs = outputs;
      } on SideChainError catch (e) {
        final missing = <Uint8List>[];
        if (byId(block.side.parent) == null) missing.add(block.side.parent);
        return VerifyResult.pending('cannot fill outputs: $e', missing);
      }
      if (block.main.outputsBlob().length != block.main.outputsBlobSize) {
        return VerifyResult.bad('invalid outputs blob size');
      }
      block.resetCaches();
    }
    if (block.shareVersion.index >= ShareVersion.v3.index) {
      final id = block.templateId(consensus);
      if (isZeroHash(block.main.auxTemplateId)) {
        block.main.auxTemplateId = id;
      } else if (!bytesEqual(block.main.auxTemplateId, id)) {
        return VerifyResult.bad('invalid auxiliary template id');
      }
    }
    return VerifyResult.ok;
  }

  // ---- adding and verifying -------------------------------------------

  /// Adds a block whose structure and PoW were checked. Returns the
  /// verification result of this block.
  VerifyResult addBlock(PoolBlock block) {
    final key = toHex(block.templateId(consensus));
    if (_byId.containsKey(key)) return VerifyResult.ok;
    block.localTimeMs = block.localTimeMs == 0 ? nowMs() : block.localTimeMs;
    _byId[key] = block;
    (_byHeight[block.side.height] ??= []).add(block);
    if (block.shareVersion.index >= ShareVersion.v3.index) {
      _byMerkleRoot[toHex(block.mergeMiningTag!.rootHash)] = block;
    }
    _updateDepths(block);
    if (block.verified) {
      if (!block.invalid) _updateChainTip(block);
      return VerifyResult.ok;
    }
    return _verifyLoop(block);
  }

  /// Re-adds shares this node verified before (its on-disk cache) without
  /// repeating the PPLNS and output checks, then picks the tip once. Newest
  /// first, so depths settle without walking the chain for every share.
  /// Returns how many were added.
  int addTrusted(List<PoolBlock> blocks) {
    final sorted = [...blocks]..sort((a, b) => b.side.height.compareTo(a.side.height));
    final added = <PoolBlock>[];
    for (final b in sorted) {
      final id = b.templateId(consensus);
      final key = toHex(id);
      if (_byId.containsKey(key)) continue;
      if (b.shareVersion.index >= ShareVersion.v3.index && isZeroHash(b.main.auxTemplateId)) b.main.auxTemplateId = id;
      b.verified = true;
      b.invalid = false;
      b.localTimeMs = nowMs();
      _byId[key] = b;
      (_byHeight[b.side.height] ??= []).add(b);
      if (b.shareVersion.index >= ShareVersion.v3.index) _byMerkleRoot[toHex(b.mergeMiningTag!.rootHash)] = b;
      _updateDepths(b);
      added.add(b);
    }
    PoolBlock? best = _tip;
    for (final b in added) {
      if (b.depth == 0 && _isLongerChain(best, b).$1) best = b;
    }
    if (best != null && !identical(best, _tip)) _updateChainTip(best);
    return added.length;
  }

  /// Blocks waiting for verification. Verifying a whole window (thousands of
  /// shares, each with its PPLNS outputs) takes long on slow devices, so with
  /// [verifyBudgetMs] set the work is done in slices and [continueVerification]
  /// picks up the rest.
  final List<PoolBlock> _verifyStack = [];

  /// Milliseconds of verification per call; null verifies everything at once.
  int? verifyBudgetMs;

  bool get verificationPending => _verifyStack.isNotEmpty;

  /// Continues sliced verification (see [verifyBudgetMs]).
  void continueVerification() {
    if (_verifyStack.isNotEmpty) _verifyLoop(null);
  }

  VerifyResult _verifyLoop(PoolBlock? start) {
    final stack = _verifyStack;
    if (start != null) stack.add(start);
    final budget = verifyBudgetMs;
    final clock = Stopwatch()..start();
    PoolBlock? highest;
    var result = VerifyResult.ok;
    // The block being added is processed first (its result is returned);
    // after that the budget applies, whether it verified or is pending.
    var startDone = start == null;
    while (stack.isNotEmpty) {
      if (budget != null && startDone && clock.elapsedMilliseconds >= budget) break;
      final block = stack.removeLast();
      if (identical(block, start)) startDone = true;
      if (block.verified) continue;
      final r = _verifyBlock(block);
      if (r.invalid != null) {
        log?.call('block at height ${block.side.height} is invalid: ${r.invalid}');
        block.invalid = true;
        block.verified = r.cantVerify == null;
        if (identical(block, start)) result = r;
      } else if (r.cantVerify != null) {
        block.verified = false;
        block.invalid = false;
        if (identical(block, start)) result = r;
      } else {
        block.verified = true;
        block.invalid = false;
        final parent = parentOf(block);
        if (parent != null) {
          block.parentCache = parent;
          final uncles = unclesOf(block);
          if (uncles != null) block.unclesCache = uncles;
        }
        if (_isLongerChain(highest, block).$1) highest = block;
        if (block.wantBroadcast && !block.broadcasted && block.depth < uncleBlockDepth) {
          block.broadcasted = true;
          onBroadcast?.call(block);
        }
        final id = block.templateId(consensus);
        for (var i = 1; i <= uncleBlockDepth; i++) {
          for (final b in byHeight(block.side.height + i)) {
            if (i == 1 && bytesEqual(b.side.parent, id)) {
              if (b.depth + 1 < block.depth) b.depth = block.depth - 1;
              stack.add(b);
            } else if (b.side.uncles.any((u) => bytesEqual(u, id))) {
              if (b.depth + i < block.depth) b.depth = block.depth - i;
              stack.add(b);
            }
          }
        }
      }
    }
    if (highest != null) _updateChainTip(highest);
    return result;
  }

  VerifyResult _verifyBlock(PoolBlock block) {
    final side = block.side;
    if (side.height == 0) {
      if (!isZeroHash(side.parent) ||
          side.uncles.isNotEmpty ||
          side.difficulty != BigInt.from(consensus.minimumDifficulty) ||
          side.cumulativeDifficulty != BigInt.from(consensus.minimumDifficulty) ||
          (block.shareVersion.index >= ShareVersion.v2.index && !bytesEqual(side.txKeySeed, consensus.id))) {
        return VerifyResult.bad('genesis block has invalid parameters');
      }
      return VerifyResult.ok;
    }
    if (block.depth > (consensus.chainWindowSize - 1) * 2 + uncleBlockDepth) {
      return VerifyResult.ok; // too deep to matter
    }
    if (isZeroHash(side.parent)) return VerifyResult.bad('block must have a parent');
    final parent = parentOf(block);
    if (parent == null) return VerifyResult.pending('parent does not exist', [side.parent]);
    if (!parent.verified) return VerifyResult.pending('parent is not verified');
    if (parent.invalid) return VerifyResult.bad('parent is invalid');

    if (block.shareVersion.index >= ShareVersion.v2.index) {
      final expectedSeed =
          bytesEqual(parent.main.prevId, block.main.prevId) ? parent.side.txKeySeed : parent.calculateTxKeySeed();
      if (!bytesEqual(side.txKeySeed, expectedSeed)) return VerifyResult.bad('invalid tx key seed');
    }
    if (parent.side.height + 1 != side.height) return VerifyResult.bad('wrong height');
    if (side.uncles.length > maxUncleCount) return VerifyResult.bad('too many uncles');
    for (var i = 1; i < side.uncles.length; i++) {
      if (compareHash(side.uncles[i - 1], side.uncles[i]) >= 0) return VerifyResult.bad('invalid uncle order');
    }

    var expectedCum = parent.side.cumulativeDifficulty + side.difficulty;
    final mined = <String>{};
    {
      PoolBlock? tmp = parent;
      final n = side.height + 1 < uncleBlockDepth ? side.height + 1 : uncleBlockDepth;
      for (var i = 0; tmp != null && i < n; i++) {
        mined.add(toHex(tmp.templateId(consensus)));
        for (final u in tmp.side.uncles) {
          mined.add(toHex(u));
        }
        tmp = parentOf(tmp);
      }
    }
    for (final uncleId in side.uncles) {
      if (isZeroHash(uncleId)) return VerifyResult.bad('empty uncle hash');
      if (mined.contains(toHex(uncleId))) return VerifyResult.bad('uncle has already been mined');
      final uncle = byId(uncleId);
      if (uncle == null) return VerifyResult.pending('uncle does not exist', [uncleId]);
      if (!uncle.verified) return VerifyResult.pending('uncle is not verified');
      if (uncle.invalid) return VerifyResult.bad('uncle is invalid');
      if (uncle.side.height >= side.height || uncle.side.height + uncleBlockDepth < side.height) {
        return VerifyResult.bad('uncle at the wrong height');
      }
      PoolBlock? tmp = parent;
      while (tmp != null && tmp.side.height > uncle.side.height) {
        tmp = parentOf(tmp);
      }
      if (tmp == null || tmp.side.height < uncle.side.height) return VerifyResult.bad('uncle from different chain');
      var sameChain = false;
      PoolBlock? tmp2 = uncle;
      for (var j = 0;
          j < uncleBlockDepth && tmp != null && tmp2 != null && tmp.side.height + uncleBlockDepth >= side.height;
          j++) {
        if (bytesEqual(tmp.side.parent, tmp2.side.parent)) {
          sameChain = true;
          break;
        }
        tmp = parentOf(tmp);
        tmp2 = parentOf(tmp2);
      }
      if (!sameChain) return VerifyResult.bad('uncle from different chain');
      expectedCum += uncle.side.difficulty;
    }
    if (side.cumulativeDifficulty != expectedCum) return VerifyResult.bad('wrong cumulative difficulty');

    if (block.depth >= consensus.chainWindowSize) return VerifyResult.ok; // skip diff/reward checks

    BigInt diff;
    try {
      diff = identical(parent, _tip) ? _difficulty : difficultyAfter(parent);
    } on SideChainError catch (e) {
      return VerifyResult.pending('cannot compute difficulty: $e');
    }
    if (diff != side.difficulty) return VerifyResult.bad('wrong difficulty, got ${side.difficulty}, expected $diff');

    List<Share> shares;
    try {
      shares = getShares(block);
    } on SideChainError catch (e) {
      return VerifyResult.pending('cannot compute shares: $e');
    }
    final outs = block.main.outputs;
    if (shares.length != outs.length) {
      return VerifyResult.bad('invalid number of outputs, got ${outs.length}, expected ${shares.length}');
    }
    final total = outs.fold<int>(0, (s, o) => s + o.amount);
    if (total != block.main.totalReward) return VerifyResult.bad('invalid total reward');
    final rewards = splitReward(total, shares);
    if (rewards == null || rewards.length != outs.length) return VerifyResult.bad('invalid reward split');
    for (var i = 0; i < outs.length; i++) {
      if (rewards[i] != outs[i].amount) return VerifyResult.bad('invalid reward at index $i');
      final (key, tag) = derivations.ephemeral(shares[i].spend, shares[i].view, side.txPrivateKey, i);
      if (!bytesEqual(key, outs[i].key)) return VerifyResult.bad('incorrect output key at index $i');
      if (outs[i].viewTag != null && outs[i].viewTag != tag) return VerifyResult.bad('incorrect view tag at index $i');
    }
    return VerifyResult.ok;
  }

  void _updateDepths(PoolBlock block) {
    void raise(PoolBlock b, int d) {
      if (b.depth < d) b.depth = d;
    }

    final id = block.templateId(consensus);
    for (var i = 1; i <= uncleBlockDepth; i++) {
      for (final child in byHeight(block.side.height + i)) {
        if (bytesEqual(child.side.parent, id) && i == 1) raise(block, child.depth + 1);
        if (child.side.uncles.any((u) => bytesEqual(u, id))) raise(block, child.depth + i);
      }
    }
    final stack = <PoolBlock>[block];
    while (stack.isNotEmpty) {
      final b = stack.removeLast();
      if (!b.verified && (b.depth > (consensus.chainWindowSize - 1) * 2 + uncleBlockDepth * 2 || b.side.height == 0)) {
        _verifyLoop(b);
      }
      final bid = b.templateId(consensus);
      for (var i = 1; i <= uncleBlockDepth; i++) {
        for (final child in byHeight(b.side.height + i)) {
          final old = child.depth;
          if (i == 1 && bytesEqual(child.side.parent, bid) && b.depth > 0) raise(child, b.depth - 1);
          if (child.side.uncles.any((u) => bytesEqual(u, bid)) && b.depth > i) raise(child, b.depth - i);
          if (child.depth > old) stack.add(child);
        }
      }
      final parent = parentOf(b);
      if (parent != null && parent.side.height + 1 == b.side.height && parent.depth < b.depth + 1) {
        raise(parent, b.depth + 1);
        stack.add(parent);
      }
      for (final u in unclesOf(b) ?? const <PoolBlock>[]) {
        if (u.side.height >= b.side.height || u.side.height + uncleBlockDepth < b.side.height) continue;
        final d = b.side.height - u.side.height;
        if (u.depth < b.depth + d) {
          raise(u, b.depth + d);
          stack.add(u);
        }
      }
    }
  }

  void _updateChainTip(PoolBlock block) {
    if (!block.verified || block.invalid) return;
    if (block.depth >= consensus.chainWindowSize) return;
    final t = _tip;
    if (identical(block, t)) return;
    final (longer, alternative) = _isLongerChain(t, block);
    if (longer) {
      BigInt diff;
      try {
        diff = difficultyAfter(block);
      } on SideChainError {
        return;
      }
      _tip = block;
      _difficulty = diff;
      block.wantBroadcast = true;
      onNewTip?.call(block);
      if (alternative) {
        derivations.clear();
        log?.call('SYNCHRONIZED to tip ${toHex(block.templateId(consensus))} at height ${block.side.height}');
      }
      _pruneOldBlocks();
    }
    if (block.wantBroadcast && !block.broadcasted) {
      block.broadcasted = true;
      onBroadcast?.call(block);
    }
  }

  /// (isLonger, isAlternative), P2Pool `is_longer_chain`.
  (bool, bool) _isLongerChain(PoolBlock? block, PoolBlock candidate) {
    if (!candidate.verified || candidate.invalid) return (false, false);
    if (block == null) return (true, true);

    PoolBlock? ba = block;
    while (ba != null && ba.side.height > candidate.side.height) {
      ba = parentOf(ba);
    }
    if (ba != null) {
      PoolBlock? ca = candidate;
      while (ca != null && ca.side.height > ba.side.height) {
        ca = parentOf(ca);
      }
      while (ba != null && ca != null) {
        if (bytesEqual(ba.side.parent, ca.side.parent)) {
          if (block.side.height - ba.side.height >= consensus.chainWindowSize ||
              candidate.side.height - ca.side.height >= consensus.chainWindowSize) {
            break;
          }
          return (block.side.cumulativeDifficulty < candidate.side.cumulativeDifficulty, false);
        }
        ba = parentOf(ba);
        ca = parentOf(ca);
      }
    }

    var blockTotal = BigInt.zero, candTotal = BigInt.zero;
    PoolBlock? oldChain = block, newChain = candidate;
    var candMainHeight = 0, candMainMin = 0;
    final curMonero = <String>{}, candMonero = <String>{};
    final candTimestamps = <int>[];
    var deviation = 0;
    for (var i = 0; i < consensus.chainWindowSize && (oldChain != null || newChain != null); i++) {
      if (oldChain != null) {
        void addMonero(Uint8List id) {
          if (mainChain.byId(id) != null) curMonero.add(toHex(id));
        }

        blockTotal += oldChain.side.difficulty;
        for (final u in unclesOf(oldChain) ?? const <PoolBlock>[]) {
          if (block.side.height - u.side.height < consensus.chainWindowSize) {
            blockTotal += u.side.difficulty;
            addMonero(u.main.prevId);
          }
        }
        addMonero(oldChain.main.prevId);
        oldChain = parentOf(oldChain);
      }
      if (newChain != null) {
        void addMonero(Uint8List id, int ts) {
          final data = mainChain.byId(id);
          if (data == null) return;
          if (data.timestamp > 0) {
            final d = (ts - data.timestamp).abs();
            if (d > deviation) deviation = d;
          }
          if (candMonero.add(toHex(id)) && data.height > candMainHeight) candMainHeight = data.height;
        }

        final g = newChain.main.genHeight;
        candMainMin = candMainMin != 0 ? (g < candMainMin ? g : candMainMin) : g;
        candTotal += newChain.side.difficulty;
        candTimestamps.add(newChain.main.timestamp);
        for (final u in unclesOf(newChain) ?? const <PoolBlock>[]) {
          if (candidate.side.height - u.side.height < consensus.chainWindowSize) {
            if (u.main.genHeight < candMainMin) candMainMin = u.main.genHeight;
            candTotal += u.side.difficulty;
            candTimestamps.add(u.main.timestamp);
            addMonero(u.main.prevId, u.main.timestamp);
          }
        }
        addMonero(newChain.main.prevId, newChain.main.timestamp);
        newChain = parentOf(newChain);
      }
    }
    if (blockTotal >= candTotal) return (false, true);

    final headerTip = mainChain.tip;
    if (headerTip == null) return (false, true);
    if (candMainHeight + 10 < headerTip.height) return (false, true);
    final limit = consensus.chainWindowSize * 4 * consensus.targetBlockTime ~/ 120;
    if (candMainMin + limit < headerTip.height) return (false, true);
    if (candMonero.length * 2 < curMonero.length || candMainHeight < candMainMin) return (false, true);
    if (deviation > 3600 * 3) return (false, true);
    int span80(List<int> v) {
      if (v.isEmpty) return 0;
      final s = List<int>.of(v)..sort();
      final cut = (s.length + 9) ~/ 10;
      final p1 = cut - 1, p2 = s.length - cut;
      if (p1 >= p2) return 0;
      return s[p2] - s[p1];
    }

    final span = span80(candTimestamps);
    final moneroSpan = (candMainHeight + 1 - candMainMin) * 120 * 8 ~/ 10;
    if (span * 3 < moneroSpan * 2 || span * 3 > moneroSpan * 4) return (false, true);
    return (true, true);
  }

  void _pruneOldBlocks() {
    final t = _tip;
    final distance = consensus.pruneDistance;
    if (t == null || t.side.height < distance) return;
    final h = t.side.height - distance;
    final delayMs = consensus.chainWindowSize * 4 * consensus.targetBlockTime * 1000;
    final cutoff = nowMs() - delayMs;
    final heights = _byHeight.keys.where((k) => k <= h).toList();
    var pruned = 0;
    for (final height in heights) {
      final list = _byHeight[height]!;
      list.removeWhere((b) {
        if (b.depth > distance || b.localTimeMs <= cutoff) {
          _byId.remove(toHex(b.templateId(consensus)));
          if (b.mergeMiningTag != null) _byMerkleRoot.remove(toHex(b.mergeMiningTag!.rootHash));
          b.parentCache = null;
          b.unclesCache = null;
          pruned++;
          return true;
        }
        return false;
      });
      if (list.isEmpty) _byHeight.remove(height);
    }
    if (pruned > 0) {
      _seen.removeWhere((k) => !_byId.containsKey(k.substring(0, 64)));
      log?.call('pruned $pruned old blocks at heights <= $h');
    }
  }

  /// Parents and uncles referenced by unverified blocks but not present.
  List<Uint8List> missingBlocks() {
    final out = <Uint8List>[];
    final seen = <String>{};
    for (final b in _byId.values) {
      if (b.verified) continue;
      if (!isZeroHash(b.side.parent) && byId(b.side.parent) == null && seen.add(toHex(b.side.parent))) {
        out.add(b.side.parent);
      }
      var missingUncles = 0;
      for (final u in b.side.uncles) {
        if (!isZeroHash(u) && byId(u) == null && seen.add(toHex(u))) {
          out.add(u);
          if (++missingUncles >= 2) return out;
        }
      }
    }
    return out;
  }

  /// Verified uncles a new block on top of [tip] may include.
  List<PoolBlock> possibleUncles(PoolBlock tip, int forHeight) {
    final mined = <String>{};
    PoolBlock? tmp = tip;
    final n = tip.side.height + 1 < uncleBlockDepth ? tip.side.height + 1 : uncleBlockDepth;
    for (var i = 0; tmp != null && i < n; i++) {
      mined.add(toHex(tmp.templateId(consensus)));
      for (final u in tmp.side.uncles) {
        mined.add(toHex(u));
      }
      tmp = parentOf(tmp);
    }
    final out = <PoolBlock>[];
    for (var i = 0; i < n; i++) {
      for (final u in byHeight(tip.side.height - i)) {
        if (!u.verified || u.invalid) continue;
        if (mined.contains(toHex(u.templateId(consensus)))) continue;
        PoolBlock? a = tip;
        while (a != null && a.side.height > u.side.height) {
          a = parentOf(a);
        }
        if (a == null || a.side.height < u.side.height) continue;
        PoolBlock? b = u;
        var same = false;
        for (var j = 0; j < uncleBlockDepth && a != null && b != null && a.side.height + uncleBlockDepth >= forHeight; j++) {
          if (bytesEqual(a.side.parent, b.side.parent)) {
            same = true;
            break;
          }
          a = parentOf(a);
          b = parentOf(b);
        }
        if (same) out.add(u);
      }
    }
    out.sort((x, y) => compareHash(x.templateId(consensus), y.templateId(consensus)));
    return out;
  }
}
