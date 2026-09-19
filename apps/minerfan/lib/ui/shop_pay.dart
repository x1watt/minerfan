import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../format.dart';
import '../shop/paid_note.dart';
import '../shop/pay.dart';
import '../shop/payment_uri.dart';
import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';
import 'field_types.dart';
import 'qr_input.dart';
import 'room_moderation.dart' show payingWallets;
import 'widgets.dart';

/// The customer's side: read a shop's code and pay it.
Future<void> payByScanning(BuildContext context, AppController app) async {
  final text = await readQrText(
    context,
    accept: (t) => parsePaymentUri(t) != null,
    title: 'Scan the shop\'s code',
    hint: 'Point the camera at the code on the shop\'s screen.',
    what: 'the payment code (text starting with monero: or cryptoescudo:)',
  );
  if (text == null || !context.mounted) return;
  final request = parsePaymentUri(text);
  if (request == null) {
    _say(context, paymentUriProblem(text) ?? 'That code is not a payment.');
    return;
  }
  final bad = fieldType(request.chain)?.check?.call(request.address);
  if (bad != null) {
    _say(context, 'The address in that code is not a ${request.chain} address.');
    return;
  }
  await showPaySheet(context, app, request);
}

void _say(BuildContext context, String m) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(m)));

/// Confirms a payment and sends it.
Future<void> showPaySheet(BuildContext context, AppController app, PaymentRequest request) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PaySheet(app, request),
    );

class _PaySheet extends StatefulWidget {
  final AppController app;
  final PaymentRequest request;
  const _PaySheet(this.app, this.request);

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  final _amount = TextEditingController();
  final _password = TextEditingController();
  Wallet? _wallet;
  String? _error;
  bool _busy = false;
  String? _note;

  String get chain => widget.request.chain;

  @override
  void initState() {
    super.initState();
    final ws = payingWallets(widget.app, chain);
    _wallet = ws.isEmpty ? null : ws.first;
  }

  @override
  void dispose() {
    _amount.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _symbol {
    for (final w in widget.app.wallets) {
      if (w.chain == chain) return w.symbol;
    }
    return chain.toUpperCase();
  }

  /// The bill's reference, when the shop wrote one at the front of the
  /// description (`Cafe Central A7K3: ...`).
  String get _reference {
    final m = RegExp(r'\b([A-Z0-9]{4})\s*:').firstMatch(widget.request.message);
    return m?.group(1) ?? '';
  }

  int _spendable(Wallet w) => switch (w) {
        MoneroWallet() => w.status?.unlocked ?? 0,
        UtxoWallet() => w.status?.balance.confirmed ?? 0,
        _ => 0,
      };

  Future<void> _pay() async {
    final w = _wallet;
    if (w == null) return;
    final units = widget.request.units ?? parseCoins(_amount.text, decimals: coinDecimals(chain));
    if (units == null) return setState(() => _error = 'Enter an amount');
    if (units > _spendable(w)) return setState(() => _error = 'Not enough spendable in this wallet');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final txid = await payRequest(
        wallet: w,
        req: widget.request,
        units: units,
        password: w is KeyedWallet && w.hasPassword ? _password.text : null,
      );
      // The receipt the shop can scan: it says which bill this payment is
      // for, which the chain cannot.
      String? note;
      try {
        final keys = await widget.app.privateNetwork.keys();
        note = await buildPaidNoteInBackground(
          keys.station.privateKeyHex,
          reference: _reference,
          chain: chain,
          txid: txid,
          units: units,
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = note;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final ws = payingWallets(widget.app, chain);
    final w = _wallet;
    final needsPassword = w is KeyedWallet && w.hasPassword;
    final units = widget.request.units;
    final note = _note;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: note != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Paid', style: t.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('Show this to the shop so it knows which order you paid.',
                    textAlign: TextAlign.center, style: muted),
                const SizedBox(height: 14),
                QrCard(note, size: 240),
                const SizedBox(height: 14),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
              ])
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  units == null ? 'Pay ${widget.request.label}' : 'Pay ${coins(units, decimals: coinDecimals(chain))} $_symbol',
                  style: t.textTheme.titleLarge,
                ),
                if (widget.request.label.isNotEmpty && units != null)
                  Text(widget.request.label, style: t.textTheme.titleMedium),
                if (widget.request.message.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(widget.request.message, style: muted),
                ],
                const SizedBox(height: 14),
                if (ws.isEmpty)
                  Text('You have no $_symbol wallet here to pay from. Add one in Wallets.', style: muted)
                else ...[
                  DropdownButtonFormField<Wallet>(
                    isExpanded: true,
                    initialValue: w,
                    decoration: const InputDecoration(labelText: 'Pay from'),
                    items: [
                      for (final x in ws)
                        DropdownMenuItem(
                          value: x,
                          child: Text('${x.label}  (${coins(_spendable(x), decimals: coinDecimals(chain))} $_symbol)'),
                        ),
                    ],
                    onChanged: _busy ? null : (x) => setState(() => _wallet = x),
                  ),
                  if (units == null) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Amount ($_symbol)'),
                    ),
                  ],
                  if (needsPassword) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Wallet password'),
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                ],
                if (_busy && chain == 'monero')
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('Picking decoys, signing and sending (up to a minute).', style: muted),
                  ),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy || ws.isEmpty ? null : _pay,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Pay'),
                  ),
                ]),
              ]),
      ),
    );
  }
}
