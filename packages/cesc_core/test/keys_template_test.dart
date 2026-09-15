import 'dart:io';
import 'dart:typed_data';

import 'package:cesc_core/cesc_core.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

void main() {
  final p = Cryptoescudo.params;

  test('BIP44 coin type 111 matches the hdaddressgenerator Cryptoescudo vectors', () {
    // hdaddressgenerator 1.1.12, tests/settings.js and tests/coins/CESC.js.
    const mnemonic = 'brand improve symbol strike say focus ginger imitate ginger appear wheel brand swear relief zero';
    final root = HdKey.master(Bip39.seed(mnemonic));
    final k0 = root.derive("m/44'/111'/0'/0/0");
    final k1 = root.derive("m/44'/111'/0'/0/1");
    expect(toHex(k0.publicKey), '039234266bd9ef1736188dbe347b976a3a64e81af542e710808a0b9e46a8939072');
    expect(Address.fromPublicKey(k0.publicKey).encode(p), 'CSCiHCVaTb9181tjCvnrhmCxSjFruKX6YC');
    expect(WifKey(k0.key!).encode(p), 'Q9qFwgxWEJyHg9AbXY2LvE2pcACF6Q5SRp4GVM8BihnnvCFt5nts');
    expect(Address.fromPublicKey(k1.publicKey).encode(p), 'CGm2G16dXNZawf3RJyFDmySBy6xtAC6Rg3');
    expect(WifKey(k1.key!).encode(p), 'QCZQXzbHtHZuSmUCKDJoctypY9sa4BYmg5w5txoHL7PC1spE72ub');
    expect(WifKey.parse('QCZQXzbHtHZuSmUCKDJoctypY9sa4BYmg5w5txoHL7PC1spE72ub', p)!.key, k1.key);
  });

  test('addresses: parse, script, and chain checks', () {
    // The address paid by the coinbase of block 3202835 (explorer).
    final a = Address.parse('CcovbWmS78xdG8aHq9WPV4SX8AtvUGcDgw', p)!;
    expect(a.isScript, isFalse);
    expect(a.script.length, 25);
    expect(Address.fromScript(a.script), a);
    expect(a.encode(p), 'CcovbWmS78xdG8aHq9WPV4SX8AtvUGcDgw');
    // A Bitcoin address is not a Cryptoescudo one.
    expect(Address.parse('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2', p), isNull);
    expect(Address.parse('CcovbWmS78xdG8aHq9WPV4SX8AtvUGcDgx', p), isNull);
  });

  test('block template on the real chain: BIP34 height, 20 CESC, retarget bits, merkle root', () {
    final b = File('test/fixtures/headers_after_checkpoint.bin').readAsBytesSync();
    final headers = [for (var i = 0; i < b.length; i += 80) BlockHeader.parse(Uint8List.sublistView(b, i, i + 80))];
    final chain = HeaderChain(p, cryptoescudoCheckpoint())..add(headers, nowSeconds: 1789400000);
    final pay = Address.parse('CSCiHCVaTb9181tjCvnrhmCxSjFruKX6YC', p)!;
    final t = BlockTemplate.build(params: p, chain: chain, payTo: pay, extraNonce: 7, nowSeconds: 1789400000);
    expect(t.height, chain.tipHeight + 1);
    final script = t.coinbase.inputs.first.script;
    expect(script.sublist(0, 4), scriptNumPush(t.height));
    expect(toHex(scriptNumPush(3202835)), '0313df30'); // as in the real coinbase of 3202835
    expect(t.coinbase.outputs.single.value, 20 * Cryptoescudo.coin);
    expect(t.coinbase.outputs.single.script, pay.script);
    expect(t.header.merkleRoot, t.coinbase.txid);
    expect(t.header.bits, p.retarget.next(chain, chain.tipHeight));
    expect(t.header.prevHash, chain.tipHash);
    expect(t.header.version, 2);
    final block = t.withNonce(42);
    final parsed = Block.read(ByteReader(block.serialize()));
    expect(parsed.header.nonce, 42);
    expect(parsed.transactions.single.txid, t.coinbase.txid);
    expect(t.coinbase.isCoinbase, isTrue);
  });
}
