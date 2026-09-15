import 'dart:typed_data';

import 'ripemd160.dart';
import 'sha256.dart';
import 'sha512.dart';

/// A one-shot hash function and its block size, for HMAC.
class HashFunction {
  final Uint8List Function(List<int>) hash;
  final int blockSize;
  final int outputSize;
  const HashFunction(this.hash, this.blockSize, this.outputSize);

  static const sha256 = HashFunction(Sha256.hash, 64, 32);
  static const sha512 = HashFunction(Sha512.hash, 128, 64);
}

/// HMAC (RFC 2104).
Uint8List hmac(HashFunction h, List<int> key, List<int> message) {
  var k = key.length > h.blockSize ? h.hash(key) : Uint8List.fromList(key);
  if (k.length < h.blockSize) k = Uint8List(h.blockSize)..setRange(0, k.length, k);
  final inner = Uint8List(h.blockSize + message.length);
  final outer = Uint8List(h.blockSize + h.outputSize);
  for (var i = 0; i < h.blockSize; i++) {
    inner[i] = k[i] ^ 0x36;
    outer[i] = k[i] ^ 0x5c;
  }
  inner.setRange(h.blockSize, inner.length, message);
  outer.setRange(h.blockSize, outer.length, h.hash(inner));
  return h.hash(outer);
}

Uint8List hmacSha256(List<int> key, List<int> message) => hmac(HashFunction.sha256, key, message);
Uint8List hmacSha512(List<int> key, List<int> message) => hmac(HashFunction.sha512, key, message);

/// PBKDF2 (RFC 8018) with an HMAC of [h].
Uint8List pbkdf2(HashFunction h, List<int> password, List<int> salt, int iterations, int length) {
  final out = Uint8List(length);
  final block = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
  var offset = 0;
  for (var i = 1; offset < length; i++) {
    ByteData.sublistView(block).setUint32(salt.length, i);
    var u = hmac(h, password, block);
    final t = Uint8List.fromList(u);
    for (var c = 1; c < iterations; c++) {
      u = hmac(h, password, u);
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    final n = length - offset < t.length ? length - offset : t.length;
    out.setRange(offset, offset + n, t);
    offset += n;
  }
  return out;
}

/// SHA-256 applied twice (block and transaction ids, checksums).
Uint8List sha256d(List<int> data) => Sha256.hash(Sha256.hash(data));

/// RIPEMD-160 of SHA-256 (public key and script hashes).
Uint8List hash160(List<int> data) => Ripemd160.hash(Sha256.hash(data));
