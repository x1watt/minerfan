import 'dart:convert';
import 'dart:typed_data';

import '../util/bytes.dart';
import '../util/reader.dart';

/// epee binary portable storage, the key-value format carried in every levin
/// body (contrib/epee/include/storages/portable_storage_base.h,
/// portable_storage_to_bin.h, portable_storage_from_bin.h).
///
/// Layout: 9-byte header (u32 signature A, u32 signature B, u8 version), then
/// the root section. A section is `varint(count)` followed by `count` entries
/// of `u8 name_len, name, u8 type, value`. The varint here is NOT the Monero
/// varint: its low two bits select a 1, 2, 4 or 8 byte little-endian integer
/// holding `value << 2`.
///
/// Dart model: a section is a `Map<String, Object?>` (insertion ordered).
/// Values are typed wrappers so the wire type survives a round trip:
/// [PsI64], [PsI32], [PsI16], [PsI8], [PsU64], [PsU32], [PsU16], [PsU8],
/// [PsDouble], [PsString], [PsBool], nested `Map` sections and [PsArray].
/// For encoding, a plain `Uint8List` is accepted as a string, a Dart `String`
/// as a UTF-8 string and a Dart `bool` as a bool; a plain `int` is rejected
/// because its wire width would be ambiguous.

const int psSignatureA = 0x01011101; // PORTABLE_STORAGE_SIGNATUREA
const int psSignatureB = 0x01020101; // PORTABLE_STORAGE_SIGNATUREB
const int psFormatVersion = 1; // PORTABLE_STORAGE_FORMAT_VER
const int psHeaderSize = 9;

// Entry type codes (portable_storage_base.h:52-66).
const int psTypeInt64 = 1;
const int psTypeInt32 = 2;
const int psTypeInt16 = 3;
const int psTypeInt8 = 4;
const int psTypeUint64 = 5;
const int psTypeUint32 = 6;
const int psTypeUint16 = 7;
const int psTypeUint8 = 8;
const int psTypeDouble = 9;
const int psTypeString = 10;
const int psTypeBool = 11;
const int psTypeObject = 12;
const int psTypeArray = 13;
const int psFlagArray = 0x80;

/// `MAX_STRING_LEN_POSSIBLE` (portable_storage_base.h:48).
const int psMaxStringLen = 2000000000;

/// Base of every typed scalar and array value.
sealed class PsValue {
  const PsValue();

  /// Wire type code without the array flag.
  int get type;
}

/// An integer scalar of a fixed wire width.
sealed class PsInt extends PsValue {
  /// For unsigned 64-bit values this holds the raw bit pattern (negative when
  /// the top bit is set).
  final int value;
  const PsInt(this.value);

  @override
  bool operator ==(Object other) => other is PsInt && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(type, value);

  @override
  String toString() => '$runtimeType($value)';
}

final class PsI64 extends PsInt {
  const PsI64(super.value);
  @override
  int get type => psTypeInt64;
}

final class PsI32 extends PsInt {
  const PsI32(super.value);
  @override
  int get type => psTypeInt32;
}

final class PsI16 extends PsInt {
  const PsI16(super.value);
  @override
  int get type => psTypeInt16;
}

final class PsI8 extends PsInt {
  const PsI8(super.value);
  @override
  int get type => psTypeInt8;
}

final class PsU64 extends PsInt {
  const PsU64(super.value);
  @override
  int get type => psTypeUint64;
}

final class PsU32 extends PsInt {
  const PsU32(super.value);
  @override
  int get type => psTypeUint32;
}

final class PsU16 extends PsInt {
  const PsU16(super.value);
  @override
  int get type => psTypeUint16;
}

final class PsU8 extends PsInt {
  const PsU8(super.value);
  @override
  int get type => psTypeUint8;
}

final class PsDouble extends PsValue {
  final double value;
  const PsDouble(this.value);
  @override
  int get type => psTypeDouble;

  @override
  bool operator ==(Object other) => other is PsDouble && (other.value == value || (other.value.isNaN && value.isNaN));

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PsDouble($value)';
}

final class PsBool extends PsValue {
  final bool value;
  const PsBool(this.value);
  @override
  int get type => psTypeBool;

  @override
  bool operator ==(Object other) => other is PsBool && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PsBool($value)';
}

/// A byte string (`std::string`, binary safe).
final class PsString extends PsValue {
  final Uint8List bytes;
  const PsString(this.bytes);
  PsString.utf8(String s) : bytes = Uint8List.fromList(utf8.encode(s));

