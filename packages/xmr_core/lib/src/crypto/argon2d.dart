import 'dart:typed_data';

import '../util/bytes.dart';
import 'package:crypto_core/crypto_core.dart';

/// Argon2d (RFC 9106, version 0x13) memory filling, as RandomX uses it to
/// build its cache: the filled block array *is* the output, no final hash.
///
/// [memory] holds `blocks * 128` 64-bit words. Only one lane is supported,
/// which is all RandomX needs.
class Argon2d {
  static const int blockWords = 128;
  static const int syncPoints = 4;
  static const int version = 0x13;

  static void fill(Int64List memory, List<int> password, List<int> salt,
      {required int passes, required int blocks}) {
    if (memory.length < blocks * blockWords) {
      throw ArgumentError('memory too small');
    }
    final h0 = _initialHash(password, salt, passes, blocks);
    final seed = Uint8List(72)..setRange(0, 64, h0);
    // First two blocks of the single lane.
    for (var i = 0; i < 2; i++) {
      writeU32LE(seed, 64, i);
      writeU32LE(seed, 68, 0);
      final block = _hPrime(seed, 1024);
      for (var w = 0; w < blockWords; w++) {
        memory[i * blockWords + w] = readU64LE(block, w * 8);
      }
    }

    final segmentLength = blocks ~/ syncPoints;
    final laneLength = segmentLength * syncPoints;
    final r = Int64List(blockWords), q = Int64List(blockWords);

    for (var pass = 0; pass < passes; pass++) {
      for (var slice = 0; slice < syncPoints; slice++) {
        final startIndex = (pass == 0 && slice == 0) ? 2 : 0;
        var cur = slice * segmentLength + startIndex;
        var prev = cur == 0 ? laneLength - 1 : cur - 1;
        for (var index = startIndex; index < segmentLength; index++, cur++, prev++) {
          if (cur % laneLength == 1) prev = cur - 1;
          final pseudoRand = memory[prev * blockWords];
          final j1 = pseudoRand & 0xffffffff;

          int refAreaSize;
          if (pass == 0) {
            refAreaSize = slice == 0 ? index - 1 : slice * segmentLength + index - 1;
          } else {
            refAreaSize = laneLength - segmentLength + index - 1;
          }
          var rel = (j1 * j1) >>> 32;
          rel = refAreaSize - 1 - ((refAreaSize * rel) >>> 32);
          final start = (pass != 0 && slice != syncPoints - 1) ? (slice + 1) * segmentLength : 0;
          final refIndex = (start + rel) % laneLength;

          _fillBlock(memory, prev * blockWords, refIndex * blockWords, cur * blockWords, pass != 0, r, q);
        }
      }
    }
  }

  static Uint8List _initialHash(List<int> password, List<int> salt, int passes, int blocks) {
    final b = Blake2b(64);
    final w = Uint8List(4);
    void u32(int v) {
      writeU32LE(w, 0, v);
      b.update(w);
    }

    u32(1); // lanes
    u32(0); // tag length (RandomX passes outlen = 0)
    u32(blocks); // memory in KiB
    u32(passes);
    u32(version);
    u32(0); // type: Argon2d
    u32(password.length);
    b.update(password);
    u32(salt.length);
    b.update(salt);
    u32(0); // secret
    u32(0); // associated data
    return b.digest();
  }

  /// Argon2's variable-length hash H' for outputs longer than 64 bytes.
  static Uint8List _hPrime(List<int> input, int outLen) {
    final out = Uint8List(outLen);
    final lenBytes = Uint8List(4);
    writeU32LE(lenBytes, 0, outLen);
    var v = (Blake2b(64)
          ..update(lenBytes)
          ..update(input))
        .digest();
    out.setRange(0, 32, v);
    var pos = 32;
    while (outLen - pos > 64) {
      v = Blake2b.hash(v, 64);
      out.setRange(pos, pos + 32, v);
      pos += 32;
    }
    final last = Blake2b.hash(v, outLen - pos);
    out.setRange(pos, outLen, last);
    return out;
  }

  static void _fillBlock(Int64List m, int prev, int ref, int next, bool withXor, Int64List r, Int64List q) {
    for (var i = 0; i < blockWords; i++) {
      final v = m[prev + i] ^ m[ref + i];
      r[i] = v;
      q[i] = v;
    }
    for (var i = 0; i < 8; i++) {
      final o = 16 * i;
      _round(q, o, o + 1, o + 2, o + 3, o + 4, o + 5, o + 6, o + 7, o + 8, o + 9, o + 10, o + 11, o + 12,
          o + 13, o + 14, o + 15);
    }
    for (var i = 0; i < 8; i++) {
      final o = 2 * i;
      _round(q, o, o + 1, o + 16, o + 17, o + 32, o + 33, o + 48, o + 49, o + 64, o + 65, o + 80, o + 81,
          o + 96, o + 97, o + 112, o + 113);
    }
    if (withXor) {
      for (var i = 0; i < blockWords; i++) {
        m[next + i] ^= q[i] ^ r[i];
      }
    } else {
      for (var i = 0; i < blockWords; i++) {
        m[next + i] = q[i] ^ r[i];
      }
    }
  }

  static void _round(Int64List v, int v0, int v1, int v2, int v3, int v4, int v5, int v6, int v7, int v8,
      int v9, int v10, int v11, int v12, int v13, int v14, int v15) {
    _g(v, v0, v4, v8, v12);
    _g(v, v1, v5, v9, v13);
    _g(v, v2, v6, v10, v14);
    _g(v, v3, v7, v11, v15);
    _g(v, v0, v5, v10, v15);
    _g(v, v1, v6, v11, v12);
    _g(v, v2, v7, v8, v13);
    _g(v, v3, v4, v9, v14);
  }

  static void _g(Int64List v, int ia, int ib, int ic, int id) {
    var a = v[ia], b = v[ib], c = v[ic], d = v[id];
    a = a + b + 2 * (a & 0xffffffff) * (b & 0xffffffff);
    d ^= a;
    d = (d >>> 32) | (d << 32);
    c = c + d + 2 * (c & 0xffffffff) * (d & 0xffffffff);
    b ^= c;
    b = (b >>> 24) | (b << 40);
    a = a + b + 2 * (a & 0xffffffff) * (b & 0xffffffff);
    d ^= a;
    d = (d >>> 16) | (d << 48);
    c = c + d + 2 * (c & 0xffffffff) * (d & 0xffffffff);
    b ^= c;
    b = (b >>> 63) | (b << 1);
    v[ia] = a;
    v[ib] = b;
    v[ic] = c;
    v[id] = d;
  }
}
