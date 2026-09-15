import 'dart:convert';
import 'dart:typed_data';

import '../crypto/ed25519.dart';
import '../crypto/keccak.dart';
import '../monero/block.dart' show TxOutput, rctNullBaseHash;
import '../monero/hardforks.dart';
import '../monero/tree_hash.dart';
import '../util/bytes.dart';
import '../util/reader.dart';
import '../util/varint.dart';
import 'consensus.dart';
import 'merkle.dart';

/// A P2Pool share ("pool block"): a Monero block template plus sidechain
/// data. Ported from DataHoarder's P2Pool consensus (MIT) for Monero v16.

const int extraTagPadding = 0x00, extraTagPubKey = 0x01, extraTagNonce = 0x02;
const int extraTagMergeMining = 0x03, extraTagAdditionalPubKeys = 0x04;
const int sideExtraNonceSize = 4, sideExtraNonceMaxSize = 14;

class ExtraTag {
  final int tag;
  final bool hasVarint;
  final int varint;
  final Uint8List data;

  const ExtraTag(this.tag, this.hasVarint, this.varint, this.data);

  void write(BytesBuilder b) {
    b.addByte(tag);
    if (hasVarint) writeVarint(b, varint);
    b.add(data);
  }

  int get length => 1 + (hasVarint ? encodeVarint(varint).length : 0) + data.length;

  static List<ExtraTag> parseAll(Uint8List bytes) {
    final r = ByteReader(bytes);
    final tags = <ExtraTag>[];
    while (!r.isDone) {
      final tag = r.byte();
      switch (tag) {
        case extraTagPadding:
          var n = 0;
          while (!r.isDone) {
            if (r.byte() != 0) throw FormatError('padding is not zero');
            n++;
            if (n >= 255) throw FormatError('padding too big');
          }
          tags.add(ExtraTag(tag, false, 0, Uint8List(n)));
        case extraTagPubKey:
          tags.add(ExtraTag(tag, false, 0, r.bytes(32)));
        case extraTagNonce:
          final n = r.varint();
          if (n > 255) throw FormatError('nonce too big');
          tags.add(ExtraTag(tag, true, n, r.bytes(n)));
        case extraTagAdditionalPubKeys:
          final n = r.varint();
          tags.add(ExtraTag(tag, true, n, r.bytes(32 * n)));
        case extraTagMergeMining:
          final n = r.varint();
          tags.add(ExtraTag(tag, true, n, r.bytes(n)));
        default:
          throw FormatError('unknown extra tag $tag');
      }
    }
    return tags;
  }
}

class MergeMiningExtraEntry {
  final Uint8List chainId;
  final Uint8List data;
  const MergeMiningExtraEntry(this.chainId, this.data);
}

/// Sidechain part of a share.
class SideData {
  Uint8List spendKey;
  Uint8List viewKey;

  /// v2+: seed of the deterministic coinbase key. v1: stored private key.
  Uint8List txKeySeed;

  /// Coinbase private key; derived from the seed for v2+ shares.
  Uint8List txPrivateKey;

  Uint8List parent;
  List<Uint8List> uncles;
  int height;
  BigInt difficulty;
  BigInt cumulativeDifficulty;
  List<Uint8List> merkleProof;
  List<MergeMiningExtraEntry> mergeMiningExtra;
  int softwareId, softwareVersion, randomNumber, sideChainExtraNonce;

  SideData({
    required this.spendKey,
    required this.viewKey,
    required this.txKeySeed,
    Uint8List? txPrivateKey,
    required this.parent,
    required this.uncles,
    required this.height,
    required this.difficulty,
    required this.cumulativeDifficulty,
    this.merkleProof = const [],
    this.mergeMiningExtra = const [],
    this.softwareId = 0,
    this.softwareVersion = 0,
    this.randomNumber = 0,
    this.sideChainExtraNonce = 0,
  }) : txPrivateKey = txPrivateKey ?? Uint8List(32);

  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

  static BigInt _diff(ByteReader r) {
    final lo = BigInt.from(r.varint()).toUnsigned(64);
    final hi = BigInt.from(r.varint()).toUnsigned(64);
    return (hi << 64) | lo;
  }

  static void _writeDiff(BytesBuilder b, BigInt d) {
    writeVarint(b, (d & _mask64).toSigned(64).toInt());
    writeVarint(b, ((d >> 64) & _mask64).toSigned(64).toInt());
  }

