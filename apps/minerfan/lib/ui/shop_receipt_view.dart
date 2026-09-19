import 'package:flutter/material.dart';

import 'widgets.dart';

/// Where a bill stands.
enum BillState {
  /// Nothing yet: the code is on screen.
  waiting,

  /// The payment is out there but not in a block.
  seen,

  /// In a block.
  paid,
}

/// The bill on the counter, as the customer sees it across the screen:
/// the coin chips, one big code, the amount and what it is for.
///
/// Plain data and callbacks, no AppController, so it can be put on screen
/// in a test.
class ReceiptView extends StatelessWidget {
  /// Coin ids the cart can be paid in, and the symbol for each.
  final List<String> coins;
  final Map<String, String> symbols;
  final String coin;

  /// The payment code behind the QR, null while it is being made.
  final String? code;

  final String amount;
  final String reference;
  final String description;
  final BillState state;

  /// What arrived, when it was more than the bill.
  final String? tip;

  final void Function(String coin) onCoin;
  final VoidCallback onNewOrder;
  final VoidCallback? onScanConfirmation;
  final VoidCallback? onMarkPaid;

  const ReceiptView({
    required this.coins,
    required this.symbols,
    required this.coin,
    required this.code,
    required this.amount,
    required this.reference,
    required this.description,
    required this.state,
    required this.onCoin,
    required this.onNewOrder,
    this.tip,
    this.onScanConfirmation,
    this.onMarkPaid,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final done = state != BillState.waiting;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
      if (coins.length > 1 && !done)
        Center(
          child: Wrap(spacing: 8, children: [
            for (final c in coins)
              ChoiceChip(
                label: Text(symbols[c] ?? c),
                selected: c == coin,
                onSelected: (_) => onCoin(c),
              ),
          ]),
        ),
      const SizedBox(height: 14),
      Center(
        child: done
            ? Column(children: [
                Icon(
                  state == BillState.paid ? Icons.check_circle : Icons.hourglass_bottom,
                  size: 120,
                  color: state == BillState.paid ? Colors.green : t.colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  state == BillState.paid ? 'Paid' : 'Payment received',
                  style: t.textTheme.headlineSmall,
                ),
              ])
            : QrCard(code, size: 300),
      ),
      const SizedBox(height: 16),
      Center(child: Text(amount, style: t.textTheme.displaySmall?.copyWith(color: t.colorScheme.primary))),
      const SizedBox(height: 4),
      Center(child: Text('Order $reference', style: t.textTheme.titleMedium)),
      const SizedBox(height: 4),
      Center(child: Text(description, textAlign: TextAlign.center, style: muted)),
      const SizedBox(height: 16),
      Center(
        child: Text(
          switch (state) {
            BillState.waiting => 'Waiting for the payment. The customer scans this code.',
            BillState.seen => 'The payment is on its way and not yet in a block. Safe to hand over for small amounts.',
            BillState.paid => tip == null ? 'Settled in full.' : 'Settled, and $tip more than the bill.',
          },
          textAlign: TextAlign.center,
          style: muted,
        ),
      ),
      const SizedBox(height: 20),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
        if (!done && onScanConfirmation != null)
          OutlinedButton.icon(
            onPressed: onScanConfirmation,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Scan a receipt'),
          ),
        if (!done && onMarkPaid != null)
          OutlinedButton.icon(
            onPressed: onMarkPaid,
            icon: const Icon(Icons.done, size: 18),
            label: const Text('Mark as paid'),
          ),
        FilledButton.icon(
          onPressed: onNewOrder,
          icon: const Icon(Icons.add_shopping_cart, size: 18),
          label: const Text('New order'),
        ),
      ]),
    ]);
  }
}
