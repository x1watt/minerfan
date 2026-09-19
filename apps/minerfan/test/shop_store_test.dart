import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/shop/cart.dart';
import 'package:minerfan/shop/shop.dart';
import 'package:minerfan/shop/shop_item.dart';

ShopItem espresso() => ShopItem(
      id: 'i91a',
      title: 'Espresso',
      note: 'Short and strong',
      prices: {'cryptoescudo': 100000000000, 'monero': 100000000},
    );

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('shop'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('a catalogue saves and loads, keys this version does not know included', () async {
    final shop = Shop(tmp.path);
    await shop.setName('Cafe Central');
    await shop.setReceiveWallet('cryptoescudo', 'cryptoescudo-2');
    await shop.addCategory('Coffee');
    await shop.putItem(shop.categories.first.id, espresso());
    await shop.flush();

    // A newer version wrote fields at all three levels.
    final file = File('${tmp.path}/shop.json');
    final m = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    m['openingHours'] = '08:00-18:00';
    (m['categories']! as List)[0]['colour'] = 'brown';
    ((m['categories']! as List)[0]['items'] as List)[0]['vat'] = 23;
    await file.writeAsString(jsonEncode(m));

    final again = Shop(tmp.path);
    await again.load();
    expect(again.name, 'Cafe Central');
    expect(again.receive['cryptoescudo'], 'cryptoescudo-2');
    expect(again.categories.single.title, 'Coffee');
    final item = again.categories.single.items.single;
    expect(item.title, 'Espresso');
    expect(item.prices['cryptoescudo'], 100000000000);
    expect(item.prices['monero'], 100000000);

    // Saving again keeps what it did not understand.
    await again.setName('Cafe Bica');
    await again.flush();
    final back = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(back['openingHours'], '08:00-18:00');
    expect((back['categories']! as List)[0]['colour'], 'brown');
    expect(((back['categories']! as List)[0]['items'] as List)[0]['vat'], 23);
    expect(back['name'], 'Cafe Bica');
  });

  test('removing an item takes its picture with it', () async {
    final shop = Shop(tmp.path);
    await shop.addCategory('Coffee');
    final id = shop.categories.first.id;
    await Directory(shop.imageDir).create(recursive: true);
    final picture = File(shop.imagePath('i91a-1.jpg'));
    await picture.writeAsBytes([1, 2, 3]);
    await shop.putItem(id, espresso()..image = 'i91a-1.jpg');
    await shop.removeItem(id, 'i91a');
    await shop.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await picture.exists(), isFalse);
    expect(shop.categories.single.items, isEmpty);
  });

  test('a picture no item names is swept away', () async {
    final shop = Shop(tmp.path);
    await Directory(shop.imageDir).create(recursive: true);
    final orphan = File(shop.imagePath('gone-1.jpg'));
    await orphan.writeAsBytes([1]);
    await shop.sweepImages();
    expect(await orphan.exists(), isFalse);
  });

  test('paid bills are kept and summed', () async {
    final shop = Shop(tmp.path);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await shop.recordSale(Sale(reference: 'A7K3', chain: 'cryptoescudo', units: 100000000000, time: now - 300));
    await shop.recordSale(Sale(reference: 'K2WY', chain: 'cryptoescudo', units: 50000000000, time: now));
    await shop.recordSale(Sale(
      reference: 'OLD1',
      chain: 'cryptoescudo',
      units: 900,
      time: now - 3 * 24 * 3600,
    ));
    await shop.flush();

    final today = shop.takings(DateTime.now().subtract(const Duration(hours: 12)));
    expect(today['cryptoescudo'], 150000000000, reason: 'yesterday and older stay out');

    final again = Shop(tmp.path);
    await again.load();
    expect(again.sales.length, 3);
    expect(again.sales.first.reference, 'K2WY', reason: 'newest first');
  });

  test('a reference is short and easy to read out loud', () {
    for (var i = 0; i < 50; i++) {
      final r = Shop.newReference();
      expect(r.length, 4);
      expect(RegExp(r'^[ACDEFGHJKLMNPQRTUVWXY349]{4}$').hasMatch(r), isTrue, reason: r);
    }
  });

  test('the cart adds up, and only offers coins every line has', () {
    final cart = Cart();
    final cake = ShopItem(id: 'cake', title: 'Pastel de nata', prices: {'cryptoescudo': 30000000000});
    cart.add(espresso());
    cart.add(espresso());
    cart.add(cake);
    expect(cart.count, 3);
    expect(cart.lines.length, 2);
    expect(cart.total('cryptoescudo'), 2 * 100000000000 + 30000000000);
    expect(cart.total('monero'), isNull, reason: 'the cake has no Monero price');
    expect(cart.payableCoins(['cryptoescudo', 'monero']), ['cryptoescudo']);

    cart.setCount('cake', 0);
    expect(cart.total('monero'), 200000000);
    cart.setCount('i91a', 5);
    expect(cart.total('monero'), 500000000);
    cart.clear();
    expect(cart.total('monero'), isNull);
  });

  test('the order text names the shop, the reference and the items', () {
    final cart = Cart()
      ..add(espresso(), 2)
      ..add(ShopItem(id: 'cake', title: 'Pastel de nata'));
    final text = cartDescription(cart, shop: 'Cafe Central', reference: 'A7K3');
    expect(text, 'Cafe Central A7K3: 2x Espresso, 1x Pastel de nata');

    // A long order is cut, and still says what it is.
    final big = Cart();
    for (var i = 0; i < 20; i++) {
      big.add(ShopItem(id: 'x$i', title: 'Something with a long name $i'));
    }
    final long = cartDescription(big, shop: 'Cafe Central', reference: 'A7K3');
    expect(long.length, lessThanOrEqualTo(120));
    expect(long, startsWith('Cafe Central A7K3:'));
  });
}