  static SideData read(ByteReader r, ShareVersion v) {
    final spend = r.bytes(32);
    final view = r.bytes(32);
    final seedOrKey = r.bytes(32);
    final parent = r.bytes(32);
    final nUncles = r.varint();
    if (nUncles > 64) throw FormatError('too many uncles');
    final uncles = [for (var i = 0; i < nUncles; i++) r.bytes(32)];
    final height = r.varint();
    if (height > 31556952000) throw FormatError('side height too high');
    final diff = _diff(r);
    final cum = _diff(r);
    if (diff > cum) throw FormatError('difficulty above cumulative difficulty');
    var proof = <Uint8List>[];
    final mm = <MergeMiningExtraEntry>[];
    if (v.index >= ShareVersion.v3.index) {
      final n = r.byte();
      if (n > 8) throw FormatError('merkle proof too large');
      proof = [for (var i = 0; i < n; i++) r.bytes(32)];
      final m = r.varint();
      if (m > 256) throw FormatError('merge mining data too big');
      for (var i = 0; i < m; i++) {
        final id = r.bytes(32);
        if (mm.isNotEmpty && compareHash(mm.last.chainId, id) >= 0) {
          throw FormatError('merge mining chain ids not ordered');
        }
        final len = r.varint();
        if (len > poolBlockMaxTemplateSize) throw FormatError('merge mining data too big');
        mm.add(MergeMiningExtraEntry(id, r.bytes(len)));
      }
    }
    var sid = 0, sver = 0, rnd = 0, sxn = 0;
    if (v.index >= ShareVersion.v2.index) {
      sid = r.u32();
      sver = r.u32();
      rnd = r.u32();
      sxn = r.u32();
    }
    return SideData(
      spendKey: spend,
      viewKey: view,
      txKeySeed: v.index >= ShareVersion.v2.index ? seedOrKey : Uint8List(32),
      txPrivateKey: v.index >= ShareVersion.v2.index ? null : seedOrKey,
      parent: parent,
      uncles: uncles,
      height: height,
      difficulty: diff,
      cumulativeDifficulty: cum,
      merkleProof: proof,
      mergeMiningExtra: mm,
      softwareId: sid,
      softwareVersion: sver,
      randomNumber: rnd,
      sideChainExtraNonce: sxn,
    );
  }

  void write(BytesBuilder b, ShareVersion v) {
    b.add(spendKey);
    b.add(viewKey);
    b.add(v.index >= ShareVersion.v2.index ? txKeySeed : txPrivateKey);
    b.add(parent);
    writeVarint(b, uncles.length);
    for (final u in uncles) {
      b.add(u);
    }
    writeVarint(b, height);
    _writeDiff(b, difficulty);
    _writeDiff(b, cumulativeDifficulty);
    if (v.index >= ShareVersion.v3.index) {
      b.addByte(merkleProof.length);
      for (final h in merkleProof) {
        b.add(h);
      }
      writeVarint(b, mergeMiningExtra.length);
      for (final e in mergeMiningExtra) {
        b.add(e.chainId);
        writeVarint(b, e.data.length);
        b.add(e.data);
      }
    }
    if (v.index >= ShareVersion.v2.index) {
      final t = Uint8List(16);
      writeU32LE(t, 0, softwareId);
      writeU32LE(t, 4, softwareVersion);
      writeU32LE(t, 8, randomNumber);
      writeU32LE(t, 12, sideChainExtraNonce);
      b.add(t);
    }
  }
}

/// Hash ordering used by P2Pool: four little-endian 64-bit words, the most
/// significant word being bytes 24..31. Equivalent to comparing the bytes
/// from index 31 down to 0.
int compareHash(Uint8List a, Uint8List b) {
  for (var i = 31; i >= 0; i--) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}

final Uint8List zeroHash = Uint8List(32);

bool isZeroHash(Uint8List h) {
  for (final x in h) {
    if (x != 0) return false;
  }
  return true;
}

/// The Monero part of a share.
class PoolMainBlock {
  int majorVersion;
  int minorVersion;
  int timestamp;
  Uint8List prevId;
  int nonce;
  int unlockTime;
  int genHeight;

