import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import 'package:pow_core/pow_core.dart';
import 'package:test/test.dart';
import 'package:utxo_core/utxo_core.dart';

/// The shared packages hold no coin constants: other Bitcoin-family chains
/// plug in with their own parameters. Genesis headers of Litecoin (scrypt)
/// and Bitcoin (sha256d) check with the same code the Cryptoescudo miner
/// uses.
void main() {
  test('Litecoin genesis: header hash and scrypt proof of work', () {
    final h = BlockHeader(
      version: 1,
      prevHash: Uint8List(32),
      merkleRoot: hashFromHex('97ddfbbae6be97fd6cdf3e7ca13232a3afff2353e29badfab7f73011edd4ced9'),
      time: 1317972665,
      bits: 0x1e0ffff0,
      nonce: 2084524493,
    );
    expect(hashToHex(h.hash), '12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2');
    expect(CompactTarget.meets(ScryptPow().hash(h.serialize()), CompactTarget.decode(h.bits)), isTrue);
    // One nonce off does not meet the target (about 1 in 4096 would).
    expect(CompactTarget.meets(ScryptPow().hash(h.withNonce(h.nonce + 1).serialize()), CompactTarget.decode(h.bits)),
        isFalse);
  });

  test('Bitcoin genesis: header hash and sha256d proof of work', () {
    final h = BlockHeader(
      version: 1,
      prevHash: Uint8List(32),
      merkleRoot: hashFromHex('4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b'),
      time: 1231006505,
      bits: 0x1d00ffff,
      nonce: 2083236893,
    );
    expect(hashToHex(h.hash), '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f');
    expect(CompactTarget.meets(Sha256dPow().hash(h.serialize()), CompactTarget.decode(h.bits)), isTrue);
  });

  test('addresses follow the chain parameters (Litecoin L... and Bitcoin 1...)', () {
    final key = Secp256k1.publicKey(BigInt.one).encode();
    final a = Address.fromPublicKey(key);
    final ltc = a.encode(_params(48));
    final btc = a.encode(_params(0));
    expect(btc, '1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH'); // key 1, compressed
    expect(ltc, startsWith('L'));
    expect(Address.parse(ltc, _params(48))!.encode(_params(0)), btc);
    expect(Address.parse(ltc, _params(0)), isNull);
  });
}

ChainParams _params(int version) => ChainParams(
      name: 'test',
      symbol: 'TST',
      magic: Uint8List(4),
      port: 1,
      dnsSeeds: const [],
      protocolVersion: 70002,
      userAgent: '/t/',
      pubKeyHashVersion: version,
      scriptHashVersion: 5,
      wifVersion: 128,
      bip44CoinType: 0,
      pow: Sha256dPow.new,
      retarget: KimotoGravityWell.fromSeconds(
          spacingSeconds: 150, pastSecondsMin: 3600, pastSecondsMax: 7200, powLimit: BigInt.one << 224),
      targetSpacingSeconds: 150,
      subsidy: (_) => 0,
      coinbaseMaturity: 100,
      minFeePerKb: 1000,
      blockVersion: 2,
      bip34: true,
    );
