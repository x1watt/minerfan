import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/catalog.dart';

void main() {
  final catalog = MiningCatalog.parse(File('assets/mining_catalog.json').readAsStringSync());

  test('every coin names a known algorithm, and ids are unique', () {
    for (final c in catalog.coins.values) {
      expect(catalog.algorithms, contains(c.algorithm), reason: c.symbol);
    }
    expect(catalog.algorithms.length, 20);
    expect(catalog.coins.length, 25);
  });

  test('Monero is RandomX on CPU and has the app miner and wallet', () {
    final a = catalog.algorithmOf('XMR')!;
    expect(a.id, 'randomx');
    expect(a.hardware, MinerHardware.cpu);
    expect(catalog.coins['XMR']!.minerId, 'monero');
    expect(catalog.coins['XMR']!.walletId, 'monero');
    expect(catalog.coins['XMR']!.price['kraken'], 'XMRUSD');
  });

  test('Cryptoescudo is scrypt, mined on the GPU on its small network, with the app miner and wallet', () {
    expect(catalog.algorithmOf('CESC')!.id, 'scrypt');
    expect(catalog.algorithmOf('CESC')!.hardware, MinerHardware.other); // scrypt in general: ASICs
    expect(catalog.hardwareOf('CESC'), MinerHardware.gpu);
    expect(catalog.hardwareOf('LTC'), MinerHardware.other);
    expect(catalog.coins['CESC']!.minerId, 'cryptoescudo');
    expect(catalog.coins['CESC']!.walletId, 'cryptoescudo');
    expect(catalog.coins['CESC']!.price, isEmpty);
  });

  test('every hardware class has algorithms', () {
    for (final h in MinerHardware.values) {
      expect(catalog.byHardware(h), isNotEmpty, reason: h.name);
    }
    expect(catalog.coinsFor('proof-of-space-time').map((c) => c.symbol), ['XCH']);
  });
}