  /// Coinbase outputs; empty for a pruned share until recomputed.
  List<TxOutput> outputs;
  int totalReward;
  int outputsBlobSize;

  /// v3 pruned shares carry their template id in place of the outputs.
  Uint8List auxTemplateId;
  List<ExtraTag> extra;
  List<Uint8List> txHashes;

  /// Compact encoding: 1-based index into the parent's list, 0 = explicit.
  List<int> txParentIndices;

  PoolMainBlock({
    required this.majorVersion,
    required this.minorVersion,
    required this.timestamp,
    required this.prevId,
    required this.nonce,
    required this.unlockTime,
    required this.genHeight,
    required this.outputs,
    required this.totalReward,
    required this.outputsBlobSize,
    required this.auxTemplateId,
    required this.extra,
    required this.txHashes,
    required this.txParentIndices,
  });

  ExtraTag? tag(int t) {
    for (final e in extra) {
      if (e.tag == t) return e;
    }
    return null;
  }

  Uint8List outputsBlob() {
    final b = BytesBuilder(copy: false);
    writeVarint(b, outputs.length);
    for (final o in outputs) {
      writeVarint(b, o.amount);
      if (o.viewTag != null) {
        b.addByte(3);
        b.add(o.key);
        b.addByte(o.viewTag!);
      } else {
        b.addByte(2);
        b.add(o.key);
      }
    }
    return b.takeBytes();
  }

  void _writeHeader(BytesBuilder b, {bool zeroNonce = false}) {
    b.addByte(majorVersion);
    b.addByte(minorVersion);
    writeVarint(b, timestamp);
    b.add(prevId);
    final n = Uint8List(4);
    if (!zeroNonce) writeU32LE(n, 0, nonce);
    b.add(n);
  }

  void _writeCoinbaseHead(BytesBuilder b) {
    b.addByte(2); // version
    writeVarint(b, unlockTime);
    b.addByte(1); // input count
    b.addByte(0xff); // txin_gen
    writeVarint(b, genHeight);
  }

  Uint8List _extraBlob({bool sidechainHashing = false, bool zeroTemplateId = false}) {
    final b = BytesBuilder(copy: false);
    for (final t in extra) {
      if (sidechainHashing && t.tag == extraTagNonce) {
        b.addByte(t.tag);
        writeVarint(b, t.varint);
        final d = Uint8List.fromList(t.data);
        for (var i = 0; i < sideExtraNonceSize && i < d.length; i++) {
          d[i] = 0;
        }
        b.add(d);
      } else if (sidechainHashing && zeroTemplateId && t.tag == extraTagMergeMining) {
        b.addByte(t.tag);
        writeVarint(b, t.varint);
        final d = Uint8List.fromList(t.data);
        for (var i = d.length >= 32 ? d.length - 32 : 0; i < d.length; i++) {
          d[i] = 0;
        }
        b.add(d);
      } else {
        t.write(b);
      }
    }
    return b.takeBytes();
  }

  /// Full coinbase transaction bytes (as Monero serializes it).
  Uint8List coinbaseBlob() {
    final b = BytesBuilder(copy: false);
    _writeCoinbaseHead(b);
    b.add(outputsBlob());
    final e = _extraBlob();
    writeVarint(b, e.length);
    b.add(e);
    b.addByte(0);
    return b.takeBytes();
  }

  Uint8List coinbaseHash() {
    final full = coinbaseBlob();
    final prefixHash = Keccak.hash256(Uint8List.sublistView(full, 0, full.length - 1));
    return Keccak.hash256(concatBytes([prefixHash, rctNullBaseHash, zeroHash]));
  }

  /// Serialization inside a share: full, pruned (outputs replaced by their
  /// total and size) and/or compact (tx hashes as parent indices).
  void write(BytesBuilder b, {bool pruned = false, bool compact = false, bool withTemplateId = false}) {
    _writeHeader(b);
    _writeCoinbaseHead(b);
    if (pruned) {
      writeVarint(b, 0);
      writeVarint(b, totalReward);
      writeVarint(b, outputsBlob().length);
      if (withTemplateId) b.add(auxTemplateId);
    } else {
      b.add(outputsBlob());
    }
    final e = _extraBlob();
    writeVarint(b, e.length);
    b.add(e);
    b.addByte(0);
    writeVarint(b, txHashes.length);
    for (var i = 0; i < txHashes.length; i++) {
      if (compact) {
        final p = i < txParentIndices.length ? txParentIndices[i] : 0;
        writeVarint(b, p);
        if (p == 0) b.add(txHashes[i]);
      } else {
        b.add(txHashes[i]);
      }
    }
  }

