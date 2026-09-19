import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'cart.dart';
import 'shop_item.dart';

/// The shop: its name, the folders of things it sells, which wallet takes
/// each coin, and the bills it has been paid.
///
/// Two files next to the app's other data: `shop.json` (the catalogue,
/// small, rewritten whole) and `shop-sales.json` (paid bills, newest
/// first). Pictures live in `shop/images`. Saves happen in order, off the
/// frame, through a temporary file and a rename, and every key this
/// version does not know is kept.
class Shop extends ChangeNotifier {
  final String dataDir;
  Shop(this.dataDir);

  String name = '';

  /// Chain id to the wallet id that receives it.
  final Map<String, String> receive = {};

  final List<ShopCategory> categories = [];

  /// Paid bills, newest first.
  final List<Sale> sales = [];

  /// What the customer at the counter is buying right now (not saved).
  final Cart cart = Cart();

  /// Transactions already counted for a bill, so two bills of the same
  /// price cannot both claim one payment (not saved: it only matters
  /// while the app is up).
  final Set<String> claimedTxids = {};

  Map<String, Object?> _extra = {};
  Future<void> _writing = Future.value();

  File get _file => File('$dataDir/shop.json');
  File get _salesFile => File('$dataDir/shop-sales.json');

  /// Where an item's picture lives.
  String get imageDir => '$dataDir/shop/images';
  String imagePath(String fileName) => '$imageDir/$fileName';

  static const _known = {'version', 'name', 'receive', 'categories'};

