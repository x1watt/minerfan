import 'dart:math';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';

import 'block.dart';
import 'bytes.dart';

/// A BIP37 bloom filter (`filterload`): peers send only the transactions
/// that match it, with a merkle proof per block.
class BloomFilter {
  final Uint8List data;
  final int hashFuncs;
  final int tweak;

  /// 1 = BLOOM_UPDATE_ALL: the peer adds the outpoints of matching outputs,
  /// so later spends of them match too.
  final int flags;

  BloomFilter._(this.data, this.hashFuncs, this.tweak, this.flags);

  /// A filter for [elements] items at a [falsePositiveRate] (BIP37 sizing).
  factory BloomFilter.forElements(int elements, {double falsePositiveRate = 0.0005, int? tweak, int flags = 1}) {
    final n = max(elements, 1);
    const ln2 = 0.6931471805599453;
    var size = (-1 / (ln2 * ln2) * n * log(falsePositiveRate) / 8).floor();
    size = size.clamp(1, 36000);
    var funcs = (size * 8 / n * ln2).floor();
    funcs = funcs.clamp(1, 50);
    return BloomFilter._(Uint8List(size), funcs, tweak ?? Random.secure().nextInt(1 << 32), flags);
  }

  void insert(List<int> element) {
    for (var i = 0; i < hashFuncs; i++) {
      final bit = murmur3((i * 0xFBA4C795 + tweak) & 0xffffffff, element) % (data.length * 8);
      data[bit >> 3] |= 1 << (bit & 7);
    }
  }

  bool contains(List<int> element) {
    for (var i = 0; i < hashFuncs; i++) {
      final bit = murmur3((i * 0xFBA4C795 + tweak) & 0xffffffff, element) % (data.length * 8);
      if (data[bit >> 3] & (1 << (bit & 7)) == 0) return false;
    }
    return true;
  }

  /// The `filterload` payload.
  Uint8List payload() {
    final w = ByteWriter()
      ..varBytes(data)
      ..u32(hashFuncs)
      ..u32(tweak)
      ..u8(flags);
    return w.take();
  }

  /// MurmurHash3 (x86, 32-bit), as BIP37 uses it.
  static int murmur3(int seed, List<int> data) {
    const c1 = 0xcc9e2d51, c2 = 0x1b873593;
    var h = seed;
    final n = data.length;
    final blocks = n ~/ 4;
    int mul(int a, int b) => ((a & 0xffff) * b + ((((a >>> 16) * b) & 0xffff) << 16)) & 0xffffffff;
    int rotl(int x, int r) => ((x << r) | (x >>> (32 - r))) & 0xffffffff;
    for (var i = 0; i < blocks; i++) {
      var k = data[i * 4] | data[i * 4 + 1] << 8 | data[i * 4 + 2] << 16 | data[i * 4 + 3] << 24;
      k = mul(k, c1);
      k = rotl(k, 15);
      k = mul(k, c2);
      h ^= k;
      h = rotl(h, 13);
      h = (mul(h, 5) + 0xe6546b64) & 0xffffffff;
    }
    var k1 = 0;
    final tail = blocks * 4;
    switch (n & 3) {
      case 3:
        k1 ^= data[tail + 2] << 16;
        k1 ^= data[tail + 1] << 8;
        k1 ^= data[tail];
      case 2:
        k1 ^= data[tail + 1] << 8;
        k1 ^= data[tail];
      case 1:
        k1 ^= data[tail];
    }
    if (n & 3 != 0) {
      k1 = mul(k1, c1);
      k1 = rotl(k1, 15);
      k1 = mul(k1, c2);
      h ^= k1;
    }
    h ^= n;
    h ^= h >>> 16;
    h = mul(h, 0x85ebca6b);
    h ^= h >>> 13;
    h = mul(h, 0xc2b2ae35);
    h ^= h >>> 16;
    return h;
  }
}

/// A `merkleblock`: a header and a partial merkle tree proving which
/// transactions of the block matched the filter.
class MerkleBlock {
  final BlockHeader header;
  final int totalTransactions;
  final List<Uint8List> hashes;
  final Uint8List flags;

  MerkleBlock(this.header, this.totalTransactions, this.hashes, this.flags);

  factory MerkleBlock.parse(Uint8List p) {
    final r = ByteReader(p);
    final header = BlockHeader.read(r);
    final total = r.u32();
    final hashes = [for (var i = r.varInt(); i > 0; i--) r.bytes(32)];
    return MerkleBlock(header, total, hashes, r.varBytes());
  }

  /// The matched transaction ids, or null when the proof does not lead to
  /// the header's merkle root.
  List<Uint8List>? matched() {
    if (totalTransactions == 0 || hashes.length > totalTransactions) return null;
    var height = 0;
    while (_width(height) > 1) {
      height++;
    }
    var bit = 0, used = 0;
    final out = <Uint8List>[];
    bool bad = false;

    Uint8List walk(int h, int pos) {
      if (bit >= flags.length * 8) {
        bad = true;
        return Uint8List(32);
      }
      final parentOfMatch = flags[bit >> 3] & (1 << (bit & 7)) != 0;
      bit++;
      if (h == 0 || !parentOfMatch) {
        if (used >= hashes.length) {
          bad = true;
          return Uint8List(32);
        }
        final hash = hashes[used++];
        if (h == 0 && parentOfMatch) out.add(hash);
        return hash;
      }
      final left = walk(h - 1, pos * 2);
      final right = pos * 2 + 1 < _width(h - 1) ? walk(h - 1, pos * 2 + 1) : left;
      if (pos * 2 + 1 < _width(h - 1) && bytesEqual(left, right)) bad = true; // CVE-2012-2459
      return sha256d([...left, ...right]);
    }

    final root = walk(height, 0);
    if (bad || used != hashes.length || !bytesEqual(root, header.merkleRoot)) return null;
    return out;
  }

  int _width(int h) => (totalTransactions + (1 << h) - 1) >> h;
}