  /// The part of the Monero block that goes into the sidechain template id
  /// and the tx key seed: nonce and extra nonce zeroed, and the merge mining
  /// root zeroed as well when [zeroTemplateId].
  Uint8List sidechainHashingBlob(bool zeroTemplateId) {
    final b = BytesBuilder(copy: false);
    _writeHeader(b, zeroNonce: true);
    _writeCoinbaseHead(b);
    b.add(outputsBlob());
    final e = _extraBlob(sidechainHashing: true, zeroTemplateId: zeroTemplateId);
    writeVarint(b, e.length);
    b.add(e);
    b.addByte(0);
    writeVarint(b, txHashes.length);
    for (final h in txHashes) {
      b.add(h);
    }
    return b.takeBytes();
  }

  /// The RandomX input for this block.
  Uint8List hashingBlob() {
    final b = BytesBuilder(copy: false);
    _writeHeader(b);
    b.add(treeHash([coinbaseHash(), ...txHashes]));
    writeVarint(b, txHashes.length + 1);
    return b.takeBytes();
  }

  /// Monero block id.
  Uint8List id() {
    final blob = hashingBlob();
    return Keccak.hash256(concatBytes([encodeVarint(blob.length), blob]));
  }

  /// The full Monero block (for submitting a found block).
  Uint8List moneroBlob() {
    final b = BytesBuilder(copy: false);
    _writeHeader(b);
    b.add(coinbaseBlob());
    writeVarint(b, txHashes.length);
    for (final h in txHashes) {
      b.add(h);
    }
    return b.takeBytes();
  }
}

final List<int> _txKeySeedDomain = [...utf8.encode('tx_key_seed'), 0];
final List<int> _txSecretKeyDomain = utf8.encode('tx_secret_key');

/// 15 * l, the largest multiple of the group order below 2^256.
final BigInt _scalarLimit = groupOrder * BigInt.from(15);

/// P2Pool's deterministic coinbase private key for [seed] and the previous
/// Monero block id.
Uint8List deterministicTxPrivateKey(Uint8List seed, Uint8List prevId) {
  final entropy = concatBytes([_txSecretKeyDomain, seed, prevId]);
  for (var counter = 1;; counter++) {
    final c = Uint8List(4);
    writeU32LE(c, 0, counter);
    final h = Keccak.hash256(concatBytes([entropy, c]));
    if (bytesToBigLE(h) >= _scalarLimit) continue;
    final k = scReduce32(h);
    if (!scIsZero(k)) return k;
  }
}

class PoolBlock {
  final P2PoolConsensus consensus;
  final PoolMainBlock main;
  final SideData side;
  final ShareVersion shareVersion;
  MergeMiningTag? mergeMiningTag;

  // Sidechain bookkeeping.
  bool verified = false;
  bool invalid = false;
  int depth = 0;
  bool wantBroadcast = false;
  bool broadcasted = false;
  int localTimeMs = 0;
  PoolBlock? parentCache;
  List<PoolBlock>? unclesCache;

  Uint8List? _templateId;
  Uint8List? _mainId;

  PoolBlock(this.consensus, this.main, this.side, this.shareVersion);

