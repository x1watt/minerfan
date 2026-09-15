import 'dart:io';

import 'package:test/test.dart';
import 'package:xmr_core/src/crypto/ed25519.dart';
import 'package:xmr_core/src/crypto/monero_keys.dart';
import 'package:xmr_core/src/util/bytes.dart';

/// Vectors: monero-project/monero tests/crypto/tests.txt (BSD-3-Clause),
/// commit c93af366c3125e0ebd59ee4687a85943bb3ec708.
void main() {
  final lines = File('test/data/monero_crypto_tests.txt').readAsLinesSync();
  Iterable<List<String>> cases(String name) =>
      lines.where((l) => l.startsWith('$name ')).map((l) => l.split(' ').sublist(1));

  test('check_scalar', () {
    for (final c in cases('check_scalar')) {
      expect(scCheck(fromHex(c[0])), c[1] == 'true', reason: c[0]);
    }
  });

  test('check_key', () {
    for (final c in cases('check_key')) {
      expect(checkKey(fromHex(c[0])), c[1] == 'true', reason: c[0]);
    }
  });

  test('hash_to_scalar', () {
    for (final c in cases('hash_to_scalar')) {
      final input = c[0] == 'x' ? <int>[] : fromHex(c[0]);
      expect(toHex(hashToScalar(input)), c[1], reason: c[0]);
    }
  });

  test('secret_key_to_public_key', () {
    for (final c in cases('secret_key_to_public_key')) {
      final pub = secretKeyToPublicKey(fromHex(c[0]));
      expect(pub != null, c[1] == 'true', reason: c[0]);
      if (pub != null) expect(toHex(pub), c[2], reason: c[0]);
    }
  });

  test('generate_key_derivation', () {
    for (final c in cases('generate_key_derivation')) {
      final d = generateKeyDerivation(fromHex(c[0]), fromHex(c[1]));
      expect(d != null, c[2] == 'true', reason: c.join(' '));
      if (d != null) expect(toHex(d), c[3], reason: c.join(' '));
    }
  });

  test('derive_public_key', () {
    for (final c in cases('derive_public_key')) {
      final p = derivePublicKey(fromHex(c[0]), int.parse(c[1]), fromHex(c[2]));
      expect(p != null, c[3] == 'true', reason: c.join(' '));
      if (p != null) expect(toHex(p), c[4], reason: c.join(' '));
    }
  });

  test('derive_view_tag', () {
    for (final c in cases('derive_view_tag')) {
      expect(deriveViewTag(fromHex(c[0]), int.parse(c[1])), int.parse(c[2], radix: 16), reason: c.join(' '));
    }
  });
}
