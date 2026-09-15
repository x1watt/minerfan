import 'dart:io';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ec_ops.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/crypto/monero_keys.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Monero's own crypto test vectors (tests/crypto/tests.txt, BSD-3), the
/// commands the wallet relies on.
void main() {
  final lines = File('test/fixtures/monero_crypto_tests.txt').readAsLinesSync();
  Iterable<List<String>> cases(String cmd) =>
      lines.where((l) => l.startsWith('$cmd ')).map((l) => l.split(' ').sublist(1));

  test('hash_to_point', () {
    for (final c in cases('hash_to_point')) {
      expect(toHex(geFromFeFromBytes(fromHex(c[0])).encode()), c[1]);
    }
  });

  test('biased_hash_to_ec', () {
    for (final c in cases('biased_hash_to_ec')) {
      expect(toHex(hashToEc(fromHex(c[0])).encode()), c[1]);
    }
  });

  test('generate_key_image', () {
    for (final c in cases('generate_key_image')) {
      expect(toHex(generateKeyImage(fromHex(c[0]), fromHex(c[1]))), c[2]);
    }
  });

  test('derive_secret_key and derive_public_key', () {
    for (final c in cases('derive_secret_key')) {
      final s = scAdd(derivationToScalar(fromHex(c[0]), int.parse(c[1])), fromHex(c[2]));
      expect(toHex(s), c[3]);
    }
    for (final c in cases('derive_public_key')) {
      final r = derivePublicKey(fromHex(c[0]), int.parse(c[1]), fromHex(c[2]));
      if (c[3] == 'false') {
        expect(r, isNull);
      } else {
        expect(toHex(r!), c[4]);
      }
    }
  });

  test('generate_key_derivation, derive_view_tag, hash_to_scalar', () {
    for (final c in cases('generate_key_derivation')) {
      final r = generateKeyDerivation(fromHex(c[0]), fromHex(c[1]));
      if (c[2] == 'false') {
        expect(r, isNull);
      } else {
        expect(toHex(r!), c[3]);
      }
    }
    for (final c in cases('derive_view_tag')) {
      expect(deriveViewTag(fromHex(c[0]), int.parse(c[1])).toRadixString(16).padLeft(2, '0'), c[2]);
    }
    for (final c in cases('hash_to_scalar')) {
      expect(toHex(hashToScalarBytes(c[0] == 'x' ? const [] : fromHex(c[0]))), c[1]); // x: empty
    }
  });

  test('secret_key_to_public_key and check_scalar', () {
    for (final c in cases('secret_key_to_public_key')) {
      final r = secretKeyToPublicKey(fromHex(c[0]));
      if (c[1] == 'false') {
        expect(r, isNull);
      } else {
        expect(toHex(r!), c[2]);
      }
    }
    for (final c in cases('check_scalar')) {
      expect(scCheck(fromHex(c[0])), c[1] == 'true');
    }
  });

  test('multiScalarMult matches separate multiplications', () {
    final pts = [for (var i = 0; i < 5; i++) scalarMultBase(randomScalar())];
    final sc = [for (var i = 0; i < 5; i++) randomScalar()];
    var sum = scalarMult(sc[0], pts[0]);
    for (var i = 1; i < 5; i++) {
      sum = pointSum(sum, scalarMult(sc[i], pts[i]));
    }
    expect(multiScalarMult(sc, pts).encode(), sum.encode());
    expect(pointIsIdentity(pointDiff(pts[0], pts[0])), isTrue);
  });
}