  /// Parses a share as received from a peer. [compact] selects the
  /// compact transaction encoding. Throws [FormatError].
  static PoolBlock parse(Uint8List data, P2PoolConsensus consensus, {bool compact = false}) {
    if (data.length > poolBlockMaxTemplateSize) throw FormatError('share too large');
    final r = ByteReader(data);
    final major = r.byte();
    if (major < 14 || major > supportedMajorVersion) throw FormatError('unsupported version $major');
    final minor = r.byte();
    if (minor < major || minor > 127) throw FormatError('bad minor version $minor');
    final timestamp = r.varint();
    final prevId = r.bytes(32);
    final nonce = r.u32();
    final version = consensus.shareVersionAt(timestamp);

    if (r.byte() != 2) throw FormatError('coinbase version');
    final unlockTime = r.varint();
    if (r.byte() != 1) throw FormatError('coinbase input count');
    if (r.byte() != 0xff) throw FormatError('coinbase input type');
    final genHeight = r.varint();
    if (unlockTime != genHeight + 60) throw FormatError('invalid unlock time');

    final nOut = r.varint();
    final outputs = <TxOutput>[];
    var totalReward = 0, blobSize = 0;
    var templateId = Uint8List(32);
    if (nOut > 0) {
      if (nOut > 10000) throw FormatError('too many outputs');
      for (var i = 0; i < nOut; i++) {
        final amount = r.varint();
        final type = r.byte();
        if (type == 3) {
          final key = r.bytes(32);
          outputs.add(TxOutput(amount, key, r.byte()));
        } else if (type == 2) {
          outputs.add(TxOutput(amount, r.bytes(32)));
        } else {
          throw FormatError('unknown output type $type');
        }
        totalReward += amount;
      }
    } else {
      totalReward = r.varint();
      blobSize = r.varint();
      if (version.index >= ShareVersion.v3.index) {
        templateId = r.bytes(32);
        if (isZeroHash(templateId)) throw FormatError('invalid template id');
      }
    }
    final extraLen = r.varint();
    if (extraLen > r.remaining) throw FormatError('extra overrun');
    final extra = ExtraTag.parseAll(r.bytes(extraLen));
    if (r.byte() != 0) throw FormatError('coinbase rct type');

    final nTx = r.varint();
    if (nTx > 65536) throw FormatError('too many transactions');
    final txs = <Uint8List>[];
    final parents = <int>[];
    for (var i = 0; i < nTx; i++) {
      if (compact) {
        final p = r.varint();
        parents.add(p);
        txs.add(p == 0 ? r.bytes(32) : Uint8List(32));
      } else {
        txs.add(r.bytes(32));
      }
    }
    final main = PoolMainBlock(
      majorVersion: major,
      minorVersion: minor,
      timestamp: timestamp,
      prevId: prevId,
      nonce: nonce,
      unlockTime: unlockTime,
      genHeight: genHeight,
      outputs: outputs,
      totalReward: totalReward,
      outputsBlobSize: blobSize,
      auxTemplateId: templateId,
      extra: extra,
      txHashes: txs,
      txParentIndices: parents,
    );
    if (majorVersionAt(genHeight) != major) {
      throw FormatError('expected major version ${majorVersionAt(genHeight)} at height $genHeight');
    }
    final side = SideData.read(r, version);
    if (!r.isDone) throw FormatError('trailing bytes in share');
    final b = PoolBlock(consensus, main, side, version);
    b._consensusChecks();
    b._fillPrivateKey();
    return b;
  }

  void _consensusChecks() {
    final ex = main.extra;
    if (ex.length != 3 || ex[0].tag != extraTagPubKey || ex[1].tag != extraTagNonce || ex[2].tag != extraTagMergeMining) {
      throw FormatError('wrong coinbase extra tags');
    }
    final nonceTag = ex[1];
    if (nonceTag.data.length < sideExtraNonceSize || nonceTag.data.length > sideExtraNonceMaxSize) {
      throw FormatError('invalid extra nonce size');
    }
    for (var i = sideExtraNonceSize; i < nonceTag.data.length; i++) {
      if (nonceTag.data[i] != 0) throw FormatError('non-zero extra nonce padding');
    }
    final mm = ex[2];
    if (mm.varint > 32 + 9) throw FormatError('merge mining tag too big');
    if (shareVersion.index <= ShareVersion.v2.index) {
      if (mm.varint != 32) throw FormatError('wrong merge mining tag depth');
    } else {
      final r = ByteReader(mm.data);
      mergeMiningTag = MergeMiningTag.read(r);
      if (!r.isDone) throw FormatError('wrong merge mining tag length');
    }
  }

  void _fillPrivateKey() {
    if (shareVersion.index >= ShareVersion.v2.index) {
      side.txPrivateKey = deterministicTxPrivateKey(side.txKeySeed, main.prevId);
    } else {
      side.txKeySeed = side.spendKey;
    }
  }

  bool get isPruned => main.outputs.isEmpty;

