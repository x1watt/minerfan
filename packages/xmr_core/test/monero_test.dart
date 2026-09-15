import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/keccak.dart';
import 'package:xmr_core/src/monero/address.dart';
import 'package:xmr_core/src/monero/base58.dart';
import 'package:xmr_core/src/monero/difficulty.dart';
import 'package:xmr_core/src/monero/hardforks.dart';
import 'package:xmr_core/src/monero/tree_hash.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/util/varint.dart';

void main() {
  test('address parse and re-encode', () {
    const a = '4AeEwC2Uik2Zv4uooAUWjQb2ZvcLDBmLXN4rzSn3wjBoY8EKfNkSUqeg5PxcnWTwB1b2V39PDwU9gaNE5SnxSQPYQyoQtr7';
    final addr = MoneroAddress.parse(a)!;
    expect(addr.network, MoneroNetwork.mainnet);
    expect(addr.kind, AddressKind.standard);
    expect(addr.encode(), a);
    // One changed character breaks the checksum.
    expect(MoneroAddress.parse('${a.substring(0, 20)}${a[20] == 'a' ? 'b' : 'a'}${a.substring(21)}'), isNull);
  });

  test('base58 round trip on all partial block sizes', () {
    final rnd = Random(1);
    for (var n = 0; n < 40; n++) {
      final data = Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
      expect(base58Decode(base58Encode(data)), data);
    }
  });

  test('varint', () {
    for (final v in [0, 1, 127, 128, 300, 0xffffffff, 1 << 62, -1]) {
      final e = encodeVarint(v);
      expect(readVarint(e, 0), (v, e.length));
    }
  });

  test('tree hash and coinbase branch agree', () {
    final rnd = Random(7);
    for (var count = 1; count <= 70; count++) {
      final hashes = List.generate(count, (_) => Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))));
      final root = treeHash(hashes);
      final branch = coinbaseBranch(hashes);
      expect(toHex(rootFromCoinbaseBranch(hashes[0], branch)), toHex(root), reason: 'count=$count');
    }
    // Two leaves: plain keccak of the concatenation.
    final a = Uint8List(32)..[0] = 1, b = Uint8List(32)..[0] = 2;
    expect(treeHash([a, b]), Keccak.hash256(concatBytes([a, b])));
  });

  test('seed height and hardforks', () {
    expect(seedHeight(1), 0);
    expect(seedHeight(2048 + 64), 0);
    expect(seedHeight(2048 + 64 + 1), 2048);
    expect(seedHeight(3456189), 3454976);
    expect(majorVersionAt(3761003), 16);
  });

  test('difficulty: constant block time keeps difficulty', () {
    final ts = <int>[], cd = <BigInt>[];
    var cum = BigInt.zero;
    final d = BigInt.parse('750000000000');
    for (var i = 0; i < difficultyBlocksCount; i++) {
      ts.add(1700000000 + 120 * i);
      cum += d;
      cd.add(cum);
    }
    expect(nextDifficulty(ts, cd), d);
  });
}
