import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ec_ops.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/account.dart';
import 'package:xmr_core/src/wallet/outputs.dart';
import 'package:xmr_core/src/wallet/scanner.dart';
import 'package:xmr_core/src/wallet/transaction.dart';

MoneroTx _tx(List<NewOutput> outs, Uint8List extra, {int fee = 1000}) {
  final prefix = TxWriter.prefix(
      unlockTime: 0,
      inputs: [TxInToKey(0, [1, 2, 3], Uint8List(32))],
      outputs: [for (final o in outs) o.out],
      extra: extra);
  final base =
      TxWriter.base(fee: fee, ecdhAmounts: [for (final o in outs) o.ecdhAmount], outPk: [for (final o in outs) o.commitment]);
  return MoneroTx.parse(Uint8List.fromList([...prefix, ...base]), pruned: true, prunableHash: Uint8List(32));
}

void main() {
  final (me, _) = MoneroAccount.generate();
  final (other, _) = MoneroAccount.generate();

  test('finds outputs to the main address with amount, mask and key image', () {
    final r = randomScalar();
    final outs = [makeOutput(me.address, 123456789, 0, r), makeOutput(other.address, 5, 1, r)];
    final tx = _tx(outs, txExtra(txPublicKey(r, null), const []));
    final found = MoneroScanner(me).scan(tx, 'aa', 100);
    expect(found.length, 1);
    final o = found.single;
    expect(o.amount, 123456789);
    expect(o.index, 0);
    expect(bytesEqual(o.mask, outs[0].mask), isTrue);
    // The key image is x * Hp(P) with x the output's secret, and x G = P.
    final x = MoneroScanner(me).outputSecret(o);
    expect(bytesEqual(scalarMultBaseEncode(x), o.key), isTrue);
    expect(bytesEqual(o.keyImage!, generateKeyImage(o.key, x)), isTrue);
    expect(MoneroScanner(other).scan(tx, 'aa', 100).single.amount, 5);
  });

  test('subaddress outputs with additional keys', () {
    final r = randomScalar();
    final a1 = randomScalar(), a2 = randomScalar();
    final sub = me.subaddress(0, 7);
    final outs = [makeOutput(sub, 42, 0, r, additional: a1), makeOutput(other.address, 9, 1, r, additional: a2)];
    final tx = _tx(outs, txExtra(txPublicKey(r, null), [outs[0].additionalKey!, outs[1].additionalKey!]));
    final o = MoneroScanner(me).scan(tx, 'bb', 5).single;
    expect((o.amount, o.major, o.minor), (42, 0, 7));
    final x = MoneroScanner(me).outputSecret(o);
    expect(bytesEqual(scalarMultBaseEncode(x), o.key), isTrue);
    // A single subaddress destination without additional keys.
    final r2 = randomScalar();
    final solo = makeOutput(sub, 77, 0, r2);
    final tx2 = _tx([solo], txExtra(txPublicKey(r2, sub), const []));
    expect(MoneroScanner(me).scan(tx2, 'cc', 5).single.amount, 77);
  });

  test('a wrong encrypted amount does not open the commitment and is ignored', () {
    final r = randomScalar();
    final o = makeOutput(me.address, 1000, 0, r);
    final bad = NewOutput(o.out, Uint8List.fromList([...o.ecdhAmount]..[0] ^= 1), o.mask, o.commitment, o.amount, null);
    expect(MoneroScanner(me).scan(_tx([bad], txExtra(txPublicKey(r, null), const [])), 'dd', 1), isEmpty);
  });

  test('a real block has nothing for a new wallet (and is quick to scan)', () {
    final b = (jsonDecode(File('test/fixtures/monero_blocks.json').readAsStringSync()) as List).first as Map;
    final scanner = MoneroScanner(me);
    final sw = Stopwatch()..start();
    var outputs = 0;
    for (final t in (b['pruned'] as List).cast<Map<String, dynamic>>()) {
      final tx = MoneroTx.parse(fromHex(t['blob'] as String), pruned: true, prunableHash: fromHex(t['prunableHash'] as String));
      outputs += tx.outputs.length;
      expect(scanner.scan(tx, '', 0), isEmpty);
    }
    print('scanned ${(b['pruned'] as List).length} txs, $outputs outputs in ${sw.elapsedMilliseconds} ms');
  });
}

Uint8List scalarMultBaseEncode(Uint8List x) => scalarMultBase(x).encode();

