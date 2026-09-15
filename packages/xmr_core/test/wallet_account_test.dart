import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/wallet/account.dart';

/// Vectors from monero-python 1.1.1 (Seed, OfflineWallet.get_address).
void main() {
  final vectors = (jsonDecode(File('test/fixtures/monero_seed_vectors.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('mnemonic <-> seed', () {
    for (final v in vectors) {
      expect(MoneroMnemonic.fromSeed(fromHex(v['seed'] as String)), v['phrase']);
      expect(toHex(MoneroMnemonic.toSeed(v['phrase'] as String)!), v['seed']);
    }
    final phrase = vectors[1]['phrase'] as String;
    // First three letters are enough; a wrong checksum word fails.
    expect(toHex(MoneroMnemonic.toSeed(phrase.split(' ').map((w) => w.length > 3 ? w.substring(0, 3) : w).join(' '))!),
        vectors[1]['seed']);
    final words = phrase.split(' ');
    words[24] = words[24] == 'abbey' ? 'zoom' : 'abbey';
    expect(MoneroMnemonic.toSeed(words.join(' ')), isNull);
  });

  test('keys, address and subaddresses', () {
    for (final v in vectors) {
      final a = MoneroAccount.fromSeed(fromHex(v['seed'] as String));
      expect(toHex(a.spendSecret!), v['spend']);
      expect(toHex(a.viewSecret), v['view']);
      expect(a.address.encode(), v['address']);
      expect(a.subaddress(0, 1).encode(), v['sub01']);
      expect(a.subaddress(1, 0).encode(), v['sub10']);
      expect(a.subaddress(2, 5).encode(), v['sub25']);
    }
  });

  test('view-only accounts check the view key', () {
    final v = vectors[2];
    final a = MoneroAccount.fromSeed(fromHex(v['seed'] as String));
    expect(MoneroAccount.viewOnly(a.address, a.viewSecret)!.canSpend, isFalse);
    expect(MoneroAccount.viewOnly(a.address, a.spendSecret!), isNull);
  });
}
