import 'dart:typed_data';

import 'varint.dart';

class FormatError implements Exception {
  final String message;
  FormatError(this.message);
  @override
  String toString() => 'FormatError: $message';
}

/// Sequential reader over a byte buffer; throws [FormatError] on overrun.
class ByteReader {
  final Uint8List data;
  int pos;
  final int end;

  ByteReader(this.data, [this.pos = 0, int? end]) : end = end ?? data.length;

  int get remaining => end - pos;
  bool get isDone => pos >= end;

  int byte() {
    if (pos >= end) throw FormatError('unexpected end of data');
    return data[pos++];
  }

  int varint() {
    final r = readVarint(data, pos);
    if (r == null || pos + r.$2 > end) throw FormatError('bad varint at $pos');
    pos += r.$2;
    return r.$1;
  }

  Uint8List bytes(int n) {
    if (n < 0 || pos + n > end) throw FormatError('need $n bytes at $pos');
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return Uint8List.fromList(out);
  }

  int u32() {
    final b = bytes(4);
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }

  int u64() {
    final b = bytes(8);
    var v = 0;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | b[i];
    }
    return v;
  }
}
