String xmr(int atomic, [int digits = 6]) => (atomic / 1e12).toStringAsFixed(digits);

String hashrate(double h) {
  if (h >= 1e6) return '${(h / 1e6).toStringAsFixed(2)} MH/s';
  if (h >= 1000) return '${(h / 1000).toStringAsFixed(2)} kH/s';
  return '${h.toStringAsFixed(1)} H/s';
}

/// Smallest units as a coin amount with [decimals] places, trailing zeros
/// trimmed (at least two decimals).
String coins(int units, {int decimals = 8}) {
  final neg = units < 0;
  final u = units.abs();
  final base = BigInt.from(10).pow(decimals).toInt();
  var frac = (u % base).toString().padLeft(decimals, '0');
  while (frac.length > 2 && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  return '${neg ? '-' : ''}${u ~/ base}.$frac';
}

/// Decimals of a coin's smallest unit, by chain id.
int coinDecimals(String coin) => coin == 'monero' ? 12 : 8;

/// An amount of [coin] for the screen, with its symbol.
String coinAmount(String coin, BigInt units, String symbol) =>
    '${coins(units.toInt(), decimals: coinDecimals(coin))} $symbol';

/// Smallest units as the exact decimal a payment code carries: every
/// trailing zero trimmed, and no trailing dot (1000, not 1000.00, and
/// 0.0001 for 100000000 piconero). [coins] is for the screen and keeps two
/// decimals, which a payment code must not.
String uriAmount(int units, int decimals) {
  final base = BigInt.from(10).pow(decimals).toInt();
  var frac = (units.abs() % base).toString().padLeft(decimals, '0');
  while (frac.isNotEmpty && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  final whole = '${units < 0 ? '-' : ''}${units.abs() ~/ base}';
  return frac.isEmpty ? whole : '$whole.$frac';
}

/// Parses a decimal coin amount into smallest units exactly; null when it
/// is not a positive number with at most [decimals] places.
int? parseCoins(String text, {int decimals = 8}) {
  final m = RegExp(r'^(\d*)(?:[.,](\d*))?$').firstMatch(text.trim());
  if (m == null || (m[1]!.isEmpty && (m[2] ?? '').isEmpty)) return null;
  final frac = m[2] ?? '';
  if (frac.length > decimals) return null;
  final whole = int.tryParse(m[1]!.isEmpty ? '0' : m[1]!);
  if (whole == null || whole > 90000000000) return null;
  final units = whole * BigInt.from(10).pow(decimals).toInt() + int.parse(frac.padRight(decimals, '0').isEmpty ? '0' : frac.padRight(decimals, '0'));
  return units > 0 ? units : null;
}
