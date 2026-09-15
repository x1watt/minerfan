import 'dart:typed_data';

/// Compact targets (`nBits`) as in Bitcoin's `CBigNum::SetCompact` and
/// `GetCompact`, and difficulty and hashrate derived from them.
abstract final class CompactTarget {
  static BigInt decode(int compact) {
    final size = compact >>> 24;
    var word = compact & 0x007fffff;
    BigInt v;
    if (size <= 3) {
      word >>>= 8 * (3 - size);
      v = BigInt.from(word);
    } else {
      v = BigInt.from(word) << (8 * (size - 3));
    }
    return (compact & 0x00800000) != 0 ? -v : v;
  }

  static int encode(BigInt v) {
    final negative = v.isNegative;
    final a = v.abs();
    var size = (a.bitLength + 7) ~/ 8;
    int compact;
    if (size <= 3) {
      compact = (a << (8 * (3 - size))).toInt();
    } else {
      compact = (a >> (8 * (size - 3))).toInt();
    }
    if (compact & 0x00800000 != 0) {
      compact >>= 8;
      size++;
    }
    compact |= size << 24;
    if (negative && compact & 0x007fffff != 0) compact |= 0x00800000;
    return compact;
  }

  /// Difficulty relative to the Bitcoin difficulty-1 target (0x1d00ffff),
  /// as block explorers show it.
  static double difficulty(int compact) {
    final t = decode(compact);
    if (t <= BigInt.zero) return 0;
    return decode(0x1d00ffff) / t;
  }

  /// Hashes per second the network needs to find a block every
  /// [spacingSeconds] at this target (`2^256 / (target + 1)` hashes per
  /// block).
  static double hashrate(int compact, int spacingSeconds) {
    final t = decode(compact);
    if (t <= BigInt.zero) return 0;
    return (BigInt.one << 256) / (t + BigInt.one) / spacingSeconds;
  }

  /// Whether a PoW hash (32 bytes, little-endian number as Bitcoin compares
  /// it) is at or below [target].
  static bool meets(Uint8List powHash, BigInt target) {
    var v = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      v = (v << 8) | BigInt.from(powHash[i]);
    }
    return v <= target;
  }
}
