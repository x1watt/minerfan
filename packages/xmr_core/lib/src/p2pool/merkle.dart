import 'dart:typed_data';

import '../crypto/keccak.dart';
import 'package:crypto_core/crypto_core.dart';
import '../util/bytes.dart';
import '../util/reader.dart';
import '../util/varint.dart';

/// Merge-mining tag (coinbase extra tag 3) and the auxiliary chain Merkle
/// tree, ported from DataHoarder's P2Pool consensus (MIT).

class MergeMiningTag {
  final int numberAuxiliaryChains;
  final int nonce;
  final Uint8List rootHash;

  const MergeMiningTag(this.numberAuxiliaryChains, this.nonce, this.rootHash);

  static MergeMiningTag read(ByteReader r) {
    final data = r.varint();
    final k = data & 0xffffffff;
    final n = 1 + (k & 7);
    final chains = 1 + ((k >> 3) & ((1 << n) - 1));
    final nonce = (data >>> (3 + n)) & 0xffffffff;
    return MergeMiningTag(chains, nonce, r.bytes(32));
  }

  int get treeData {
    var nBits = 1;
    while ((1 << nBits) < numberAuxiliaryChains && nBits < 8) {
      nBits++;
    }
    return (nBits - 1) | ((numberAuxiliaryChains - 1) << 3) | (nonce << (3 + nBits));
  }

  Uint8List encode() => concatBytes([encodeVarint(treeData), rootHash]);
}

/// Slot of chain [id] in a merge-mining tree of [chains] leaves.
int auxiliarySlot(Uint8List id, int nonce, int chains) {
  if (chains <= 1) return 0;
  final buf = Uint8List(37)..setRange(0, 32, id);
  writeU32LE(buf, 32, nonce);
  buf[36] = 0x6d; // 'm'
  final h = Sha256.hash(buf);
  return readU32LE(h, 0) % chains;
}

int _previousPowerOfTwo(int x) => x == 0 ? 0 : 1 << (x.bitLength - 1);

Uint8List _pairHash(int index, Uint8List h, Uint8List p) =>
    Keccak.hash256((index & 1) != 0 ? concatBytes([p, h]) : concatBytes([h, p]));

/// Root of the aux tree from leaf [h] at [index] of [count] and its [proof],
/// or null if the proof has the wrong shape.
Uint8List? merkleProofRoot(List<Uint8List> proof, Uint8List h, int index, int count) {
  if (count == 1) return proof.isEmpty ? h : null;
  if (index >= count) return null;
  if (count == 2) {
    if (proof.length != 1) return null;
    return _pairHash(index, h, proof[0]);
  }
  var pow2cnt = _previousPowerOfTwo(count);
  final k = pow2cnt * 2 - count;
  var proofIndex = 0;
  if (index >= k) {
    index -= k;
    if (proof.isEmpty) return null;
    h = _pairHash(index, h, proof[0]);
    index = (index >> 1) + k;
    proofIndex = 1;
  }
  for (; pow2cnt >= 2; proofIndex++, index >>= 1, pow2cnt >>= 1) {
    if (proofIndex >= proof.length) return null;
    h = _pairHash(index, h, proof[proofIndex]);
  }
  if (proofIndex != proof.length) return null;
  return h;
}

bool verifyMerkleProof(List<Uint8List> proof, Uint8List h, int index, int count, Uint8List root) {
  final r = merkleProofRoot(proof, h, index, count);
  return r != null && bytesEqual(r, root);
}