  bool get isEmpty => categories.isEmpty;

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final m = (jsonDecode(await _file.readAsString()) as Map).cast<String, Object?>();
        name = '${m['name'] ?? ''}';
        receive
          ..clear()
          ..addAll({
            for (final e in ((m['receive'] as Map?) ?? const {}).entries)
              if ('${e.value}'.isNotEmpty) '${e.key}': '${e.value}',
          });
        categories
          ..clear()
          ..addAll([
            for (final e in (m['categories'] as List?) ?? const [])
              if (e is Map) ?ShopCategory.fromJson(e.cast<String, Object?>()),
          ]);
        _extra = {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value};
      }
      if (await _salesFile.exists()) {
        sales
          ..clear()
          ..addAll([
            for (final e in (jsonDecode(await _salesFile.readAsString()) as List)
                .whereType<Map>()) ?Sale.fromJson(e.cast<String, Object?>()),
          ]);
        _sortSales();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('shop: $e');
    }
    unawaited(sweepImages());
  }

  Map<String, Object?> toJson() => {
        ..._extra,
        'version': 1,
        'name': name,
        'receive': receive,
        'categories': [for (final c in categories) c.toJson()],
      };

  /// Saves (in order, off the frame: a temporary file, then a rename).
  Future<void> save() {
    notifyListeners();
    final text = const JsonEncoder.withIndent(' ').convert(toJson());
    return _writing = _writing.then((_) => _write(_file, text));
  }

  Future<void> _saveSales() {
    final text = const JsonEncoder.withIndent(' ').convert([for (final s in sales) s.toJson()]);
    return _writing = _writing.then((_) => _write(_salesFile, text));
  }

  Future<void> _write(File f, String text) async {
    try {
      await Directory(dataDir).create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('shop: $e');
    }
  }

  /// Tells the screens something changed that is not saved (the cart).
  void notify() => notifyListeners();

  /// Waits for the writes in flight (tests, shutdown).
  Future<void> flush() => _writing;

  // ---- the catalogue ----

  ShopCategory? category(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> addCategory(String title) {
    categories.add(ShopCategory(id: newShopId(), title: title.trim()));
    return save();
  }

  Future<void> renameCategory(String id, String title) {
    category(id)?.title = title.trim();
    return save();
  }

  /// Removes a folder with everything in it, and their pictures.
  Future<void> removeCategory(String id) {
    final c = category(id);
    if (c == null) return Future.value();
    for (final i in c.items) {
      _deleteImage(i.image);
    }
    categories.removeWhere((x) => x.id == id);
    return save();
  }

  Future<void> putItem(String categoryId, ShopItem item) {
    final c = category(categoryId);
    if (c == null) return Future.value();
    final at = c.items.indexWhere((i) => i.id == item.id);
    if (at < 0) {
      c.items.add(item);
    } else {
      c.items[at] = item;
    }
    return save();
  }

  Future<void> removeItem(String categoryId, String itemId) {
    final c = category(categoryId);
    if (c == null) return Future.value();
    for (final i in c.items) {
      if (i.id == itemId) _deleteImage(i.image);
    }
    c.items.removeWhere((i) => i.id == itemId);
    cart.remove(itemId);
    return save();
  }

  void _deleteImage(String? fileName) {
    if (fileName == null) return;
    unawaited(() async {
      try {
        final f = File(imagePath(fileName));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }());
  }

  /// Deletes pictures no item names any more (a crash between writing a
  /// picture and saving the catalogue leaves one behind).
  Future<void> sweepImages() async {
    try {
      final dir = Directory(imageDir);
      if (!await dir.exists()) return;
      final named = {
        for (final c in categories)
          for (final i in c.items)
            if (i.image != null) i.image!,
      };
      await for (final f in dir.list()) {
        if (f is File && !named.contains(f.uri.pathSegments.last)) await f.delete();
      }
    } catch (e) {
      debugPrint('shop: $e');
    }
  }

  // ---- the counter ----

  Future<void> setName(String v) {
    name = v.trim();
    return save();
  }

  Future<void> setReceiveWallet(String chain, String walletId) {
    receive[chain] = walletId;
    return save();
  }

  /// A short, easy to read reference for a bill: no letters that can be
  /// mistaken for a digit.
  static String newReference() {
    const alphabet = 'ACDEFGHJKLMNPQRTUVWXY349';
    final r = Random.secure();
    return List.generate(4, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }

  /// Keeps a paid bill and its takings.
  Future<void> recordSale(Sale s) {
    sales.add(s);
    _sortSales();
    if (sales.length > 2000) sales.removeRange(2000, sales.length);
    notifyListeners();
    return _saveSales();
  }

  void _sortSales() => sales.sort((a, b) => b.time.compareTo(a.time));

  /// What came in over [since], by coin.
  Map<String, int> takings(DateTime since) {
    final from = since.millisecondsSinceEpoch ~/ 1000;
    final out = <String, int>{};
    for (final s in sales) {
      if (s.time < from) continue;
      out[s.chain] = (out[s.chain] ?? 0) + s.units;
    }
    return out;
  }
}

/// A bill that was paid.
class Sale {
  final String reference;
  final String chain;
  final int units;

  /// Seconds since the epoch.
  final int time;

  /// The order, as it was written on the bill.
  final String description;

  /// The payment that settled it, when one was matched.
  final String? txid;

  final Map<String, Object?> extra;

  Sale({
    required this.reference,
    required this.chain,
    required this.units,
    required this.time,
    this.description = '',
    this.txid,
    Map<String, Object?>? extra,
  }) : extra = extra ?? {};

  static const _known = {'reference', 'chain', 'units', 'time', 'description', 'txid'};

  static Sale? fromJson(Map<String, Object?> m) {
    final units = m['units'];
    if (m['reference'] is! String || m['chain'] is! String || units is! num) return null;
    return Sale(
      reference: m['reference']! as String,
      chain: m['chain']! as String,
      units: units.toInt(),
      time: (m['time'] as num?)?.toInt() ?? 0,
      description: '${m['description'] ?? ''}',
      txid: m['txid'] as String?,
      extra: {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value},
    );
  }

  Map<String, Object?> toJson() => {
        ...extra,
        'reference': reference,
        'chain': chain,
        'units': units,
        'time': time,
        if (description.isNotEmpty) 'description': description,
        if (txid != null) 'txid': txid,
      };
}
