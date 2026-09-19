import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'shop_cart_view.dart';
import 'shop_page.dart';
import 'shop_receipt_page.dart';

/// The cart, wired to the shop.
class ShopCartPage extends StatelessWidget {
  final AppController app;
  const ShopCartPage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cart = app.shop.cart;
        final payable = cart.payableCoins(payableChains(app));
        return Scaffold(
          appBar: AppBar(title: const Text('The order')),
          body: SafeArea(
            child: CartView(
              cart: cart,
              symbols: {for (final w in app.wallets) w.chain: w.symbol},
              payable: payable,
              picture: (line) => ShopPicture(shop: app.shop, image: line.item.image, size: 44),
              onCount: (line, n) {
                cart.setCount(line.item.id, n);
                app.shop.notify();
              },
              onRemove: (line) {
                cart.remove(line.item.id);
                app.shop.notify();
              },
              onClear: () {
                cart.clear();
                app.shop.notify();
                Navigator.pop(context);
              },
              onCheckout: payable.isEmpty
                  ? null
                  : () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(builder: (_) => ShopReceiptPage(app, coin: payable.first)),
                      ),
            ),
          ),
        );
      },
    );
  }
}
