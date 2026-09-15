import 'dart:math';
import 'dart:typed_data';

import '../monero/hardforks.dart';
import '../util/bytes.dart';
import '../util/varint.dart';
import 'consensus.dart';
import 'merkle.dart';
import 'pool_block.dart';
import 'sidechain.dart';

/// Monero chain state a template is built on (P2Pool's "miner data").
class MinerData {
  final int majorVersion;
  final int height;
  final Uint8List prevId;
  final Uint8List seedHash;
  final BigInt difficulty;

  /// Median of the last 60 Monero block timestamps.
  final int medianTimestamp;

  const MinerData({
    required this.majorVersion,
    required this.height,
    required this.prevId,
    required this.seedHash,
    required this.difficulty,
    required this.medianTimestamp,
  });
}

/// Software id we put in our shares ("XMRD"), and version 0.1.0.
const int softwareIdXmrDart = 0x44524d58;
const int softwareVersion = 0x00000100;

/// A block template ready to hash: the share with nonce 0 and its hashing
/// blob. Set the nonce and call [finish] when a result meets the target.
class BlockTemplate {
  final PoolBlock block;
  final Uint8List hashingBlob;
  final int nonceOffset;
  final BigInt sidechainDifficulty;
  final BigInt mainchainDifficulty;
  final Uint8List seedHash;
  final int height;

  BlockTemplate(this.block, this.hashingBlob, this.nonceOffset, this.sidechainDifficulty, this.mainchainDifficulty,
      this.seedHash, this.height);

  /// The share with [nonce] filled in, ready to add and broadcast.
  PoolBlock finish(int nonce) {
    block.main.nonce = nonce;
    block.resetCaches();
    return block;
  }
}

/// Builds coinbase-only templates paying [spendKey]/[viewKey] a share of the
/// PPLNS window (P2Pool `BlockTemplate::update`, single wallet, no mempool).
class TemplateBuilder {
  final SideChain sidechain;
  final Uint8List spendKey;
  final Uint8List viewKey;
  final Random _rng;

  TemplateBuilder(this.sidechain, this.spendKey, this.viewKey, {Random? rng}) : _rng = rng ?? Random.secure();

  P2PoolConsensus get consensus => sidechain.consensus;

  BlockTemplate build(MinerData md, {int? nowSeconds, int? extraNonce}) {
    if (md.majorVersion > supportedMajorVersion) throw SideChainError('unsupported Monero version ${md.majorVersion}');
    final tip = sidechain.tip;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestamp = max(now, md.medianTimestamp + 1);
    final version = consensus.shareVersionAt(timestamp);

    Uint8List parentId, seed;
    int sideHeight;
    BigInt diff, cumDiff;
    final uncleIds = <Uint8List>[];
    if (tip != null) {
      parentId = tip.templateId(consensus);
      sideHeight = tip.side.height + 1;
      seed = bytesEqual(tip.main.prevId, md.prevId) ? tip.side.txKeySeed : tip.calculateTxKeySeed();
      diff = sidechain.difficulty;
      cumDiff = tip.side.cumulativeDifficulty + diff;
      for (final u in sidechain.possibleUncles(tip, sideHeight)) {
        uncleIds.add(u.templateId(consensus));
        cumDiff += u.side.difficulty;
        if (uncleIds.length >= maxUncleCount) break;
      }
    } else {
      parentId = Uint8List(32);
      sideHeight = 0;
      seed = consensus.id;
      diff = BigInt.from(consensus.minimumDifficulty);
      cumDiff = diff;
    }
    final txKey = deterministicTxPrivateKey(seed, md.prevId);
    final txPub = sidechain.derivations.txPublicKey(txKey);

    final side = SideData(
      spendKey: spendKey,
      viewKey: viewKey,
      txKeySeed: seed,
      txPrivateKey: txKey,
      parent: parentId,
      uncles: uncleIds,
      height: sideHeight,
      difficulty: diff,
      cumulativeDifficulty: cumDiff,
      softwareId: softwareIdXmrDart,
      softwareVersion: softwareVersion,
      randomNumber: _rng.nextInt(1 << 32),
      sideChainExtraNonce: _rng.nextInt(1 << 32),
    );

    final xn = Uint8List(sideExtraNonceSize);
    writeU32LE(xn, 0, extraNonce ?? _rng.nextInt(1 << 32));
    // Merge mining tag with one chain: tree data 0, root = template id.
    final mmData = concatBytes([encodeVarint(0), Uint8List(32)]);
    final main = PoolMainBlock(
      majorVersion: md.majorVersion,
      minorVersion: supportedMajorVersion,
      timestamp: timestamp,
      prevId: md.prevId,
      nonce: 0,
      unlockTime: md.height + 60,
      genHeight: md.height,
      outputs: const [],
      totalReward: tailEmissionReward,
      outputsBlobSize: 0,
      auxTemplateId: Uint8List(32),
      extra: [
        ExtraTag(extraTagPubKey, false, 0, txPub),
        ExtraTag(extraTagNonce, true, xn.length, xn),
        ExtraTag(extraTagMergeMining, true, mmData.length, mmData),
      ],
      txHashes: [],
      txParentIndices: [],
    );
    final block = PoolBlock(consensus, main, side, version);
    block.main.outputs = sidechain.calculateOutputs(block);
    block.resetCaches();

    final templateId = block.templateId(consensus);
    mmData.setRange(mmData.length - 32, mmData.length, templateId);
    block.mergeMiningTag = MergeMiningTag(1, 0, templateId);
    block.main.auxTemplateId = templateId;
    block.resetCaches();

    final blob = block.main.hashingBlob();
    final nonceOffset = 2 + encodeVarint(timestamp).length + 32;
    return BlockTemplate(block, blob, nonceOffset, diff, md.difficulty, md.seedHash, md.height);
  }
}

