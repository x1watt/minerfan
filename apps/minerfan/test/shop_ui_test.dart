import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/shop/cart.dart';
import 'package:minerfan/shop/shop_item.dart';
import 'package:minerfan/ui/shop_cart_view.dart';
import 'package:minerfan/ui/shop_receipt_view.dart';
import 'package:qr_flutter/qr_flutter.dart';

const symbols = {'cryptoescudo': 'CESC', 'monero': 'XMR'};

Widget wrap(Widget child) => MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  testWidgets('the cart shows the lines, the totals and what the buttons do', (tester) async {
    final cart = Cart()
      ..add(ShopItem(id: 'esp', title: 'Espresso', prices: {'cryptoescudo': 100000000000}), 2)
      ..add(ShopItem(id: 'nata', title: 'Pastel de nata', prices: {'cryptoescudo': 30000000000}));
    final counts = <(String, int)>[];
    final removed = <String>[];
    var checkout = 0;

    await tester.pumpWidget(wrap(CartView(
      cart: cart,
      symbols: symbols,
      payable: const ['cryptoescudo'],
      onCount: (l, n) => counts.add((l.item.id, n)),
      onRemove: (l) => removed.add(l.item.id),
      onClear: () {},
      onCheckout: () => checkout++,
    )));

    expect(find.text('Espresso'), findsOneWidget);
    expect(find.text('Pastel de nata'), findsOneWidget);
    expect(find.text('2300.00 CESC'), findsOneWidget, reason: '2 coffees at 1000 plus a cake at 300');
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.tap(find.text('Make the bill'));
    await tester.pump();

    expect(counts, [('esp', 3), ('esp', 1)]);
    expect(removed, ['nata']);
    expect(checkout, 1);
  });

  testWidgets('a cart no coin covers cannot be billed', (tester) async {
    final cart = Cart()..add(ShopItem(id: 'x', title: 'Thing'));
    var checkout = 0;
    await tester.pumpWidget(wrap(CartView(
      cart: cart,
      symbols: symbols,
      payable: const [],
      onCount: (_, _) {},
      onRemove: (_) {},
      onClear: () {},
      onCheckout: () => checkout++,
    )));
    expect(find.textContaining('No coin covers every line'), findsOneWidget);
    await tester.tap(find.text('Make the bill'));
    await tester.pump();
    expect(checkout, 0, reason: 'there is nothing to bill in');
  });

  testWidgets('the bill shows its code, its reference and what it is for', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(wrap(ReceiptView(
      coins: const ['cryptoescudo', 'monero'],
      symbols: symbols,
      coin: 'cryptoescudo',
      code: 'cryptoescudo:CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2?amount=1000',
      amount: '1000.00 CESC',
      reference: 'A7K3',
      description: 'Cafe Central A7K3: 2x Espresso',
      state: BillState.waiting,
      onCoin: picked.add,
      onNewOrder: () {},
    )));

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('1000.00 CESC'), findsOneWidget);
    expect(find.text('Order A7K3'), findsOneWidget);
    expect(find.text('Cafe Central A7K3: 2x Espresso'), findsOneWidget);
    expect(find.textContaining('Waiting for the payment'), findsOneWidget);

    await tester.tap(find.text('XMR'));
    expect(picked, ['monero']);
  });

  testWidgets('a paid bill shows the tick, the tip and no code', (tester) async {
    var again = 0;
    await tester.pumpWidget(wrap(ReceiptView(
      coins: const ['cryptoescudo'],
      symbols: symbols,
      coin: 'cryptoescudo',
      code: 'cryptoescudo:CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2?amount=1000',
      amount: '1000.00 CESC',
      reference: 'A7K3',
      description: 'Cafe Central A7K3: 2x Espresso',
      state: BillState.paid,
      tip: '50.00 CESC',
      onCoin: (_) {},
      onNewOrder: () => again++,
    )));

    expect(find.byType(QrImageView), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    expect(find.textContaining('50.00 CESC more than the bill'), findsOneWidget);

    await tester.tap(find.text('New order'));
    expect(again, 1);
  });
}
