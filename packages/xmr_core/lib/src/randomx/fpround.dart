import 'dart:math' as math;
import 'dart:typed_data';

/// IEEE-754 double arithmetic in the four x86 rounding modes, built on
/// round-to-nearest only (Dart has no rounding-mode control).
///
/// Each op computes the round-to-nearest result `c`, then the sign of the
/// exact error (exact result minus `c`), and moves `c` one ulp when the
/// requested direction differs. Errors come from error-free transformations:
/// TwoSum for add/sub, Dekker's TwoProduct for mul/div/sqrt. Operands outside
/// Dekker's safe range fall back to exact BigInt arithmetic.
///
/// Modes follow the MXCSR RC field: 0 nearest, 1 down, 2 up, 3 toward zero.

final Float64List _cf = Float64List(1);
final Int64List _ci = Int64List.view(_cf.buffer);

int doubleBits(double d) {
  _cf[0] = d;
  return _ci[0];
}

double bitsToDouble(int bits) {
  _ci[0] = bits;
  return _cf[0];
}

double _nextUp(double c) {
  _cf[0] = c;
  if (c > 0) {
    _ci[0]++;
  } else if (c < 0) {
    _ci[0]--;
  } else {
    _ci[0] = 1; // smallest positive subnormal
  }
  return _cf[0];
}

double _nextDown(double c) {
  _cf[0] = c;
  if (c > 0) {
    _ci[0]--;
  } else if (c < 0) {
    _ci[0]++;
  } else {
    _ci[0] = 0x8000000000000001;
  }
  return _cf[0];
}

/// Adjusts round-to-nearest [c] given the sign of (exact - c).
double _adjust(double c, double err, int mode) {
  switch (mode) {
    case 1:
      return err < 0 ? _nextDown(c) : c;
    case 2:
      return err > 0 ? _nextUp(c) : c;
    default:
      if (c > 0 && err < 0) return _nextDown(c);
      if (c < 0 && err > 0) return _nextUp(c);
      return c;
  }
}

/// Result for an overflow of finite operands in [mode].
double _overflow(double c, int mode) {
  final positive = c > 0;
  if (mode == 3 || (mode == 1 && positive) || (mode == 2 && !positive)) {
    return positive ? double.maxFinite : -double.maxFinite;
  }
  return c;
}

const double _dekkerMax = 1e290;
const double _dekkerMin = 1e-290;

bool _safe(double x) {
  final ax = x.abs();
  return ax < _dekkerMax && ax > _dekkerMin;
}

double fAdd(double a, double b, int mode) {
  final c = a + b;
  if (mode == 0) return c;
  if (!c.isFinite) {
    return (a.isFinite && b.isFinite) ? _overflow(c, mode) : c;
  }
  final bv = c - a;
  final err = (a - (c - bv)) + (b - bv);
  if (err == 0.0) {
    if (c == 0.0 && mode == 1 && !(a == 0.0 && b == 0.0 && !a.isNegative && !b.isNegative)) {
      return -0.0;
    }
    return c;
  }
  return _adjust(c, err, mode);
}

double fSub(double a, double b, int mode) => fAdd(a, -b, mode);

double fMul(double a, double b, int mode) {
  final c = a * b;
  if (mode == 0) return c;
  if (!c.isFinite) {
    return (a.isFinite && b.isFinite) ? _overflow(c, mode) : c;
  }
  if (a == 0.0 || b == 0.0) return c;
  double err;
  if (_safe(a) && _safe(b) && _safe(c)) {
    err = _twoProductErr(a, b, c);
  } else {
    err = _exactMulSign(a, b, c).toDouble();
  }
  if (err == 0.0) return c;
  return _adjust(c, err, mode);
}

double fDiv(double a, double b, int mode) {
  final c = a / b;
  if (mode == 0) return c;
  if (!c.isFinite) {
    return (a.isFinite && b != 0.0) ? _overflow(c, mode) : c;
  }
  if (a == 0.0 || !a.isFinite || !b.isFinite) return c;
  double err;
  if (_safe(a) && _safe(b) && _safe(c)) {
    final p = c * b;
    final e = _twoProductErr(c, b, p);
    err = (a - p) - e; // sign of a - c*b
    if (b < 0) err = -err;
  } else {
    err = _exactDivSign(a, b, c).toDouble();
  }
  if (err == 0.0) return c;
  return _adjust(c, err, mode);
}

double fSqrt(double a, int mode) {
  final c = math.sqrt(a);
  if (mode == 0) return c;
  if (!c.isFinite || c == 0.0) return c;
  double err;
  if (_safe(a) && _safe(c)) {
    final p = c * c;
    final e = _twoProductErr(c, c, p);
    err = (a - p) - e;
  } else {
    err = _exactMulSign(c, c, a).toDouble() * -1;
  }
  if (err == 0.0) return c;
  return _adjust(c, err, mode);
}

/// Exact value of a*b - p where p = fl(a*b), for operands in the safe range.
double _twoProductErr(double a, double b, double p) {
  const split = 134217729.0; // 2^27 + 1
  final ta = split * a;
  final ah = ta - (ta - a);
  final al = a - ah;
  final tb = split * b;
  final bh = tb - (tb - b);
  final bl = b - bh;
  return ((ah * bh - p) + ah * bl + al * bh) + al * bl;
}

// ---- exact fallback -------------------------------------------------------

/// A finite double as mantissa * 2^exponent.
(BigInt, int) _decompose(double d) {
  final bits = doubleBits(d);
  final neg = bits < 0;
  final exp = (bits >>> 52) & 0x7ff;
  var mant = bits & 0xfffffffffffff;
  int e;
  if (exp == 0) {
    e = -1074;
  } else {
    mant |= 1 << 52;
    e = exp - 1075;
  }
  var m = BigInt.from(mant);
  if (neg) m = -m;
  return (m, e);
}

/// sign(x*2^ex - y*2^ey)
int _cmpScaled(BigInt x, int ex, BigInt y, int ey) {
  if (ex > ey) {
    x = x << (ex - ey);
  } else {
    y = y << (ey - ex);
  }
  return (x - y).sign;
}

/// sign(a*b - c), exactly.
int _exactMulSign(double a, double b, double c) {
  final (ma, ea) = _decompose(a);
  final (mb, eb) = _decompose(b);
  final (mc, ec) = _decompose(c);
  return _cmpScaled(ma * mb, ea + eb, mc, ec);
}

/// sign(a/b - c), exactly.
int _exactDivSign(double a, double b, double c) {
  final (ma, ea) = _decompose(a);
  final (mb, eb) = _decompose(b);
  final (mc, ec) = _decompose(c);
  // a/b - c has the sign of (a - c*b) * sign(b).
  final s = _cmpScaled(ma, ea, mc * mb, ec + eb);
  return b < 0 ? -s : s;
}
