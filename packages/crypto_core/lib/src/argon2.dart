import 'dart:typed_data';

import 'blake2b.dart';

/// Argon2 (RFC 9106, version 0x13): Argon2d, Argon2i and Argon2id with any
/// number of lanes, computed one lane after another. For password hashing
/// and key derivation (wallet files); RandomX uses its own Argon2d fill.
abstract final class Argon2 {
  static const typeD = 0, typeI = 1, typeId = 2;
  static const _blockWords = 128;
  static const _syncPoints = 4;

  static Uint8List hash({
    required List<int> password,
    required List<int> salt,
    int type = typeId,
    int memoryKiB = 64 * 1024,
    int iterations = 3,
    int lanes = 1,
    int tagLength = 32,
    List<int> secret = const [],
    List<int> associatedData = const [],
  }) {
    if (memoryKiB < 8 * lanes) throw ArgumentError('memory must be at least 8 KiB per lane');
    final h0 = _initialHash(password, salt, secret, associatedData, type, memoryKiB, iterations, lanes, tagLength);
    final segment = memoryKiB ~/ (_syncPoints * lanes);
    final laneLen = segment * _syncPoints;
    final blocks = laneLen * lanes;
    final m = Int64List(blocks * _blockWords);

    // First two blocks of each lane.
    final seed = Uint8List(72)..setRange(0, 64, h0);
    final sd = ByteData.sublistView(seed);
    for (var l = 0; l < lanes; l++) {
      for (var i = 0; i < 2; i++) {
        sd.setUint32(64, i, Endian.little);
        sd.setUint32(68, l, Endian.little);
        final b = ByteData.sublistView(_hPrime(seed, 1024));
        for (var w = 0; w < _blockWords; w++) {
          m[(l * laneLen + i) * _blockWords + w] = b.getInt64(w * 8, Endian.little);
        }
      }
    }

    final r = Int64List(_blockWords), q = Int64List(_blockWords);
    final zero = Int64List(_blockWords);
    final input = Int64List(_blockWords);
    final addr = Int64List(_blockWords);
    final tmp = Int64List(_blockWords);

    for (var pass = 0; pass < iterations; pass++) {
      for (var slice = 0; slice < _syncPoints; slice++) {
        for (var lane = 0; lane < lanes; lane++) {
          final independent = type == typeI || (type == typeId && pass == 0 && slice < 2);
          var start = 0;
          if (independent) {
            input.fillRange(0, _blockWords, 0);
            input[0] = pass;
            input[1] = lane;
            input[2] = slice;
            input[3] = blocks;
            input[4] = iterations;
            input[5] = type;
          }
          if (pass == 0 && slice == 0) {
            start = 2;
            if (independent) _nextAddresses(input, addr, zero, tmp, r, q);
          }
          var cur = lane * laneLen + slice * segment + start;
          var prev = cur % laneLen == 0 ? cur + laneLen - 1 : cur - 1;
          for (var i = start; i < segment; i++, cur++, prev++) {
            if (cur % laneLen == 1) prev = cur - 1;
            int pseudo;
            if (independent) {
              if (i % _blockWords == 0) _nextAddresses(input, addr, zero, tmp, r, q);
              pseudo = addr[i % _blockWords];
            } else {
              pseudo = m[prev * _blockWords];
            }
            final j1 = pseudo & 0xffffffff;
            final j2 = (pseudo >>> 32) & 0xffffffff;
            final refLane = (pass == 0 && slice == 0) ? lane : j2 % lanes;
            final same = refLane == lane;
            int area;
            if (pass == 0) {
              area = same ? slice * segment + i - 1 : slice * segment + (i == 0 ? -1 : 0);
            } else {
              area = same ? laneLen - segment + i - 1 : laneLen - segment + (i == 0 ? -1 : 0);
            }
            var rel = (j1 * j1) >>> 32;
            rel = area - 1 - ((area * rel) >>> 32);
            final startPos = pass != 0 && slice != _syncPoints - 1 ? (slice + 1) * segment : 0;
            final refIndex = (startPos + rel) % laneLen;
            _g(m, prev * _blockWords, m, (refLane * laneLen + refIndex) * _blockWords, m, cur * _blockWords, pass != 0, r, q);
          }
        }
      }
    }

    // Final block: XOR of the last block of every lane.
    final fin = Int64List(_blockWords);
    for (var l = 0; l < lanes; l++) {
      final off = (l * laneLen + laneLen - 1) * _blockWords;
      for (var w = 0; w < _blockWords; w++) {
        fin[w] ^= m[off + w];
      }
    }
    final fb = ByteData(1024);
    for (var w = 0; w < _blockWords; w++) {
      fb.setInt64(w * 8, fin[w], Endian.little);
    }
    return _hPrime(fb.buffer.asUint8List(), tagLength);
  }

