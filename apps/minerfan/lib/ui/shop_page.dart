import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../shop/cart.dart';
import '../shop/payment_uri.dart';
import '../shop/shop.dart';
import '../shop/shop_item.dart';
import '../wallets/wallet.dart';
import 'shop_cart_page.dart';
import 'shop_category_page.dart';
import 'shop_pay.dart';
import 'shop_settings_page.dart';

/// The shop at the counter: the folders of things on sale, the cart the
/// customer is filling, and the Pay button a customer uses to settle a
/// bill on somebody else's screen.
class ShopPage extends StatelessWidget {
  final AppController app;
  const ShopPage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final shop = app.shop;
    final today = shop.takings(DateTime.now().subtract(const Duration(hours: 12)));
    return Scaffold(
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
        Row(children: [
          Expanded(
            child: Text(
              shop.name.isEmpty ? 'Your shop' : shop.name,
              style: t.textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Shop settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ShopSettingsPage(app))),
          ),
        ]),
        const SizedBox(height: 4),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            leading: const Icon(Icons.qr_code_scanner, size: 32),
            title: const Text('Pay'),
            subtitle: const Text('Scan a payment code and pay it from a wallet here'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => payByScanning(context, app),
          ),
        ),
        if (today.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              'Taken today: ${[
                for (final e in today.entries) cartAmount(e.value, e.key, _symbol(app, e.key)),
              ].join(', ')}',
              style: muted,
            ),
          ),
        const SizedBox(height: 6),
        if (shop.categories.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Nothing on sale yet', style: t.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  'Make a folder for coffee, cakes or whatever you sell, then add what is in it with a picture and '
                  'a price per coin. A customer pays by scanning the code on your screen.',
                  style: muted,
                ),
              ]),
            ),
          ),
        for (final c in shop.categories) _CategoryCard(app, c),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Add a folder'),
            onTap: () => _addCategory(context, app),
          ),
        ),
      ]),
      bottomNavigationBar: shop.cart.isEmpty ? null : _CartBar(app),
    );
  }

  static String _symbol(AppController app, String chain) {
    for (final w in app.wallets) {
      if (w.chain == chain) return w.symbol;
    }
    return chain.toUpperCase();
  }
}

Future<void> _addCategory(BuildContext context, AppController app) async {
  final name = await askText(context, title: 'New folder', hint: 'Coffee');
  if (name == null || name.trim().isEmpty) return;
  await app.shop.addCategory(name);
}

/// Asks for one line of text. Used for folder names.
Future<String?> askText(BuildContext context, {required String title, String hint = '', String initial = ''}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AskText(title: title, hint: hint, initial: initial),
    );

class _AskText extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  const _AskText({required this.title, required this.hint, required this.initial});

  @override
  State<_AskText> createState() => _AskTextState();
}

class _AskTextState extends State<_AskText> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _field.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _field,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (_) => _done(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _done, child: const Text('Save')),
        ],
      );
}

class _CategoryCard extends StatelessWidget {
  final AppController app;
  final ShopCategory category;
  const _CategoryCard(this.app, this.category);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = category.items.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: _FolderThumb(app.shop, category),
        title: Text(category.title),
        subtitle: Text(n == 1 ? '1 item' : '$n items', style: t.textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => ShopCategoryPage(app, category.id))),
      ),
    );
  }
}

class _FolderThumb extends StatelessWidget {
  final Shop shop;
  final ShopCategory category;
  const _FolderThumb(this.shop, this.category);

  @override
  Widget build(BuildContext context) {
    String? image;
    for (final i in category.items) {
      if (i.image != null) {
        image = i.image;
        break;
      }
    }
    return ShopPicture(shop: shop, image: image, size: 44, radius: 10);
  }
}

/// An item's picture, or a plain tinted box when it has none, always the
/// same size so a list never jumps.
class ShopPicture extends StatelessWidget {
  final Shop shop;
  final String? image;
  final double size;
  final double radius;
  final BoxFit fit;
  const ShopPicture({
    required this.shop,
    required this.image,
    this.size = 44,
    this.radius = 10,
    this.fit = BoxFit.cover,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.local_cafe_outlined, color: t.colorScheme.onSurfaceVariant, size: size * 0.5),
    );
    final name = image;
    if (name == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(shop.imagePath(name)),
        width: size,
        height: size,
        fit: fit,
        cacheWidth: (size * 3).round(),
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

class _CartBar extends StatelessWidget {
  final AppController app;
  const _CartBar(this.app);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cart = app.shop.cart;
    final coins = cart.payableCoins(payableChains(app));
    final line = coins.isEmpty
        ? 'No coin covers every line'
        : [for (final c in coins) cartAmount(cart.total(c)!, c, _symbolOf(app, c))].join('  ·  ');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Card(
          color: t.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(cart.count == 1 ? '1 item' : '${cart.count} items', style: t.textTheme.titleSmall),
                  Text(line, style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShopCartPage(app))),
                child: const Text('Checkout'),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  static String _symbolOf(AppController app, String chain) => ShopPage._symbol(app, chain);
}

/// The coins this shop can take money in: a payment code exists for them
/// and a wallet here receives them.
List<String> payableChains(AppController app) => [
      for (final chain in {for (final w in app.wallets) w.chain})
        if (coinHasPaymentUri(chain) && receivingWallet(app, chain) != null) chain,
    ];

/// The wallet that takes [chain] at this shop: the one chosen in the shop
/// settings, else the first wallet of that coin.
Wallet? receivingWallet(AppController app, String chain) {
  final id = app.shop.receive[chain];
  for (final w in app.wallets) {
    if (w.id == id && w.chain == chain && w.canReceive) return w;
  }
  for (final w in app.wallets) {
    if (w.chain == chain && w.canReceive) return w;
  }
  return null;
}