  @override
  int get type => psTypeString;

  /// Lenient UTF-8 view, for text fields such as ping status.
  String get text => utf8.decode(bytes, allowMalformed: true);

  @override
  bool operator ==(Object other) => other is PsString && bytesEqual(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'PsString(${toHex(bytes)})';
}

/// A homogeneous array. [elementType] is a type code without the array flag.
/// Items use the same representation as scalars: [PsInt] subclasses for
/// integer elements, [PsString], [PsBool], [PsDouble], `Map` for objects and
/// [PsArray] for nested arrays. Plain Dart values (`int` for integer element
/// types, `Uint8List`, `bool`, `double`) are also accepted when encoding.
final class PsArray extends PsValue {
  final int elementType;
  final List<Object> items;
  const PsArray(this.elementType, this.items);

  @override
  int get type => psTypeArray;

  @override
  bool operator ==(Object other) {
    if (other is! PsArray || other.elementType != elementType || other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (!psValueEquals(items[i], other.items[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(elementType, items.length);

  @override
  String toString() => 'PsArray($elementType, $items)';
}

/// Deep equality for decoded values, including sections.
bool psValueEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !psValueEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is Uint8List && b is Uint8List) return bytesEqual(a, b);
  return a == b;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Serializes [root] with the storage header (`store_to_binary`,
/// contrib/epee/src/portable_storage.cpp:57). With [sortKeys] the entries of
/// every section are written in byte order of their names, as monerod does
/// (its sections are `std::map`), which makes the output byte-identical to
/// monerod for the same content.
Uint8List encodePortableStorage(Map<String, Object?> root, {bool sortKeys = false}) {
  final w = _PsWriter(sortKeys);
  final h = Uint8List(psHeaderSize);
  writeU32LE(h, 0, psSignatureA);
  writeU32LE(h, 4, psSignatureB);
  h[8] = psFormatVersion;
  w.b.add(h);
  w.section(root);
  return w.b.takeBytes();
}

/// Writes a portable storage varint (`pack_varint`, portable_storage_to_bin.h:51).
void writePsVarint(BytesBuilder b, int v) {
  if (v < 0) throw ArgumentError('negative portable storage varint');
  if (v <= 63) {
    b.addByte(v << 2);
  } else if (v <= 16383) {
    final x = (v << 2) | 1;
    b
      ..addByte(x & 0xff)
      ..addByte((x >> 8) & 0xff);
  } else if (v <= 1073741823) {
    final x = Uint8List(4);
    writeU32LE(x, 0, (v << 2) | 2);
    b.add(x);
  } else {
    if (v > 0x3fffffffffffffff) throw ArgumentError('portable storage varint too big: $v');
    final x = Uint8List(8);
    writeU64LE(x, 0, (v << 2) | 3);
    b.add(x);
  }
}

class _PsWriter {
  final bool sortKeys;
  final BytesBuilder b = BytesBuilder(copy: false);
  _PsWriter(this.sortKeys);

  void section(Map<String, Object?> s) {
    var entries = s.entries.where((e) => e.value != null).toList();
    if (sortKeys) {
      entries = entries..sort((x, y) => _compareBytes(utf8.encode(x.key), utf8.encode(y.key)));
    }
    writePsVarint(b, entries.length);
    for (final e in entries) {
      final name = utf8.encode(e.key);
      // portable_storage_to_bin.h:207: 0 < len < 255.
      if (name.isEmpty || name.length >= 255) {
        throw ArgumentError('bad portable storage entry name "${e.key}"');
      }
      b.addByte(name.length);
      b.add(name);
      entry(e.value!);
    }
  }

  void entry(Object v) {
    if (v is PsArray) {
      array(v);
      return;
    }
    final t = _typeOf(v);
    b.addByte(t);
    scalar(t, v);
  }

  void array(PsArray a) {
    final t = a.elementType;
    if (t < psTypeInt64 || t > psTypeArray) throw ArgumentError('bad array element type $t');
    b.addByte(t | psFlagArray);
    writePsVarint(b, a.items.length);
    for (final item in a.items) {
      if (t == psTypeArray) {
        if (item is! PsArray) throw ArgumentError('array of arrays needs PsArray items');
        array(item);
      } else {
        scalar(t, item);
      }
    }
  }

  /// Writes a value body of type [t] (no type byte).
  void scalar(int t, Object v) {
    switch (t) {
      case psTypeInt64:
      case psTypeUint64:
        final x = Uint8List(8);
        writeU64LE(x, 0, _intOf(v, t));
        b.add(x);
      case psTypeInt32:
      case psTypeUint32:
        final x = Uint8List(4);
        writeU32LE(x, 0, _intOf(v, t));
        b.add(x);
      case psTypeInt16:
      case psTypeUint16:
        final x = _intOf(v, t);
        b
          ..addByte(x & 0xff)
          ..addByte((x >> 8) & 0xff);
      case psTypeInt8:
      case psTypeUint8:
        b.addByte(_intOf(v, t) & 0xff);
      case psTypeDouble:
        final d = v is PsDouble ? v.value : (v is double ? v : throw ArgumentError('expected double, got $v'));
        final x = ByteData(8)..setFloat64(0, d, Endian.little);
        b.add(x.buffer.asUint8List());
      case psTypeBool:
        final x = v is PsBool ? v.value : (v is bool ? v : throw ArgumentError('expected bool, got $v'));
        b.addByte(x ? 1 : 0);
      case psTypeString:
        final Uint8List bytes;
        if (v is PsString) {
          bytes = v.bytes;
        } else if (v is Uint8List) {
          bytes = v;
        } else if (v is String) {
          bytes = Uint8List.fromList(utf8.encode(v));
        } else {
          throw ArgumentError('expected string, got $v');
        }
        writePsVarint(b, bytes.length);
        b.add(bytes);
      case psTypeObject:
        if (v is! Map<String, Object?>) throw ArgumentError('expected section, got $v');
        section(v);
      default:
        throw ArgumentError('cannot write type $t');
    }
  }

  static int _intOf(Object v, int t) {
    if (v is PsInt) {
      if (v.type != t) throw ArgumentError('integer width mismatch: ${v.runtimeType} in array of type $t');
      return v.value;
    }
    if (v is int) return v;
    throw ArgumentError('expected integer, got $v');
  }

  static int _typeOf(Object v) {
    if (v is PsValue) return v.type;
    if (v is Map<String, Object?>) return psTypeObject;
    if (v is Uint8List || v is String) return psTypeString;
    if (v is bool) return psTypeBool;
    if (v is double) return psTypeDouble;
    if (v is int) throw ArgumentError('plain int is ambiguous, wrap it in PsU64/PsU32/...');
    throw ArgumentError('unsupported portable storage value ${v.runtimeType}');
  }
}

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decoder limits. Defaults mirror `default_levin_limits`
/// (contrib/epee/include/storages/levin_abstract_invoke2.h:48): 8192
/// objects, 16384 fields, 16384 strings.
class PsLimits {
  final int maxObjects;
  final int maxFields;
  final int maxStrings;

  /// Nesting depth of sections and arrays. monerod counts every reader call
  /// against a limit of 100, which allows roughly 30 levels of sections.
  final int maxDepth;

  const PsLimits({this.maxObjects = 8192, this.maxFields = 16384, this.maxStrings = 16384, this.maxDepth = 32});

  static const PsLimits levin = PsLimits();
  static const PsLimits unlimited = PsLimits(
    maxObjects: 1 << 62,
    maxFields: 1 << 62,
    maxStrings: 1 << 62,
    maxDepth: 100,
  );
}

/// Parses a complete portable storage blob (header plus root section) into a
/// section map. Throws [FormatError] on malformed input. Bytes after the root
/// section are ignored, as monerod does (padded fragmented notifies rely on
/// this, levin_base.cpp make_fragmented_notify).
Map<String, Object?> decodePortableStorage(Uint8List data, {PsLimits limits = PsLimits.levin}) {
  if (data.length < psHeaderSize) throw FormatError('portable storage shorter than header');
  if (readU32LE(data, 0) != psSignatureA || readU32LE(data, 4) != psSignatureB) {
    throw FormatError('portable storage signature mismatch');
  }
  if (data[8] != psFormatVersion) throw FormatError('portable storage version ${data[8]}');
  // throwable_buffer_reader rejects an empty payload (from_bin.h:119).
  if (data.length == psHeaderSize) throw FormatError('empty portable storage payload');
  final r = _PsReader(ByteReader(data, psHeaderSize), limits);
  return r.section();
}

/// Reads a portable storage varint (`read_varint`, portable_storage_from_bin.h:235).
int readPsVarint(ByteReader r) {
  if (r.remaining < 1) throw FormatError('empty buffer, expected varint');
  final mark = r.data[r.pos] & 3;
  final int v;
  switch (mark) {
    case 0:
      v = r.byte();
    case 1:
      final x = r.bytes(2);
      v = x[0] | (x[1] << 8);
    case 2:
      v = r.u32();
    default:
      v = r.u64();
  }
  return v >>> 2;
}

class _PsReader {
  final ByteReader r;
  final PsLimits limits;
  int objects = 0;
  int fields = 0;
  int strings = 0;
  int depth = 0;

  _PsReader(this.r, this.limits);

  void _enter() {
    if (++depth > limits.maxDepth) throw FormatError('portable storage nesting too deep');
  }

  Map<String, Object?> section() {
    _enter();
    final count = readPsVarint(r);
    if (count > limits.maxFields - fields) throw FormatError('too many object fields');
    fields += count;
    final out = <String, Object?>{};
    for (var i = 0; i < count; i++) {
      final len = r.byte();
      if (len == 0) throw FormatError('section name is missing');
      final name = utf8.decode(r.bytes(len), allowMalformed: true);
      if (out.containsKey(name)) throw FormatError('duplicate key: $name');
      out[name] = entry();
    }
    depth--;
    return out;
  }

  Object entry() {
    final t = r.byte();
    if ((t & psFlagArray) != 0) return array(t & ~psFlagArray);
    if (t == psTypeArray) {
      // read_se<array_entry> (from_bin.h:287): a second type byte follows and
      // must carry the array flag.
      final t2 = r.byte();
      if ((t2 & psFlagArray) == 0) throw FormatError('wrong type sequences');
      return array(t2 & ~psFlagArray);
    }
    switch (t) {
      case psTypeString:
        if (strings >= limits.maxStrings) throw FormatError('too many strings');
        strings++;
        return PsString(string());
      case psTypeObject:
        if (objects >= limits.maxObjects) throw FormatError('too many objects');
        objects++;
        return section();
      default:
        return scalar(t);
    }
  }

  Uint8List string() {
    final len = readPsVarint(r);
    if (len >= psMaxStringLen) throw FormatError('string too long: $len');
    if (len > r.remaining) throw FormatError('string length $len exceeds remaining ${r.remaining}');
    return r.bytes(len);
  }

  Object scalar(int t) {
    switch (t) {
      case psTypeInt64:
        return PsI64(r.u64());
      case psTypeInt32:
        return PsI32(r.u32().toSigned(32));
      case psTypeInt16:
        final x = r.bytes(2);
        return PsI16((x[0] | (x[1] << 8)).toSigned(16));
      case psTypeInt8:
        return PsI8(r.byte().toSigned(8));
      case psTypeUint64:
        return PsU64(r.u64());
      case psTypeUint32:
        return PsU32(r.u32());
      case psTypeUint16:
        final x = r.bytes(2);
        return PsU16(x[0] | (x[1] << 8));
      case psTypeUint8:
        return PsU8(r.byte());
      case psTypeDouble:
        final x = r.bytes(8);
        return PsDouble(ByteData.sublistView(x).getFloat64(0, Endian.little));
      case psTypeBool:
        final x = r.byte();
        if (x > 1) throw FormatError('invalid bool value $x');
        return PsBool(x != 0);
      default:
        throw FormatError('unknown entry type $t');
    }
  }

  static int _minBytes(int t) => switch (t) {
    psTypeInt64 || psTypeUint64 || psTypeDouble => 8,
    psTypeInt32 || psTypeUint32 => 4,
    psTypeInt16 || psTypeUint16 || psTypeString => 2,
    _ => 1,
  };

  PsArray array(int t) {
    if (t < psTypeInt64 || t > psTypeArray) throw FormatError('unknown array type $t');
    _enter();
    final size = readPsVarint(r);
    // read_ae size sanity check (from_bin.h:189).
    if (size > r.remaining ~/ _minBytes(t)) throw FormatError('array size sanity check failed');
    if (t == psTypeObject) {
      if (size > limits.maxObjects - objects) throw FormatError('too many objects');
      objects += size;
    } else if (t == psTypeString) {
      if (size > limits.maxStrings - strings) throw FormatError('too many strings');
      strings += size;
    }
    final items = <Object>[];
    for (var i = 0; i < size; i++) {
      switch (t) {
        case psTypeObject:
          items.add(section());
        case psTypeString:
          items.add(PsString(string()));
        case psTypeArray:
          // monerod itself refuses to read arrays of arrays (from_bin.h:359);
          // accepted here for completeness of the codec.
          final t2 = r.byte();
          if ((t2 & psFlagArray) == 0) throw FormatError('wrong type sequences');
          items.add(array(t2 & ~psFlagArray));
        default:
          items.add(scalar(t));
      }
    }
    depth--;
    return PsArray(t, items);
  }
}

// ---------------------------------------------------------------------------
// Accessors (lenient like epee's convert_t) and POD blob helpers
// ---------------------------------------------------------------------------

/// Integer field of any integer wire type, or null when absent. Throws
/// [FormatError] when present with a non-integer type.
int? psInt(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return null;
  if (v is PsInt) return v.value;
  if (v is PsBool) return v.value ? 1 : 0;
  throw FormatError('field $key is not an integer');
}

/// Like [psInt] but required.
int psIntReq(Map<String, Object?> s, String key) => psInt(s, key) ?? (throw FormatError('missing field $key'));

bool? psBool(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return null;
  if (v is PsBool) return v.value;
  if (v is PsInt) return v.value != 0;
  throw FormatError('field $key is not a bool');
}

Uint8List? psBytes(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return null;
  if (v is PsString) return v.bytes;
  throw FormatError('field $key is not a string');
}

Map<String, Object?>? psSection(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return null;
  if (v is Map<String, Object?>) return v;
  throw FormatError('field $key is not a section');
}

/// Array of sections; absent means empty (epee omits empty containers).
List<Map<String, Object?>> psSectionList(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return const [];
  if (v is PsArray && v.elementType == psTypeObject) {
    return [for (final i in v.items) i as Map<String, Object?>];
  }
  // A single section where an array was expected is not accepted by epee.
  throw FormatError('field $key is not an array of sections');
}

/// Array of strings; absent means empty.
List<Uint8List> psBytesList(Map<String, Object?> s, String key) {
  final v = s[key];
  if (v == null) return const [];
  if (v is PsArray && v.elementType == psTypeString) {
    return [for (final i in v.items) (i as PsString).bytes];
  }
  throw FormatError('field $key is not an array of strings');
}

/// Fixed-size POD value stored as a blob (`KV_SERIALIZE_VAL_POD_AS_BLOB`),
/// for example a 32-byte hash. Absent returns null; a wrong length throws.
Uint8List? psPodBlob(Map<String, Object?> s, String key, int size) {
  final b = psBytes(s, key);
  if (b == null) return null;
  if (b.length != size) throw FormatError('field $key: blob size ${b.length}, expected $size');
  return b;
}

/// Packs 32-byte hashes into one blob (`KV_SERIALIZE_CONTAINER_POD_AS_BLOB`
/// of `crypto::hash`, keyvalue_serialization_overloads.h).
Uint8List packHashes(List<List<int>> hashes) {
  final out = Uint8List(32 * hashes.length);
  for (var i = 0; i < hashes.length; i++) {
    if (hashes[i].length != 32) throw ArgumentError('hash $i is not 32 bytes');
    out.setRange(32 * i, 32 * i + 32, hashes[i]);
  }
  return out;
}

/// Splits a blob of packed 32-byte hashes.
List<Uint8List> unpackHashes(Uint8List blob) {
  if (blob.length % 32 != 0) throw FormatError('hash blob size ${blob.length} is not a multiple of 32');
  return [for (var o = 0; o < blob.length; o += 32) Uint8List.fromList(Uint8List.sublistView(blob, o, o + 32))];
}

/// Packs u64 values little-endian into one blob.
Uint8List packU64s(List<int> values) {
  final out = Uint8List(8 * values.length);
  for (var i = 0; i < values.length; i++) {
    writeU64LE(out, 8 * i, values[i]);
  }
  return out;
}

/// Splits a blob of packed little-endian u64 values.
List<int> unpackU64s(Uint8List blob) {
  if (blob.length % 8 != 0) throw FormatError('u64 blob size ${blob.length} is not a multiple of 8');
  return [for (var o = 0; o < blob.length; o += 8) readU64LE(blob, o)];
}

/// Hash list field packed as a blob; absent means empty.
List<Uint8List> psHashList(Map<String, Object?> s, String key) {
  final b = psBytes(s, key);
  return b == null ? const [] : unpackHashes(b);
}

/// u64 list field packed as a blob; absent means empty.
List<int> psU64List(Map<String, Object?> s, String key) {
  final b = psBytes(s, key);
  return b == null ? const [] : unpackU64s(b);
}
