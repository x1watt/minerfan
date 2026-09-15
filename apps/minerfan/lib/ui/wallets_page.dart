import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../format.dart';
import '../prices.dart';
import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';
import 'add_wallet_page.dart';
import 'contacts_page.dart';
import 'monero_wallet_page.dart';
import 'utxo_wallet_page.dart';

/// Every wallet the user has, whatever mines or not, with prices in USD.
class WalletsPage extends StatefulWidget {
  final AppController app;
  const WalletsPage(this.app, {super.key});

  @override
  State<WalletsPage> createState() => _WalletsPageState();
}

class _WalletsPageState extends State<WalletsPage> {
  final Map<String, Price?> _prices = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    for (final symbol in {for (final w in widget.app.wallets) ...w.assets.map((a) => a.symbol)}) {
      final p = await widget.app.prices.usd(symbol);
      if (!mounted) return;
      setState(() => _prices[symbol] = p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final t = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addWallet(context),
        icon: const Icon(Icons.add),
        label: const Text('Add wallet'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsPage(widget.app))),
              icon: const Icon(Icons.contacts_outlined),
              label: Text(app.contacts.contacts.isEmpty ? 'Contacts' : 'Contacts (${app.contacts.contacts.length})'),
            ),
          ),
          const SizedBox(height: 12),
          for (final symbol in _prices.keys)
            if (_prices[symbol] case final p?)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  '1 $symbol = \$${p.usd.toStringAsFixed(2)}  ·  ${p.source}, ${_ago(p.at)}',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
          if (app.wallets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No wallets yet. Add one, or set a wallet address on a miner.'),
              ),
            ),
          for (final chain in {for (final w in app.wallets) w.chain}) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(
              '${app.wallets.firstWhere((w) => w.chain == chain).chainName}  ·  '
              '${app.wallets.where((w) => w.chain == chain).length}',
              style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary),
            ),
          ),
          for (final w in app.wallets.where((w) => w.chain == chain)) _WalletCard(app, w, _prices),
        ],
        ],
      ),
    );
  }

  static String _ago(DateTime at) {
    final s = DateTime.now().difference(at).inSeconds;
    return s < 60 ? 'just now' : '${s ~/ 60} min ago';
  }

  Future<void> _addWallet(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddWalletPage(widget.app)));
    _refresh();
  }
}

