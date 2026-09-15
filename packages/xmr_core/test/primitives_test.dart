import 'dart:convert';

import 'package:test/test.dart';
import 'package:crypto_core/crypto_core.dart';
import 'package:xmr_core/src/crypto/keccak.dart';
import 'package:xmr_core/src/util/bytes.dart';
import 'package:xmr_core/src/util/u64.dart';

int u64(String decimal) => BigInt.parse(decimal).toSigned(64).toInt();

void main() {
  test('blake2b-512 abc', () {
    expect(
        toHex(Blake2b.hash(utf8.encode('abc'))),
        'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1'
        '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923');
  });

  test('blake2b multi-block boundaries match one-shot', () {
    final data = List<int>.generate(1000, (i) => i * 7 & 0xff);
    for (final n in [0, 1, 127, 128, 129, 255, 256, 257, 1000]) {
      final b = Blake2b(32);
      b.update(data.sublist(0, n ~/ 2));
      b.update(data.sublist(n ~/ 2, n));
      expect(toHex(b.digest()), toHex(Blake2b.hash(data.sublist(0, n), 32)), reason: 'n=$n');
    }
  });

  test('keccak-256 (original padding)', () {
    expect(toHex(Keccak.hash256([])), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
    expect(toHex(Keccak.hash256(utf8.encode('abc'))),
        '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
  });

  test('sha256', () {
    expect(toHex(Sha256.hash(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(toHex(Sha256.hash([])), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  test('mulh', () {
    expect(mulhU64(-1, -1), -2); // (2^64-1)^2 >> 64 = 2^64-2
    expect(mulhS64(-1, -1), 0);
    expect(mulhS64(-2, 3), -1);
  });

  test('randomx_reciprocal', () {
    expect(randomxReciprocal(3), u64('12297829382473034410'));
    expect(randomxReciprocal(13), u64('11351842506898185609'));
    expect(randomxReciprocal(33), u64('17887751829051686415'));
    expect(randomxReciprocal(65537), u64('18446462603027742720'));
    expect(randomxReciprocal(15000001), u64('10316166306300415204'));
    expect(randomxReciprocal(3845182035), u64('10302264209224146340'));
    expect(randomxReciprocal(0xffffffff), u64('9223372039002259456'));
  });
}
