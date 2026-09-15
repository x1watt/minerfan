import 'dart:typed_data';

/// Little-endian writer with Bitcoin var-ints.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final ByteData _tmp = ByteData(8);

  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) => _put(2, () => _tmp.setUint16(0, v, Endian.little));
  void u16be(int v) => _put(2, () => _tmp.setUint16(0, v, Endian.big));
  void u32(int v) => _put(4, () => _tmp.setUint32(0, v & 0xffffffff, Endian.little));
  void i32(int v) => _put(4, () => _tmp.setInt32(0, v, Endian.little));
  void u64(int v) => _put(8, () => _tmp.setUint64(0, v, Endian.little));
  void i64(int v) => _put(8, () => _tmp.setInt64(0, v, Endian.little));

  void _put(int n, void Function() set) {
    set();
    _b.add(Uint8List.fromList(_tmp.buffer.asUint8List(0, n)));
  }

  void bytes(List<int> b) => _b.add(b is Uint8List ? b : Uint8List.fromList(b));

  void varInt(int v) {
    if (v < 0xfd) {
      u8(v);
    } else if (v <= 0xffff) {
      u8(0xfd);
      u16(v);
    } else if (v <= 0xffffffff) {
      u8(0xfe);
      u32(v);
    } else {
      u8(0xff);
      u64(v);
    }
  }

  void varBytes(List<int> b) {
    varInt(b.length);
    bytes(b);
  }

  void varString(String s) => varBytes(s.codeUnits);

  Uint8List take() => _b.takeBytes();
  int get length => _b.length;
}

/// Little-endian reader with Bitcoin var-ints. Throws [FormatException]
/// when the data ends early.
class ByteReader {
  final Uint8List data;
  final ByteData _bd;
  int pos;

  ByteReader(this.data, [this.pos = 0]) : _bd = ByteData.sublistView(data);

  int get remaining => data.length - pos;

  void _need(int n) {
    if (pos + n > data.length) throw const FormatException('truncated message');
  }

  int u8() {
    _need(1);
    return data[pos++];
  }

  int u16() {
    _need(2);
    final v = _bd.getUint16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int u16be() {
    _need(2);
    final v = _bd.getUint16(pos, Endian.big);
    pos += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = _bd.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int i32() {
    _need(4);
    final v = _bd.getInt32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    _need(8);
    final v = _bd.getUint64(pos, Endian.little);
    pos += 8;
    return v;
  }

  int i64() {
    _need(8);
    final v = _bd.getInt64(pos, Endian.little);
    pos += 8;
    return v;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return Uint8List.fromList(v);
  }

  int varInt() {
    final b = u8();
    if (b < 0xfd) return b;
    if (b == 0xfd) return u16();
    if (b == 0xfe) return u32();
    return u64();
  }

  Uint8List varBytes() => bytes(varInt());
  String varString() => String.fromCharCodes(varBytes());
}

String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

/// Hashes are shown reversed (big-endian display of the little-endian
/// number), as block explorers do.
String hashToHex(List<int> internal) => toHex(internal.reversed.toList());
Uint8List hashFromHex(String display) => Uint8List.fromList(fromHex(display).reversed.toList());

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
