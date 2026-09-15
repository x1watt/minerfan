import 'dart:typed_data';

import 'mac.dart';

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Bitcoin-style Base58 (big number, leading zero bytes as '1').
String base58Encode(List<int> data) {
  var zeros = 0;
  while (zeros < data.length && data[zeros] == 0) {
    zeros++;
  }
  var n = BigInt.zero;
  for (final b in data) {
    n = (n << 8) | BigInt.from(b);
  }
  final out = StringBuffer();
  final base = BigInt.from(58);
  final chars = <String>[];
  while (n > BigInt.zero) {
    chars.add(_alphabet[(n % base).toInt()]);
    n ~/= base;
  }
  for (var i = 0; i < zeros; i++) {
    out.write('1');
  }
  out.writeAll(chars.reversed);
  return out.toString();
}

Uint8List? base58Decode(String s) {
  var n = BigInt.zero;
  final base = BigInt.from(58);
  for (final c in s.split('')) {
    final v = _alphabet.indexOf(c);
    if (v < 0) return null;
    n = n * base + BigInt.from(v);
  }
  final bytes = <int>[];
  while (n > BigInt.zero) {
    bytes.add((n & BigInt.from(0xff)).toInt());
    n >>= 8;
  }
  var zeros = 0;
  while (zeros < s.length && s[zeros] == '1') {
    zeros++;
  }
  return Uint8List.fromList([...List.filled(zeros, 0), ...bytes.reversed]);
}

/// Base58 of `payload || first 4 bytes of sha256d(payload)`.
String base58CheckEncode(List<int> payload) {
  final sum = sha256d(payload);
  return base58Encode([...payload, ...sum.sublist(0, 4)]);
}

/// The payload, or null when the text is not valid Base58Check.
Uint8List? base58CheckDecode(String s) {
  final d = base58Decode(s);
  if (d == null || d.length < 5) return null;
  final payload = d.sublist(0, d.length - 4);
  final sum = sha256d(payload);
  for (var i = 0; i < 4; i++) {
    if (sum[i] != d[d.length - 4 + i]) return null;
  }
  return payload;
}
