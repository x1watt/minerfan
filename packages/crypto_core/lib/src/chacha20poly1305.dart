import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'argon2.dart';

/// ChaCha20-Poly1305 AEAD (RFC 8439).
abstract final class ChaCha20Poly1305 {
  static Uint8List _block(Uint32List key, int counter, Uint32List nonce) {
    final s = Uint32List(16)
      ..[0] = 0x61707865
      ..[1] = 0x3320646e
      ..[2] = 0x79622d32
      ..[3] = 0x6b206574;
    s.setRange(4, 12, key);
    s[12] = counter;
    s.setRange(13, 16, nonce);
    final x = Uint32List.fromList(s);
    int rotl(int v, int n) => ((v << n) | (v >>> (32 - n))) & 0xffffffff;
    void qr(int a, int b, int c, int d) {
      x[a] = x[a] + x[b];
      x[d] = rotl(x[d] ^ x[a], 16);
      x[c] = x[c] + x[d];
      x[b] = rotl(x[b] ^ x[c], 12);
      x[a] = x[a] + x[b];
      x[d] = rotl(x[d] ^ x[a], 8);
      x[c] = x[c] + x[d];
      x[b] = rotl(x[b] ^ x[c], 7);
    }

    for (var i = 0; i < 10; i++) {
      qr(0, 4, 8, 12);
      qr(1, 5, 9, 13);
      qr(2, 6, 10, 14);
      qr(3, 7, 11, 15);
      qr(0, 5, 10, 15);
      qr(1, 6, 11, 12);
      qr(2, 7, 8, 13);
      qr(3, 4, 9, 14);
    }
    for (var i = 0; i < 16; i++) {
      x[i] = x[i] + s[i];
    }
    final out = ByteData(64);
    for (var i = 0; i < 16; i++) {
      out.setUint32(i * 4, x[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static Uint32List _words(List<int> b) {
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return Uint32List.fromList([for (var i = 0; i < b.length ~/ 4; i++) d.getUint32(i * 4, Endian.little)]);
  }

  static Uint8List _xor(Uint32List key, Uint32List nonce, int counter, List<int> data) {
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 64, counter++) {
      final ks = _block(key, counter, nonce);
      for (var i = 0; i < 64 && off + i < data.length; i++) {
        out[off + i] = data[off + i] ^ ks[i];
      }
    }
    return out;
  }

  static Uint8List _poly1305(List<int> key, List<int> msg) {
    final r = _le(key.sublist(0, 16)) & BigInt.parse('0ffffffc0ffffffc0ffffffc0fffffff', radix: 16);
    final s = _le(key.sublist(16, 32));
    final p = (BigInt.one << 130) - BigInt.from(5);
    var acc = BigInt.zero;
    for (var i = 0; i < msg.length; i += 16) {
      final end = min(i + 16, msg.length);
      final n = _le([...msg.sublist(i, end), 1]);
      acc = ((acc + n) * r) % p;
    }
    acc = (acc + s) & ((BigInt.one << 128) - BigInt.one);
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = (acc >> (8 * i) & BigInt.from(0xff)).toInt();
    }
    return out;
  }

  static BigInt _le(List<int> b) {
    var v = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(b[i]);
    }
    return v;
  }

  static Uint8List _tag(Uint32List key, Uint32List nonce, List<int> aad, List<int> ct) {
    final otk = _block(key, 0, nonce).sublist(0, 32);
    int pad(int n) => (16 - n % 16) % 16;
    final lens = ByteData(16)
      ..setUint64(0, aad.length, Endian.little)
      ..setUint64(8, ct.length, Endian.little);
    final mac = [
      ...aad,
      ...List.filled(pad(aad.length), 0),
      ...ct,
      ...List.filled(pad(ct.length), 0),
      ...lens.buffer.asUint8List(),
    ];
    return _poly1305(otk, mac);
  }

  /// Ciphertext followed by the 16-byte tag.
  static Uint8List seal(List<int> key, List<int> nonce12, List<int> plaintext, [List<int> aad = const []]) {
    final k = _words(key), n = _words(nonce12);
    final ct = _xor(k, n, 1, plaintext);
    return Uint8List.fromList([...ct, ..._tag(k, n, aad, ct)]);
  }

  /// The plaintext, or null when the tag does not verify.
  static Uint8List? open(List<int> key, List<int> nonce12, List<int> sealed, [List<int> aad = const []]) {
    if (sealed.length < 16) return null;
    final k = _words(key), n = _words(nonce12);
    final ct = sealed.sublist(0, sealed.length - 16);
    final want = _tag(k, n, aad, ct);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= want[i] ^ sealed[sealed.length - 16 + i];
    }
    if (diff != 0) return null;
    return _xor(k, n, 1, ct);
  }
}

/// A secret sealed with a random 32-byte key kept elsewhere (for example a
/// device key file): ChaCha20-Poly1305 with a random nonce, no key
/// derivation. [PasswordBox.open] and [KeyBox.open] tell their boxes apart
/// by `kdf`.
abstract final class KeyBox {
  static const kdf = 'key';

  static Map<String, Object?> seal(List<int> key, List<int> secret) {
    if (key.length != 32) throw ArgumentError('the key must be 32 bytes');
    final rnd = Random.secure();
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256));
    return {
      'kdf': kdf,
      'cipher': 'chacha20-poly1305',
      'nonce': PasswordBox._hex(nonce),
      'data': PasswordBox._hex(ChaCha20Poly1305.seal(key, nonce, secret)),
    };
  }

  /// The secret, or null for a wrong key, a password box or damaged data.
  static Uint8List? open(List<int> key, Map<String, Object?> box) {
    if (box['kdf'] != kdf || key.length != 32) return null;
    try {
      return ChaCha20Poly1305.open(
        key,
        PasswordBox._unhex(box['nonce']! as String),
        PasswordBox._unhex(box['data']! as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A secret sealed with a password: Argon2id (random salt) derives the
/// key, ChaCha20-Poly1305 encrypts and authenticates. Each seal has a new
/// salt, so each key is used once.
abstract final class PasswordBox {
  static const _memoryKiB = 64 * 1024;
  static const _iterations = 3;

  static Map<String, Object?> seal(
    String password,
    List<int> secret, {
    int memoryKiB = _memoryKiB,
    int iterations = _iterations,
  }) {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final key = Argon2.hash(password: utf8.encode(password), salt: salt, memoryKiB: memoryKiB, iterations: iterations);
    final nonce = Uint8List(12); // the key is fresh for every seal
    return {
      'kdf': 'argon2id',
      'memoryKiB': memoryKiB,
      'iterations': iterations,
      'salt': _hex(salt),
      'cipher': 'chacha20-poly1305',
      'data': _hex(ChaCha20Poly1305.seal(key, nonce, secret)),
    };
  }

  /// The secret, or null for a wrong password or damaged data.
  static Uint8List? open(String password, Map<String, Object?> box) {
    if (box['kdf'] != 'argon2id') return null;
    try {
      final key = Argon2.hash(
        password: utf8.encode(password),
        salt: _unhex(box['salt']! as String),
        memoryKiB: box['memoryKiB']! as int,
        iterations: box['iterations']! as int,
      );
      return ChaCha20Poly1305.open(key, Uint8List(12), _unhex(box['data']! as String));
    } catch (_) {
      return null;
    }
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List _unhex(String s) =>
      Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}
