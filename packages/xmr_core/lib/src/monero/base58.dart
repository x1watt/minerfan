import 'dart:typed_data';

/// Monero's block-wise base58: 8-byte blocks map to 11 characters, each block
/// a big-endian number (src/common/base58.cpp).

const String _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const List<int> _encodedBlockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11];
const int _fullBlockSize = 8;
const int _fullEncodedBlockSize = 11;

final Map<int, int> _reverse = {for (var i = 0; i < _alphabet.length; i++) _alphabet.codeUnitAt(i): i};

String base58Encode(List<int> data) {
  final sb = StringBuffer();
  for (var o = 0; o < data.length; o += _fullBlockSize) {
    final n = (data.length - o) < _fullBlockSize ? data.length - o : _fullBlockSize;
    var num = BigInt.zero;
    for (var i = 0; i < n; i++) {
      num = (num << 8) | BigInt.from(data[o + i]);
    }
    final size = _encodedBlockSizes[n];
    final chars = List<int>.filled(size, _alphabet.codeUnitAt(0));
    final base = BigInt.from(58);
    for (var i = size - 1; i >= 0 && num > BigInt.zero; i--) {
      chars[i] = _alphabet.codeUnitAt((num % base).toInt());
      num ~/= base;
    }
    sb.write(String.fromCharCodes(chars));
  }
  return sb.toString();
}

/// Decodes, or returns null on invalid characters or block sizes.
Uint8List? base58Decode(String s) {
  final out = BytesBuilder();
  for (var o = 0; o < s.length; o += _fullEncodedBlockSize) {
    final n = (s.length - o) < _fullEncodedBlockSize ? s.length - o : _fullEncodedBlockSize;
    final size = _encodedBlockSizes.indexOf(n);
    if (size < 0) return null;
    var num = BigInt.zero;
    for (var i = 0; i < n; i++) {
      final d = _reverse[s.codeUnitAt(o + i)];
      if (d == null) return null;
      num = num * BigInt.from(58) + BigInt.from(d);
    }
    if (num >> (8 * size) != BigInt.zero) return null;
    final block = Uint8List(size);
    for (var i = size - 1; i >= 0; i--) {
      block[i] = (num & BigInt.from(0xff)).toInt();
      num >>= 8;
    }
    out.add(block);
  }
  return out.takeBytes();
}
