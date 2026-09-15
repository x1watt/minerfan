/// Unsigned 64-bit arithmetic on Dart's signed 64-bit `int`.
///
/// Native Dart ints wrap on overflow for `+ - * <<`, so add, sub, mul and xor
/// already behave like `uint64_t`. Only comparison, division, right shifts
/// (`>>>`) and the high half of a product need help.
library;

const int u64Min = 0x8000000000000000; // flips the sign bit for unsigned compares
const int mask32 = 0xffffffff;

/// a < b as unsigned 64-bit values.
bool ltU64(int a, int b) => (a ^ u64Min) < (b ^ u64Min);

/// a <= b as unsigned 64-bit values.
bool leU64(int a, int b) => (a ^ u64Min) <= (b ^ u64Min);

/// High 64 bits of the unsigned 128-bit product a*b.
@pragma('vm:prefer-inline')
int mulhU64(int a, int b) {
  final aLo = a & mask32, aHi = a >>> 32;
  final bLo = b & mask32, bHi = b >>> 32;
  final ll = aLo * bLo;
  final lh = aLo * bHi;
  final hl = aHi * bLo;
  final hh = aHi * bHi;
  final mid = (ll >>> 32) + (lh & mask32) + (hl & mask32);
  return hh + (lh >>> 32) + (hl >>> 32) + (mid >>> 32);
}

/// High 64 bits of the signed 128-bit product a*b.
@pragma('vm:prefer-inline')
int mulhS64(int a, int b) {
  final hi = mulhU64(a, b);
  return hi - ((a >> 63) & b) - ((b >> 63) & a);
}

@pragma('vm:prefer-inline')
int rotr64(int x, int c) {
  c &= 63;
  if (c == 0) return x;
  return (x >>> c) | (x << (64 - c));
}

@pragma('vm:prefer-inline')
int rotl64(int x, int c) {
  c &= 63;
  if (c == 0) return x;
  return (x << c) | (x >>> (64 - c));
}

/// Sign-extends a 32-bit value to 64 bits.
int signExtend32(int x) => (x & mask32).toSigned(32);

/// Number of significant bits of a non-negative value below 2^32.
int bitLength32(int x) => x.bitLength;

/// Unsigned 64-bit n divided by d, where 0 < d < 2^32. Long division in
/// 16-bit steps so no intermediate leaves the positive int range.
int udivU64By32(int n, int d) {
  var rem = 0;
  var q = 0;
  for (var shift = 48; shift >= 0; shift -= 16) {
    final cur = (rem << 16) | ((n >>> shift) & 0xffff);
    q = (q << 16) | (cur ~/ d);
    rem = cur % d;
  }
  return q;
}

/// Unsigned 64-bit n modulo d, where 0 < d < 2^32.
int umodU64By32(int n, int d) {
  var rem = 0;
  for (var shift = 48; shift >= 0; shift -= 16) {
    final cur = (rem << 16) | ((n >>> shift) & 0xffff);
    rem = cur % d;
  }
  return rem;
}

/// RandomX reciprocal: 2^x / divisor for the highest x with a result below
/// 2^64. divisor must not be zero or a power of two.
int randomxReciprocal(int divisor) {
  const p2exp63 = u64Min; // 2^63 as an unsigned bit pattern
  final q = udivU64By32(p2exp63, divisor);
  final r = umodU64By32(p2exp63, divisor);
  final shift = bitLength32(divisor);
  return (q << shift) + udivU64By32(r << shift, divisor);
}

bool isZeroOrPowerOf2(int x) => (x & (x - 1)) == 0;