  /// Compact encoding against [parent]: transactions that are also in the
  /// parent are written as 1-based parent indices (a share's transactions
  /// mostly repeat its parent's, so this is several times smaller).
  Uint8List serializeCompactAgainst(PoolBlock? parent) {
    final saved = main.txParentIndices;
    final indices = List<int>.filled(main.txHashes.length, 0);
    if (parent != null) {
      final pos = <int, int>{};
      final ph = parent.main.txHashes;
      for (var i = 0; i < ph.length; i++) {
        pos.putIfAbsent(readU64LE(ph[i], 0), () => i + 1);
      }
      for (var i = 0; i < indices.length; i++) {
        final p = pos[readU64LE(main.txHashes[i], 0)];
        if (p != null && bytesEqual(ph[p - 1], main.txHashes[i])) indices[i] = p;
      }
    }
    main.txParentIndices = indices;
    try {
      return serialize(compact: true);
    } finally {
      main.txParentIndices = saved;
    }
  }

  /// Resolves transaction hashes stored as parent indices (compact
  /// encoding) from [parent]. False if an index is out of range.
  bool fillCompactFrom(PoolBlock parent) {
    final ph = parent.main.txHashes;
    for (var i = 0; i < main.txParentIndices.length; i++) {
      final p = main.txParentIndices[i];
      if (p == 0) continue;
      if (p - 1 >= ph.length) return false;
      main.txHashes[i] = ph[p - 1];
    }
    main.txParentIndices = [];
    resetCaches();
    return true;
  }

  bool get needsCompactFill => main.txParentIndices.isNotEmpty && main.txParentIndices.any((p) => p != 0) &&
      main.txHashes.any(isZeroHash);

  int get extraNonce {
    final t = main.tag(extraTagNonce);
    if (t == null || t.data.length < 4) return 0;
    return readU32LE(t.data, 0);
  }

  Uint8List? get coinbasePubKey => main.tag(extraTagPubKey)?.data;

  Uint8List sideBlob() {
    final b = BytesBuilder(copy: false);
    side.write(b, shareVersion);
    return b.takeBytes();
  }

  /// Full serialization (as sent in BLOCK_RESPONSE / BLOCK_BROADCAST).
  Uint8List serialize({bool pruned = false, bool compact = false}) {
    if (pruned && shareVersion.index >= ShareVersion.v3.index && isZeroHash(main.auxTemplateId)) {
      main.auxTemplateId = templateId(consensus);
    }
    final b = BytesBuilder(copy: false);
    main.write(b, pruned: pruned, compact: compact, withTemplateId: shareVersion.index >= ShareVersion.v3.index);
    side.write(b, shareVersion);
    return b.takeBytes();
  }

  /// Sidechain id: keccak(main hashing blob with ids zeroed || side || consensus id).
  Uint8List templateId(P2PoolConsensus consensus) =>
      _templateId ??= Keccak.hash256(concatBytes([main.sidechainHashingBlob(true), sideBlob(), consensus.id]));

  /// Template id as advertised by the block itself (merge mining root for a
  /// single chain), without recomputing it.
  Uint8List fastTemplateId(P2PoolConsensus consensus) {
    if (shareVersion.index >= ShareVersion.v3.index) {
      final tag = mergeMiningTag!;
      if (tag.numberAuxiliaryChains == 1) return tag.rootHash;
      if (!isZeroHash(main.auxTemplateId)) return main.auxTemplateId;
      return templateId(consensus);
    }
    return main.tag(extraTagMergeMining)!.data;
  }

  /// Seed for the coinbase key of children mined on a new Monero block.
  Uint8List calculateTxKeySeed() {
    if (shareVersion.index >= ShareVersion.v2.index) {
      return Keccak.hash256(concatBytes([_txKeySeedDomain, main.sidechainHashingBlob(false), sideBlob()]));
    }
    return side.spendKey;
  }

  Uint8List mainId() => _mainId ??= main.id();

  Uint8List? powHash;

  /// Clears cached ids after the block was modified (outputs filled in).
  void resetCaches() {
    _templateId = null;
    _mainId = null;
    powHash = null;
  }

  /// (sidechain id || nonce || extra nonce): identifies a found share.
  Uint8List fullId(P2PoolConsensus consensus) {
    final b = Uint8List(40)..setRange(0, 32, fastTemplateId(consensus));
    writeU32LE(b, 32, main.nonce);
    writeU32LE(b, 36, extraNonce);
    return b;
  }
}
