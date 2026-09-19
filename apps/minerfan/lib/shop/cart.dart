import '../format.dart';
import 'shop_item.dart';

/// One line of a bill: an item and how many of it.
class CartLine {
  final ShopItem item;
  int count;
  CartLine(this.item, [this.count = 1]);

  /// The line's price in [chain], or null when the item has no price in it.
  int? total(String chain) {
    final p = item.prices[chain];
    return p == null ? null : p * count;
  }
}

/// What the customer is buying, before it becomes a bill.
class Cart {
  final List<CartLine> lines = [];

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// How many things are in it (three coffees count as three).
  int get count => lines.fold(0, (a, l) => a + l.count);

  void add(ShopItem item, [int n = 1]) {
    for (final l in lines) {
      if (l.item.id == item.id) {
        l.count += n;
        return;
      }
    }
    lines.add(CartLine(item, n));
  }

  /// Sets a line's count; zero or less removes it.
  void setCount(String itemId, int n) {
    lines.removeWhere((l) => l.item.id == itemId && n <= 0);
    for (final l in lines) {
      if (l.item.id == itemId) l.count = n;
    }
  }

  void remove(String itemId) => lines.removeWhere((l) => l.item.id == itemId);
  void clear() => lines.clear();

  /// The whole cart in [chain], or null when any line has no price in it.
  int? total(String chain) {
    if (lines.isEmpty) return null;
    var sum = 0;
    for (final l in lines) {
      final t = l.total(chain);
      if (t == null) return null;
      sum += t;
    }
    return sum;
  }

  /// The coins the whole cart can be paid in: every line has a price in
  /// the coin, and the shop can receive it ([canReceive]).
  List<String> payableCoins(Iterable<String> canReceive) =>
      [for (final c in canReceive) if (total(c) != null) c];
}

/// The order as a line of text, for the payment code and the receipt:
/// `Cafe Central A7K3: 2x Espresso, 1x Pastel de nata`. Kept short, since
/// it all has to fit in a QR code a phone can read across a counter.
String cartDescription(Cart cart, {required String shop, required String reference, int maxChars = 120}) {
  final head = [if (shop.trim().isNotEmpty) shop.trim(), reference].join(' ');
  final parts = [for (final l in cart.lines) '${l.count}x ${l.item.title}'];
  var text = '$head: ${parts.join(', ')}';
  if (text.length <= maxChars) return text;
  // Too long for comfort: keep the items that fit and count the rest.
  final kept = <String>[];
  var left = maxChars - head.length - 2;
  for (final p in parts) {
    if (left - p.length - 2 < 12) break;
    kept.add(p);
    left -= p.length + 2;
  }
  final more = parts.length - kept.length;
  text = '$head: ${kept.join(', ')}${more > 0 ? ', and $more more' : ''}';
  return text.length <= maxChars ? text : '$head: ${cart.count} items';
}

/// An amount with its coin's symbol, for the screen.
String cartAmount(int units, String chain, String symbol) => '${coins(units, decimals: coinDecimals(chain))} $symbol';
