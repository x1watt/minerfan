import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../format.dart';
import '../shop/cart.dart';
import '../shop/paid_note.dart';
import '../shop/payment_uri.dart';
import '../shop/receipt.dart';
import '../shop/shop.dart';
import 'qr_input.dart';
import 'shop_page.dart';
import 'shop_receipt_view.dart';

/// The bill on the counter: the code the customer scans, and the watch on
/// the wallet that says when the money arrived.
class ShopReceiptPage extends StatefulWidget {
  final AppController app;
  final String coin;
  const ShopReceiptPage(this.app, {required this.coin, super.key});

  @override
  State<ShopReceiptPage> createState() => _ShopReceiptPageState();
}

class _ShopReceiptPageState extends State<ShopReceiptPage> {
  late String _coin = widget.coin;
  late final String _reference = Shop.newReference();
  late final int _time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  late final String _description = cartDescription(
    widget.app.shop.cart,
    shop: widget.app.shop.name,
    reference: _reference,
  );

  /// What the wallet of each coin already held when the bill was made, so
  /// older money cannot settle it.
  final Map<String, Set<String>> _before = {};
  final Map<String, int> _pendingBefore = {};

  String? _noteTxid;
  Settled? _settled;
  bool _byHand = false;
  bool _recorded = false;

  @override
  void initState() {
    super.initState();
    for (final chain in widget.app.shop.cart.payableCoins(payableChains(widget.app))) {
      final w = receivingWallet(widget.app, chain);
      if (w == null) continue;
      _before[chain] = {for (final tx in incomingOf(w)) tx.txid};
      _pendingBefore[chain] = pendingInOf(w);
    }
  }

  int get _units => widget.app.shop.cart.total(_coin) ?? 0;

  String _symbol(String chain) {
    for (final w in widget.app.shop.cart.lines.isEmpty ? widget.app.wallets : widget.app.wallets) {
      if (w.chain == chain) return w.symbol;
    }
    return chain.toUpperCase();
  }

  Bill get _bill {
    final w = receivingWallet(widget.app, _coin);
    return Bill(
      reference: _reference,
      chain: _coin,
      address: w?.address ?? '',
      units: _units,
      description: _description,
      time: _time,
      before: _before[_coin] ?? {},
    );
  }

  /// Looks at the wallet and moves the bill on when the money is there.
  BillState _state() {
    if (_byHand) return BillState.paid;
    final w = receivingWallet(widget.app, _coin);
    if (w == null) return BillState.waiting;
    final found = settle(
      incomingOf(w),
      _bill,
      claimed: widget.app.shop.claimedTxids,
      noteTxid: _noteTxid,
    );
    if (found != null) {
      if (_settled?.txid != found.txid || _settled?.confirmed != found.confirmed) {
        _settled = found;
        widget.app.shop.claimedTxids.add(found.txid);
      }
      if (found.confirmed) _record(found);
      return found.confirmed ? BillState.paid : BillState.seen;
    }
    // Monero shows an unconfirmed payment only as a rise in what the
    // mempool holds for this wallet: no txid until a block arrives.
    final pending = pendingInOf(w) - (_pendingBefore[_coin] ?? 0);
    if (pending >= _units && _units > 0) return BillState.seen;
    return BillState.waiting;
  }

  void _record(Settled s) {
    if (_recorded) return;
    _recorded = true;
    final shop = widget.app.shop;
    Future.microtask(() => shop.recordSale(Sale(
          reference: _reference,
          chain: _coin,
          units: s.received,
          time: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          description: _description,
          txid: s.txid,
        )));
  }

  Future<void> _scanConfirmation() async {
    final text = await readQrText(
      context,
      title: 'The customer\'s receipt',
      hint: 'Point the camera at the code on the customer\'s screen.',
      accept: (t) => parsePaidNote(t) != null,
      what: 'a payment receipt',
    );
    if (text == null || !mounted) return;
    final note = parsePaidNote(text);
    if (note == null) {
      _say('That code is not a payment receipt.');
      return;
    }
    if (note.reference != _reference) {
      _say('That receipt is for order ${note.reference}, not $_reference.');
      return;
    }
    setState(() {
      _coin = note.chain;
      _noteTxid = note.txid;
    });
    _say('Receipt read. Looking for the payment.');
  }

  void _markPaid() {
    setState(() => _byHand = true);
    _record(Settled('', true, _units));
  }

  void _say(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  void _newOrder() {
    widget.app.shop.cart.clear();
    widget.app.shop.notify();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final coins = app.shop.cart.payableCoins(payableChains(app));
        if (app.shop.cart.isEmpty && _settled == null && !_byHand) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('The order is empty.')));
        }
        final wallet = receivingWallet(app, _coin);
        final state = _state();
        final code = wallet == null
            ? null
            : buildPaymentUri(PaymentRequest(
                chain: _coin,
                address: wallet.address,
                units: _units,
                label: app.shop.name,
                message: _description,
              ));
        final extra = _settled != null && _settled!.received > _units ? _settled!.received - _units : 0;
        return Scaffold(
          appBar: AppBar(title: Text('Order $_reference')),
          body: SafeArea(
            child: ReceiptView(
              coins: coins,
              symbols: {for (final w in app.wallets) w.chain: w.symbol},
              coin: _coin,
              code: code,
              amount: '${coins_(_units, _coin)} ${_symbol(_coin)}',
              reference: _reference,
              description: _description,
              state: state,
              tip: extra > 0 ? '${coins_(extra, _coin)} ${_symbol(_coin)}' : null,
              onCoin: (c) => setState(() => _coin = c),
              onNewOrder: _newOrder,
              onScanConfirmation: _scanConfirmation,
              onMarkPaid: _markPaid,
            ),
          ),
        );
      },
    );
  }

  static String coins_(int units, String chain) => coins(units, decimals: coinDecimals(chain));
}