  static void _nextAddresses(Int64List input, Int64List addr, Int64List zero, Int64List tmp, Int64List r, Int64List q) {
    input[6]++;
    _g(zero, 0, input, 0, tmp, 0, false, r, q);
    _g(zero, 0, tmp, 0, addr, 0, false, r, q);
  }

  /// Compression G(X, Y) written to (or XORed into) [out] at [outOff].
  static void _g(Int64List x, int xOff, Int64List y, int yOff, Int64List out, int outOff, bool withXor, Int64List r,
      Int64List q) {
    for (var i = 0; i < _blockWords; i++) {
      final v = x[xOff + i] ^ y[yOff + i];
      r[i] = v;
      q[i] = v;
    }
    for (var i = 0; i < 8; i++) {
      final o = 16 * i;
      _round(q, o, o + 1, o + 2, o + 3, o + 4, o + 5, o + 6, o + 7, o + 8, o + 9, o + 10, o + 11, o + 12, o + 13, o + 14, o + 15);
    }
    for (var i = 0; i < 8; i++) {
      final o = 2 * i;
      _round(q, o, o + 1, o + 16, o + 17, o + 32, o + 33, o + 48, o + 49, o + 64, o + 65, o + 80, o + 81, o + 96, o + 97,
          o + 112, o + 113);
    }
    for (var i = 0; i < _blockWords; i++) {
      final v = q[i] ^ r[i];
      out[outOff + i] = withXor ? out[outOff + i] ^ v : v;
    }
  }

  static void _round(Int64List v, int v0, int v1, int v2, int v3, int v4, int v5, int v6, int v7, int v8, int v9, int v10,
      int v11, int v12, int v13, int v14, int v15) {
    _gb(v, v0, v4, v8, v12);
    _gb(v, v1, v5, v9, v13);
    _gb(v, v2, v6, v10, v14);
    _gb(v, v3, v7, v11, v15);
    _gb(v, v0, v5, v10, v15);
    _gb(v, v1, v6, v11, v12);
    _gb(v, v2, v7, v8, v13);
    _gb(v, v3, v4, v9, v14);
  }

  static void _gb(Int64List v, int ia, int ib, int ic, int id) {
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

  static Uint8List _initialHash(List<int> p, List<int> s, List<int> k, List<int> x, int type, int m, int t, int lanes, int tag) {
    final b = Blake2b(64);
    final w = ByteData(4);
    void u32(int v) {
      w.setUint32(0, v, Endian.little);
      b.update(w.buffer.asUint8List());
    }

    u32(lanes);
    u32(tag);
    u32(m);
    u32(t);
    u32(0x13);
    u32(type);
    u32(p.length);
    b.update(p);
    u32(s.length);
    b.update(s);
    u32(k.length);
    b.update(k);
    u32(x.length);
    b.update(x);
    return b.digest();
  }

  static Uint8List _hPrime(List<int> input, int outLen) {
    final len = ByteData(4)..setUint32(0, outLen, Endian.little);
    if (outLen <= 64) {
      return (Blake2b(outLen)
            ..update(len.buffer.asUint8List())
            ..update(input))
          .digest();
    }
    final out = Uint8List(outLen);
    var v = (Blake2b(64)
          ..update(len.buffer.asUint8List())
          ..update(input))
        .digest();
    out.setRange(0, 32, v);
    var pos = 32;
    while (outLen - pos > 64) {
      v = Blake2b.hash(v, 64);
      out.setRange(pos, pos + 32, v);
      pos += 32;
    }
    out.setRange(pos, outLen, Blake2b.hash(v, outLen - pos));
    return out;
  }
}
