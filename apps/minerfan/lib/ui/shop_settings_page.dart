import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../shop/payment_uri.dart';
import '../wallets/wallet.dart';
import 'shop_page.dart';
import 'widgets.dart';

/// The shop's own settings: what it is called, and which wallet takes the
/// money for each coin.
class ShopSettingsPage extends StatefulWidget {
  final AppController app;
  const ShopSettingsPage(this.app, {super.key});

  @override
  State<ShopSettingsPage> createState() => _ShopSettingsPageState();
}

class _ShopSettingsPageState extends State<ShopSettingsPage> {
  late final _name = TextEditingController(text: widget.app.shop.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final chains = {for (final w in app.wallets) w.chain}.where(coinHasPaymentUri).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Shop settings')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
            const SectionTitle('Name'),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Shop name', hintText: 'Cafe Central'),
              onChanged: (v) => app.shop.setName(v),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('It appears on the payment screen and on every bill.', style: muted),
            ),
            const SectionTitle('Where the money arrives'),
            Text(
              'One wallet per coin. A coin with no wallet here cannot be charged, and will not be offered at '
              'checkout.',
              style: muted,
            ),
            const SizedBox(height: 8),
            if (chains.isEmpty)
              Text('No wallet in this app can receive yet. Add one in Wallets.', style: muted)
            else
              for (final chain in chains) _ReceiveRow(app, chain),
          ]),
        ),
      ),
    );
  }
}

class _ReceiveRow extends StatelessWidget {
  final AppController app;
  final String chain;
  const _ReceiveRow(this.app, this.chain);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final wallets = [for (final w in app.wallets) if (w.chain == chain && w.canReceive) w];
    if (wallets.isEmpty) return const SizedBox.shrink();
    final chosen = receivingWallet(app, chain) ?? wallets.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownButtonFormField<Wallet>(
          isExpanded: true,
          initialValue: chosen,
          decoration: InputDecoration(labelText: '${wallets.first.chainName} (${wallets.first.symbol})'),
          items: [
            for (final w in wallets) DropdownMenuItem(value: w, child: Text(w.label, maxLines: 1)),
          ],
          onChanged: (w) {
            if (w != null) app.shop.setReceiveWallet(chain, w.id);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 12),
          child: Text(_short(chosen.address), style: muted),
        ),
      ]),
    );
  }

  static String _short(String a) => a.length <= 24 ? a : '${a.substring(0, 10)}...${a.substring(a.length - 10)}';
}
