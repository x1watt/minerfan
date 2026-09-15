import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import 'package:test/test.dart';

// Expected values from independent implementations (Python hashlib/OpenSSL
// and a separate Python secp256k1) and the published BIP32/BIP39 vectors.
String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
List<int> a(String s) => utf8.encode(s);

void main() {
  test('SHA-512', () {
    expect(hex(Sha512.hash(a('abc'))), 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f');
    expect(hex(Sha512.hash(a('a' * 1000))), '67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa634fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97');
  });

  test('RIPEMD-160', () {
    expect(hex(Ripemd160.hash(const [])), '9c1185a5c5e9fc54612808977ee8f548b2258d31');
    expect(hex(Ripemd160.hash(a('abc'))), '8eb208f7e05d987a9b044a8e98c6b087f15a0bfc');
    expect(hex(Ripemd160.hash(a('x' * 200))), '38c26b47a8a3ab2e3f3c7cba7f223e4938ff5442');
  });

  test('HMAC and PBKDF2', () {
    expect(hex(hmacSha256(a('key'), a('The quick brown fox jumps over the lazy dog'))), 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
    expect(hex(hmacSha512(a('k' * 200), a('msg'))), 'b5245971beb52a5a986812c4666a05c735bf5bb7aba32eae2192adad605df4112d6c285d1c46cf81ccb7ab8c2c3b7b3c6793216909b5add05223ed21f24cdb1e');
    expect(hex(pbkdf2(HashFunction.sha256, a('passwd'), a('salt'), 1, 64)), '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783');
    expect(hex(pbkdf2(HashFunction.sha512, a('password'), a('salt'), 2048, 64)), '91be23564f09fc855c82ce84a223ebe7d63d8b49d69372593a0d9ed39e143c83e1ab2f722a5ddb969feefc88403f7e2afe1afb8b2f0e6b20add0fb7b28368807');
  });

  test('scrypt (RFC 7914 vectors and the Litecoin-family PoW)', () {
    expect(hex(ScryptHasher(n: 16).hash(const [], const [], 64)), '77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906');
    expect(hex(ScryptHasher(n: 1024, r: 8, p: 16).hash(a('password'), a('NaCl'), 64)), 'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640');
    final header = List<int>.generate(80, (i) => i);
    final h = ScryptHasher();
    expect(hex(scryptPow(header, h)), 'bc540a1a801df96e493005c71e010e2d387607fbf0fec416fd3c2645aa1ba9d2');
    expect(hex(scryptPow(header, h)), 'bc540a1a801df96e493005c71e010e2d387607fbf0fec416fd3c2645aa1ba9d2'); // scratch reuse
  });

  test('Base58Check round trip and checksum', () {
    final payload = [28, ...List<int>.generate(20, (i) => i * 7)];
    final s = base58CheckEncode(payload);
    expect(s.startsWith('C'), isTrue);
    expect(base58CheckDecode(s), payload);
    expect(base58CheckDecode('${s.substring(0, s.length - 1)}1'), isNull);
    expect(base58Encode([0, 0, 1]), '112');
  });

  test('secp256k1 keys and RFC 6979 ECDSA', () {
    expect(hex(Secp256k1.publicKey(BigInt.one).encode()), '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798');
    final h1 = Sha256.hash(a('Satoshi Nakamoto'));
    final (r1, s1) = Secp256k1.sign(BigInt.one, h1);
    expect(r1.toRadixString(16).padLeft(64, '0'), '934b1ea10a4b3c1757e2b0c017d0b6143ce3c9a7e6a4a49860d7a6ab210ee3d8');
    expect(s1.toRadixString(16).padLeft(64, '0'), '2442ce9d2b916064108014783e923ec36b49743e2ffa1c4496f01a512aafd9e5');
    expect(Secp256k1.verify(Secp256k1.publicKey(BigInt.one), h1, r1, s1), isTrue);
    expect(Secp256k1.verify(Secp256k1.publicKey(BigInt.two), h1, r1, s1), isFalse);
    final kmax = Secp256k1.n - BigInt.one;
    final h2 = Sha256.hash(a('Equations are more important to me, because politics is for the present, but an equation is something for eternity.'));
    final (r2, s2) = Secp256k1.sign(kmax, h2);
    expect(r2.toRadixString(16).padLeft(64, '0'), '54c4a33c6423d689378f160a7ff8b61330444abb58fb470f96ea16d99d4a2fed');
    expect(s2.toRadixString(16).padLeft(64, '0'), '07082304410efa6b2943111b6a4e0aaa7b7db55a07e9861d1fb3cb1f421044a5');
    final der = Secp256k1.der(r1, s1);
    expect(der[0], 0x30);
    expect(der.length, der[1] + 2);
    final pub = Secp256k1.publicKey(BigInt.from(123456789));
    expect(EcPoint.decode(pub.encode()), pub);
    expect(EcPoint.decode(pub.encode(compressed: false)), pub);
  });

  test('BIP39 mnemonic and seed', () {
    const m = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    expect(Bip39.fromEntropy(List.filled(16, 0)), m);
    expect(Bip39.valid(m), isTrue);
    expect(Bip39.valid(m.replaceFirst('about', 'abandon')), isFalse);
    expect(hex(Bip39.seed(m, passphrase: 'TREZOR')), 'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04');
    final g = Bip39.generate(words: 24);
    expect(g.split(' ').length, 24);
    expect(Bip39.valid(g), isTrue);
  });

  test('BIP32 (test vector 1)', () {
    final m = HdKey.master(unhex('000102030405060708090a0b0c0d0e0f'));
    expect(m.key!.toRadixString(16).padLeft(64, '0'), 'e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35');
    expect(hex(m.chainCode), '873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508');
    expect(m.serialize(), 'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi');
    expect(m.neutered().serialize(), 'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8');
    final c = m.derive("m/0'/1");
    expect(c.key!.toRadixString(16).padLeft(64, '0'), '3c6cb8d0f6a264c91ea8b5030fadaa8e538b020f0a387421a12de9319dc93368');
    expect(hex(c.chainCode), '2a7857631386ba23dacac34180dd1983734e444fdbf774041578e9b6adb37c19');
    // Public derivation of a non-hardened child matches the private one.
    final pubChild = m.derive("m/0'").neutered().child(1);
    expect(pubChild.publicPoint, c.publicPoint);
    // Serialized keys read back.
    expect(HdKey.parse(c.serialize())!.serialize(), c.serialize());
    expect(HdKey.parse(c.neutered().serialize())!.serialize(), c.neutered().serialize());
    expect(HdKey.parse('xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet9'), isNull);
  });
}
