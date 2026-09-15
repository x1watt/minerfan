import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'catalog.dart';

/// A USD price and where it came from.
class Price {
  final double usd;
  final String source;
  final DateTime at;
  const Price(this.usd, this.source, this.at);
}

/// Coin prices in USD from public exchange tickers, tried in order: Kraken
/// (a USD pair), KuCoin (USDT), then CoinGecko (an average over exchanges).
/// The source ids come from the mining catalog. Results are cached for a
/// minute; failures return the last known price.
class PriceService {
  final MiningCatalog Function() catalog;
  final Map<String, Price> _cache = {};
  final Map<String, Future<Price?>> _pending = {};
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  PriceService(this.catalog);

  Price? cached(String symbol) => _cache[symbol];

  Future<Price?> usd(String symbol) {
    final c = _cache[symbol];
    if (c != null && DateTime.now().difference(c.at) < const Duration(minutes: 1)) return Future.value(c);
    // A block body: returning the removed future from whenComplete would
    // make the future wait for itself.
    return _pending[symbol] ??= _fetch(symbol).whenComplete(() {
      _pending.remove(symbol);
    });
  }

  Future<Price?> _fetch(String symbol) async {
    final ids = catalog().coins[symbol]?.price ?? const {};
    final sources = <(String, Future<double?> Function())>[
      if (ids['kraken'] != null) ('Kraken', () => _kraken(ids['kraken']!)),
      if (ids['kucoin'] != null) ('KuCoin', () => _kucoin(ids['kucoin']!)),
      if (ids['coingecko'] != null) ('CoinGecko', () => _coingecko(ids['coingecko']!)),
    ];
    for (final (name, get) in sources) {
      try {
        final v = await get().timeout(const Duration(seconds: 10));
        if (v != null && v > 0) return _cache[symbol] = Price(v, name, DateTime.now());
      } catch (_) {
        // Next source.
      }
    }
    return _cache[symbol];
  }

  Future<Map<String, Object?>> _json(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    return jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, Object?>;
  }

  /// Last trade price of a Kraken pair.
  Future<double?> _kraken(String pair) async {
    final m = await _json('https://api.kraken.com/0/public/Ticker?pair=$pair');
    final result = m['result'] as Map<String, Object?>?;
    final t = result?.values.first as Map<String, Object?>?;
    final c = t?['c'] as List?;
    return c == null ? null : double.tryParse('${c.first}');
  }

  Future<double?> _kucoin(String symbol) async {
    final m = await _json('https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=$symbol');
    return double.tryParse('${(m['data'] as Map?)?['price']}');
  }

  Future<double?> _coingecko(String id) async {
    final m = await _json('https://api.coingecko.com/api/v3/simple/price?ids=$id&vs_currencies=usd');
    final v = (m[id] as Map?)?['usd'];
    return v is num ? v.toDouble() : null;
  }

  void close() => _http.close(force: true);
}
