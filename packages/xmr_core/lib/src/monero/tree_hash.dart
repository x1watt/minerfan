import 'dart:typed_data';

import '../crypto/keccak.dart';
import '../util/bytes.dart';

/// Monero's transaction tree hash (src/crypto/tree-hash.c).
Uint8List treeHash(List<Uint8List> hashes) {
  final count = hashes.length;
  if (count == 0) throw ArgumentError('empty tree');
  if (count == 1) return Uint8List.fromList(hashes[0]);
  if (count == 2) return Keccak.hash256(concatBytes([hashes[0], hashes[1]]));
  var cnt = 2;
  while (cnt < count) {
    cnt <<= 1;
  }
  cnt >>= 1;
  final ints = List<Uint8List>.generate(cnt, (_) => Uint8List(32));
  final direct = 2 * cnt - count;
  for (var i = 0; i < direct; i++) {
    ints[i] = hashes[i];
  }
  for (var i = direct, j = direct; j < cnt; i += 2, j++) {
    ints[j] = Keccak.hash256(concatBytes([hashes[i], hashes[i + 1]]));
  }
  while (cnt > 2) {
    cnt >>= 1;
    for (var i = 0, j = 0; j < cnt; i += 2, j++) {
      ints[j] = Keccak.hash256(concatBytes([ints[i], ints[i + 1]]));
    }
  }
  return Keccak.hash256(concatBytes([ints[0], ints[1]]));
}

/// Merkle branch proving leaf 0 (the coinbase) against [treeHash]: the
/// sibling hashes from the bottom up, as P2Pool's `get_merkle_proof` builds
/// it for merge mining and `tree_branch` for the hashing blob.
List<Uint8List> coinbaseBranch(List<Uint8List> hashes) {
  final count = hashes.length;
  if (count <= 1) return const [];
  if (count == 2) return [hashes[1]];
  var cnt = 2;
  while (cnt < count) {
    cnt <<= 1;
  }
  cnt >>= 1;
  final branch = <Uint8List>[];
  var ints = List<Uint8List>.generate(cnt, (_) => Uint8List(32));
  final direct = 2 * cnt - count;
  for (var i = 0; i < direct; i++) {
    ints[i] = hashes[i];
  }
  final leafIsPaired = direct == 0;
  if (leafIsPaired) branch.add(hashes[1]);
  for (var i = direct, j = direct; j < cnt; i += 2, j++) {
    ints[j] = Keccak.hash256(concatBytes([hashes[i], hashes[i + 1]]));
  }
  // Index 0 is always in the left-most position of each level.
  while (cnt > 1) {
    branch.add(ints[1]);
    final next = List<Uint8List>.generate(cnt >> 1, (_) => Uint8List(32));
    for (var i = 0, j = 0; j < (cnt >> 1); i += 2, j++) {
      next[j] = Keccak.hash256(concatBytes([ints[i], ints[i + 1]]));
    }
    ints = next;
    cnt >>= 1;
  }
  return branch;
}

/// Root from a coinbase hash and its branch (leaf index 0).
Uint8List rootFromCoinbaseBranch(Uint8List coinbaseHash, List<Uint8List> branch) {
  var h = coinbaseHash;
  for (final s in branch) {
    h = Keccak.hash256(concatBytes([h, s]));
  }
  return h;
}
