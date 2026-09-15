import 'dart:io';
import 'dart:typed_data';

import 'package:cesc_core/cesc_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

List<BlockHeader> fixtureHeaders() {
  final b = File('test/fixtures/headers_after_checkpoint.bin').readAsBytesSync();
  return [for (var i = 0; i < b.length; i += 80) BlockHeader.parse(Uint8List.sublistView(b, i, i + 80))];
}

void main() {
  final p = Cryptoescudo.params;
  // Headers are validated against time "now"; the fixture is from 2026.
  const now = 1789400000;

  test('subsidy schedule (GetBlockValue)', () {
    const c = Cryptoescudo.coin;
    expect(Cryptoescudo.subsidy(0), 22000000 * c);
    expect(Cryptoescudo.subsidy(15), 22500000 * c);
    expect(Cryptoescudo.subsidy(30), 500000 * c);
    expect(Cryptoescudo.subsidy(31), 20 * c);
    expect(Cryptoescudo.subsidy(46), 600 * c);
    expect(Cryptoescudo.subsidy(164000), 200 * c);
    expect(Cryptoescudo.subsidy(1314045), 200 * c);
    expect(Cryptoescudo.subsidy(3202835), 20 * c); // matches the coinbase seen on chain
  });

  test('600 real headers after the checkpoint pass: links, scrypt PoW and the exact KGW nBits', () {
    final chain = HeaderChain(p, cryptoescudoCheckpoint());
    final headers = fixtureHeaders();
    expect(headers.length, 600);
    expect(chain.add(headers.sublist(0, 300), nowSeconds: now), 300);
    expect(chain.add(headers.sublist(300), nowSeconds: now), 300);
    expect(chain.tipHeight, cryptoescudoCheckpoint().height + 600);
    expect(chain.tipHash, headers.last.hash);
  });

  test('a wrong nBits, a weak PoW or a broken link is rejected', () {
    final headers = fixtureHeaders();
    BlockHeader tweak(BlockHeader h, {int? bits, int? nonce}) => BlockHeader(
        version: h.version, prevHash: h.prevHash, merkleRoot: h.merkleRoot, time: h.time, bits: bits ?? h.bits, nonce: nonce ?? h.nonce);
    final c1 = HeaderChain(p, cryptoescudoCheckpoint());
    expect(() => c1.add([tweak(headers[0], bits: headers[0].bits - 1)], nowSeconds: now), throwsA(isA<HeaderRejected>()));
    // A nonce that misses the target (checked by scanning a few).
    final pow = p.pow();
    var bad = headers[0].nonce + 1;
    while (CompactTarget.meets(pow.hash(tweak(headers[0], nonce: bad).serialize()), CompactTarget.decode(headers[0].bits))) {
      bad++;
    }
    expect(() => c1.add([tweak(headers[0], nonce: bad)], nowSeconds: now), throwsA(isA<HeaderRejected>()));
    expect(() => c1.add([headers[1]], nowSeconds: now), throwsA(isA<HeaderRejected>()));
  });

  test('a saved chain restores and keeps growing; locators start at the tip', () {
    final cp = cryptoescudoCheckpoint();
    final headers = fixtureHeaders();
    final chain = HeaderChain(p, cp)..add(headers.sublist(0, 400), nowSeconds: now);
    final restored = HeaderChain.restore(p, cp, chain.serialize())!;
    expect(restored.tipHeight, chain.tipHeight);
    expect(restored.tipWork, chain.tipWork);
    expect(restored.add(headers.sublist(400), nowSeconds: now), 200);
    final loc = restored.locator();
    expect(loc.first, headers.last.hash);
    expect(loc.length, lessThan(40));
  });

  test('a branch with more work replaces the tip; one with less does not', () {
    final cp = cryptoescudoCheckpoint();
    final headers = fixtureHeaders();
    final chain = HeaderChain(p, cp)..add(headers.sublist(0, 100), nowSeconds: now);
    // The same headers again are a branch with equal work: ignored.
    expect(chain.add(headers.sublist(50, 100), nowSeconds: now), 0);
    expect(chain.add(headers.sublist(50, 120), nowSeconds: now), 70);
    expect(chain.tipHeight, cryptoescudoCheckpoint().height + 120);
  });
}
