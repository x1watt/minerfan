import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto_core/crypto_core.dart';
import 'package:test/test.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  group('Argon2 (RFC 9106 section 5)', () {
    Uint8List run(int type) => Argon2.hash(
          password: List.filled(32, 1),
          salt: List.filled(16, 2),
          secret: List.filled(8, 3),
          associatedData: List.filled(12, 4),
          type: type,
          memoryKiB: 32,
          iterations: 3,
          lanes: 4,
        );

    test('Argon2d', () {
      expect(hex(run(Argon2.typeD)), '512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb');
    });
    test('Argon2i', () {
      expect(hex(run(Argon2.typeI)), 'c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8');
    });
    test('Argon2id', () {
      expect(hex(run(Argon2.typeId)), '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659');
    });
  });

  group('ChaCha20-Poly1305 (RFC 8439)', () {
    test('section 2.8.2 vector', () {
      final key = List.generate(32, (i) => 0x80 + i);
      final nonce = unhex('070000004041424344454647');
      final aad = unhex('50515253c0c1c2c3c4c5c6c7');
      final pt = utf8.encode(
          "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
      final sealed = ChaCha20Poly1305.seal(key, nonce, pt, aad);
      expect(
          hex(sealed),
          'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691');
      expect(ChaCha20Poly1305.open(key, nonce, sealed, aad), pt);
    });

    test('matches Python cryptography for empty and 200-byte messages', () {
      final key = List.filled(32, 7);
      final nonce = Uint8List(12);
      expect(hex(ChaCha20Poly1305.seal(key, nonce, const [])), 'bdfa57e7fdca1f5a8b889e0f9e8455e6');
      expect(
          hex(ChaCha20Poly1305.seal(key, nonce, List.generate(200, (i) => i))),
          '37852b0f646e02fac87b0e0bc56ced69a6fb06c705e9d32af2565ed2a7506a17fe2f8ab977d4cad4dbf98e49d75afc95c5d1d7ecdb83bf4c854d5a0a62bc261582ff25155c0ab773294be0511f3f3f91e87cafb5d494c01d7e67cf85c1cfe868a84ed702639b12c7bb0ef5ef21f6644f507af2a3aef1cdd7ef16c2f2a6bcfadbf759342818db46eaa1d3b685fefea463c0bbd154a18de6c8a5f78c21cf04e910476679daaa4e8ca9b9e8b25a281209ee3610d43415cd09de6bef539306ee3ae4a3f0b481216699aff0e87f0f04f66bd0d2ff95c75910a0fc');
    });

    test('rejects a changed byte', () {
      final key = List.filled(32, 9);
      final nonce = Uint8List(12);
      final sealed = ChaCha20Poly1305.seal(key, nonce, utf8.encode('secret'));
      sealed[2] ^= 1;
      expect(ChaCha20Poly1305.open(key, nonce, sealed), isNull);
    });
  });

  test('PasswordBox round trip and wrong password', () {
    final secret = utf8.encode('brand improve symbol strike');
    final box = PasswordBox.seal('hunter2', secret, memoryKiB: 256, iterations: 1);
    expect(PasswordBox.open('hunter2', box), secret);
    expect(PasswordBox.open('hunter3', box), isNull);
  });

  test('KeyBox round trip, wrong key, and boxes of the other kind', () {
    final key = List.generate(32, (i) => i);
    final secret = utf8.encode('brand improve symbol strike');
    final box = KeyBox.seal(key, secret);
    expect(KeyBox.open(key, box), secret);
    expect(KeyBox.open(List.filled(32, 0), box), isNull);
    expect(PasswordBox.open('x', box), isNull);
    expect(KeyBox.open(key, PasswordBox.seal('x', secret, memoryKiB: 64, iterations: 1)), isNull);
    // A fresh nonce every time.
    expect(KeyBox.seal(key, secret)['data'], isNot(box['data']));
  });
}
