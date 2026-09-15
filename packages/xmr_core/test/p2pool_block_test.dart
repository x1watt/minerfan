import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/monero/difficulty.dart';
import 'package:xmr_core/src/p2pool/consensus.dart';
import 'package:xmr_core/src/p2pool/pool_block.dart';
import 'package:xmr_core/src/randomx/cache.dart';
import 'package:xmr_core/src/randomx/vm.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Expected values from the upstream P2Pool test suite (pool_block_tests.cpp).
/// Fixtures come from tool/fetch_testdata.sh.
void main() {
  final blockFile = File('test/fixtures/block.dat');
  final skip = blockFile.existsSync() ? null : 'run tool/fetch_testdata.sh';

  group('block.dat', () {
    late Uint8List data;
    late PoolBlock b;
    setUpAll(() {
      data = blockFile.readAsBytesSync();
      b = PoolBlock.parse(data, P2PoolConsensus.main);
    });

    test('fields', () {
      expect(b.main.majorVersion, 16);
      expect(b.main.minorVersion, 16);
      expect(b.main.timestamp, 1728813765);
      expect(b.main.nonce, 352454720);
      expect(b.main.genHeight, 3258099);
      expect(b.main.outputs.length, 27);
      expect(b.extraNonce, 2983923783);
      expect(b.main.txHashes.length, 20); // upstream counts the coinbase too (21)
      expect(b.side.uncles, isEmpty);
      expect(b.side.height, 9443384);
      expect(b.side.difficulty, BigInt.from(1828732004));
      expect(b.side.cumulativeDifficulty, BigInt.parse('15051095864465561'));
      expect(b.shareVersion, ShareVersion.v3);
    });

    test('round trip serialization', () {
      expect(toHex(b.serialize()), toHex(data));
    });

    test('template id equals merge mining root', () {
      expect(toHex(b.templateId(P2PoolConsensus.main)), toHex(b.fastTemplateId(P2PoolConsensus.main)));
    });

    test('pruned and compact round trips', () {
      final pruned = PoolBlock.parse(b.serialize(pruned: true), P2PoolConsensus.main);
      expect(pruned.isPruned, isTrue);
      expect(pruned.main.totalReward, b.main.totalReward);
      expect(pruned.main.outputsBlobSize, b.main.outputsBlob().length);
      expect(toHex(pruned.main.auxTemplateId), toHex(b.templateId(P2PoolConsensus.main)));
    });

    test('PoW hash', () {
      final seed = fromHex('bf513dbe52c22b09e65edae222ec902d6adb75585a0141b81a165f0fb0c9c0bc');
      final vm = RandomXVM.light(RandomXCache.create(seed));
      final pow = vm.hash(b.main.hashingBlob());
      expect(toHex(pow), '0906c001cc0900098fe1b62593f8ba52bd1ae2a0806096aa361a9f1702000000');
      expect(checkPow(pow, b.side.difficulty), isTrue);
    });
  }, skip: skip);
}
