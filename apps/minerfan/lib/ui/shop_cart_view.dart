import 'package:flutter/material.dart';

import '../shop/cart.dart';

/// The cart at the counter: what the customer is taking, how many of
/// each, and what it comes to in every coin they can pay in.
///
/// Plain data and callbacks, no AppController, so it can be put on screen
/// in a test.
class CartView extends StatelessWidget {
  final Cart cart;

  /// Coin id to the symbol to show ({'cryptoescudo': 'CESC'}).
  final Map<String, String> symbols;

  /// The coins the whole cart can be paid in, in the order to show them.
  final List<String> payable;

  /// A picture for a line, when there is one.
  final Widget Function(CartLine line)? picture;

  final void Function(CartLine line, int count) onCount;
  final void Function(CartLine line) onRemove;
  final VoidCallback onClear;
  final VoidCallback? onCheckout;

  const CartView({
    required this.cart,
    required this.symbols,
    required this.payable,
    required this.onCount,
    required this.onRemove,
    required this.onClear,
    this.onCheckout,
    this.picture,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    if (cart.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('The cart is empty. Tap what the customer is taking.', style: muted),
        ),
      );
    }
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), children: [
          for (final line in cart.lines)
            Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  if (picture != null) ...[picture!(line), const SizedBox(width: 10)],
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(line.item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        [
                          for (final c in payable)
                            if (line.total(c) case final total?) cartAmount(total, c, symbols[c] ?? c),
                        ].join('  ·  '),
                        style: muted,
                      ),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'One fewer',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => onCount(line, line.count - 1),
                  ),
                  Text('${line.count}', style: t.textTheme.titleMedium),
                  IconButton(
                    tooltip: 'One more',
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => onCount(line, line.count + 1),
                  ),
                  IconButton(
                    tooltip: 'Take it out',
                    icon: const Icon(Icons.close),
                    onPressed: () => onRemove(line),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (payable.isEmpty)
              Text(
                'No coin covers every line: something here has no price in a coin this shop can take.',
                style: muted,
              )
            else
              for (final c in payable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Total', style: t.textTheme.titleMedium),
                    Text(
                      cartAmount(cart.total(c)!, c, symbols[c] ?? c),
                      style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary),
                    ),
                  ]),
                ),
            const SizedBox(height: 8),
            Row(children: [
              TextButton(onPressed: onClear, child: const Text('Clear')),
              const Spacer(),
              FilledButton.icon(
                onPressed: payable.isEmpty ? null : onCheckout,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Make the bill'),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }
}
