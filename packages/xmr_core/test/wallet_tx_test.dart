import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xmr_core/src/monero/block.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/transaction.dart';

/// Real mainnet blocks (tool/fetch_tx_fixtures.dart): every transaction,
/// full or pruned, parses and hashes to the id its block lists.
void main() {
  final blocks = (jsonDecode(File('test/fixtures/monero_blocks.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('full transactions parse and hash to the block ids', () {
    var n = 0;
    for (final b in blocks) {
      final hashes = (b['txHashes'] as List).cast<String>();
      final txs = (b['txs'] as List).cast<String>();
      for (var i = 0; i < txs.length; i++) {
        final tx = MoneroTx.parse(fromHex(txs[i]));
        expect(toHex(tx.hash), hashes[i]);
        expect(tx.rctType, RctTypes.bulletproofPlus);
        expect(tx.clsags!.length, tx.inputs.length);
        expect(tx.bulletproofsPlus!.single.l.length, greaterThanOrEqualTo(6));
        n++;
      }
    }
    expect(n, greaterThan(90));
  });

  test('pruned transactions hash with the given prunable hash', () {
    for (final b in blocks) {
      final hashes = (b['txHashes'] as List).cast<String>();
      final pruned = (b['pruned'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < pruned.length; i++) {
        final tx = MoneroTx.parse(fromHex(pruned[i]['blob'] as String),
            pruned: true, prunableHash: fromHex(pruned[i]['prunableHash'] as String));
        expect(toHex(tx.hash), hashes[i]);
        expect(tx.ecdhAmounts.length, tx.outputs.length);
      }
    }
  });

  test('coinbase transactions hash to the miner tx id', () {
    for (final b in blocks) {
      final block = MoneroBlock.parse(fromHex(b['block'] as String));
      final buf = BytesBuilder();
      block.minerTx.write(buf);
      final tx = MoneroTx.parse(buf.takeBytes());
      expect(tx.isCoinbase, isTrue);
      expect(tx.hash, block.minerTx.hash());
      expect(tx.txPublicKeys.$1, isNotNull);
    }
  });
}
