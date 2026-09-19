import 'dart:math';

/// What a shop sells, and the folders it keeps them in (`shop.json`).
///
/// Every key a version does not know is kept on save, at both levels, so
/// data written by a newer app survives an older one (the rule contacts
/// follow too).

/// A short id for an item or a folder: enough to be unique on one device,
/// short enough to name an image file.
String newShopId() {
  final r = Random.secure();
  return List.generate(4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One thing for sale.
class ShopItem {
  final String id;
  String title;

  /// A line or two under the title.
  String note;

  /// The picture's file name in `shop/images`, or null.
  String? image;

  /// Price by chain id, in the coin's smallest units. A coin missing here
  /// is a coin this item is not sold in.
  final Map<String, int> prices;

  final Map<String, Object?> extra;

  ShopItem({
    required this.id,
    required this.title,
    this.note = '',
    this.image,
    Map<String, int>? prices,
    Map<String, Object?>? extra,
  })  : prices = prices ?? {},
        extra = extra ?? {};

  static const _known = {'id', 'title', 'note', 'image', 'prices'};

  static ShopItem? fromJson(Map<String, Object?> m) {
    final id = m['id'];
    final title = m['title'];
    if (id is! String || title is! String) return null;
    return ShopItem(
      id: id,
      title: title,
      note: '${m['note'] ?? ''}',
      image: m['image'] as String?,
      prices: {
        for (final e in ((m['prices'] as Map?) ?? const {}).entries)
          if (e.value is num && (e.value! as num).toInt() > 0) '${e.key}': (e.value! as num).toInt(),
      },
      extra: {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value},
    );
  }

  Map<String, Object?> toJson() => {
        ...extra,
        'id': id,
        'title': title,
        if (note.isNotEmpty) 'note': note,
        if (image != null) 'image': image,
        'prices': prices,
      };

  /// The coins this item has a price in.
  Iterable<String> get coins => prices.keys;
}

/// A folder of items: Coffee, Cakes, anything.
class ShopCategory {
  final String id;
  String title;
  final List<ShopItem> items;
  final Map<String, Object?> extra;

  ShopCategory({
    required this.id,
    required this.title,
    List<ShopItem>? items,
    Map<String, Object?>? extra,
  })  : items = items ?? [],
        extra = extra ?? {};

  static const _known = {'id', 'title', 'items'};

  static ShopCategory? fromJson(Map<String, Object?> m) {
    final id = m['id'];
    final title = m['title'];
    if (id is! String || title is! String) return null;
    return ShopCategory(
      id: id,
      title: title,
      items: [
        for (final e in (m['items'] as List?) ?? const [])
          if (e is Map) ?ShopItem.fromJson(e.cast<String, Object?>()),
      ],
      extra: {for (final e in m.entries) if (!_known.contains(e.key)) e.key: e.value},
    );
  }

  Map<String, Object?> toJson() => {
        ...extra,
        'id': id,
        'title': title,
        'items': [for (final i in items) i.toJson()],
      };
}