class _WalletCard extends StatelessWidget {
  final AppController app;
  final Wallet w;
  final Map<String, Price?> prices;
  const _WalletCard(this.app, this.w, this.prices);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    // What the Monero node saw this wallet earn from mining (until the
    // wallet engine scans real balances).
    final monero = app.monero;
    final mined = w.chain == 'monero' && monero.settings.wallet.trim() == w.address
        ? monero.status?.payouts.fold<int>(0, (a, p) => a + p.amount)
        : null;
    final price = prices[w.symbol]?.usd;
    final utxo = w is UtxoWallet ? w as UtxoWallet : null;
    final xmrWallet = w is MoneroWallet ? w as MoneroWallet : null;
    final keyed = w is KeyedWallet ? w as KeyedWallet : null;
    final balance = utxo?.status?.balance;
    final xs = xmrWallet?.status;
    Widget? page;
    if (utxo != null) page = UtxoWalletPage(app, utxo);
    if (xmrWallet != null) page = MoneroWalletPage(app, xmrWallet);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: page == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page!)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Badge(w.symbol),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(w.label, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('${w.chainName}  ·  ${_short(w.address)}', style: muted, maxLines: 1),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'remove') _remove(context);
                      if (v == 'viewkey') _addViewKey(context);
                      if (v == 'rename') _rename(context);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      if (w is MoneroWatchWallet)
                        const PopupMenuItem(value: 'viewkey', child: Text('Add its private view key (see its balance)')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (final a in w.assets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text('${a.name} (${a.symbol})')),
                      const SizedBox(width: 8),
                      Text(
                        a.amount == null
                            ? (keyed != null ? (xmrWallet != null && !xmrWallet.isOpen && keyed.hasPassword ? 'Locked' : 'Connecting...') : 'Address only')
                            : '${a.amount!.toStringAsFixed(utxo != null ? 2 : 6)} ${a.symbol}',
                        style: a.amount == null ? muted : t.textTheme.bodyLarge,
                      ),
                      if (a.amount != null && prices[a.symbol] != null)
                        Text('  \$${(a.amount! * prices[a.symbol]!.usd).toStringAsFixed(2)}', style: muted),
                    ],
                  ),
                ),
              if (keyed != null && !keyed.backedUp)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 16, color: t.colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Not backed up yet: open the wallet to write down its ${keyed.backupName}.',
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              if (balance != null && (balance.immature > 0 || balance.pending > 0))
                Text(
                  [
                    if (balance.confirmed > 0 || balance.immature > 0) 'Spendable ${coins(balance.confirmed)}',
                    if (balance.immature > 0) 'maturing ${coins(balance.immature)} (mined)',
                    if (balance.pending > 0) 'incoming ${coins(balance.pending)}',
                  ].join(', '),
                  style: muted,
                ),
              if (xs != null && (xs.balance > xs.unlocked || xs.pendingIn > 0) && xmrWallet != null && !xmrWallet.viewOnly)
                Text(
                  [
                    'Spendable ${xmrAmount(xs.unlocked)}',
                    if (xs.balance > xs.unlocked) 'locked ${xmrAmount(xs.balance - xs.unlocked)}',
                    if (xs.pendingIn > 0) 'incoming ${xmrAmount(xs.pendingIn)}',
                  ].join(', '),
                  style: muted,
                ),
              if (mined != null && w is MoneroWatchWallet)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Mining payouts seen by this app: ${xmr(mined)} XMR'
                    '${price == null ? '' : ' (\$${(mined / 1e12 * price).toStringAsFixed(2)})'}',
                    style: muted,
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: w.canReceive
                        ? () => utxo != null
                            ? showReceive(context, utxo)
                            : (xmrWallet != null ? showMoneroReceive(context, xmrWallet) : _receive(context))
                        : null,
                    icon: const Icon(Icons.call_received),
                    label: const Text('Receive'),
                  ),
                  Tooltip(
                    message: w.sendUnavailable ?? '',
                    child: FilledButton.tonalIcon(
                      onPressed: !w.canSend
                          ? null
                          : utxo != null
                              ? () => showSend(context, app, utxo)
                              : (xmrWallet != null ? () => showMoneroSend(context, app, xmrWallet) : null),
                      icon: const Icon(Icons.call_made),
                      label: const Text('Send'),
                    ),
                  ),
                ],
              ),
              if (!w.canSend && w.sendUnavailable != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(w.sendUnavailable!, style: muted),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = TextEditingController(text: w.label);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) app.renameWallet(w, name.text.trim());
  }

  Future<void> _addViewKey(BuildContext context) async {
    final key = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Private view key'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('With the private view key (64 hex characters, in your wallet\'s keys) this app scans the '
                  'chain for this address: incoming payments and P2Pool payouts, not spends. It cannot spend.'),
              TextField(controller: key, decoration: InputDecoration(labelText: 'Private view key', errorText: error)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final e = await app.addMoneroViewKey(w.label, w.address, key.text);
                if (e == null) {
                  if (context.mounted) Navigator.pop(context);
                } else {
                  setDialog(() => error = e);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final miner = app.minerPaying(w);
    final keyed = w is KeyedWallet;
    final t = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${w.label}?'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(keyed
                ? 'This deletes the wallet\'s encrypted keys and its history from this device for good; the app '
                    'does not make it again. Without its ${(w as KeyedWallet).backupName} the coins in it are lost, so '
                    'show them from the wallet\'s page first if you have not written them down.'
                : 'This removes the address from the list. Nothing is lost: the app only watched it.'),
            if (miner != null) ...[
              const SizedBox(height: 12),
              Text(
                'The $miner miner pays this address (it is typed in the miner\'s settings). Change its payout '
                'address first, or its payouts will go to a wallet you no longer have.',
                style: TextStyle(color: t.colorScheme.error),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await app.removeWallet(w);
  }

  void _receive(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Receive ${w.symbol}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send only ${w.chainName} (${w.symbol}) to this address:'),
              const SizedBox(height: 12),
              SelectableText(w.address, style: const TextStyle(fontFamily: 'monospace')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: w.address));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      ),
    );
  }

  static String _short(String a) => a.length > 20 ? '${a.substring(0, 8)}...${a.substring(a.length - 8)}' : a;
}

class _Badge extends StatelessWidget {
  final String symbol;
  const _Badge(this.symbol);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primaryContainer,
        border: Border.all(color: c.outlineVariant),
      ),
      child: Text(
        symbol,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.onPrimaryContainer),
      ),
    );
  }
}
