import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:utxo_core/utxo_core.dart';

import '../app_controller.dart';
import '../format.dart';
import '../wallets/utxo_wallet.dart';
import 'contact_picker.dart';
import 'wallet_keys_ui.dart';

/// One SPV wallet: balance, receive and send on one tab, the history on
/// another.
class UtxoWalletPage extends StatelessWidget {
  final AppController app;
  final UtxoWallet w;
  const UtxoWalletPage(this.app, this.w, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([w.service, w]),
      builder: (context, _) {
        final t = Theme.of(context);
        final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
        final s = w.status;
        final chain = w.service.status;
        final b = s?.balance;
        final sym = w.symbol;
        final history = s?.history ?? const <WalletTx>[];
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: Text(w.label),
              bottom: TabBar(
                tabs: [
                  const Tab(text: 'Wallet'),
                  Tab(text: history.isEmpty ? 'History' : 'History (${history.length})'),
                ],
              ),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'phrase') showRecoveryPhrase(context, app, w);
                    if (v == 'password') changePassword(context, app, w);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'phrase', child: Text('Show the recovery words')),
                    PopupMenuItem(
                      value: 'password',
                      child: Text(w.hasPassword ? 'Change or remove the password' : 'Set a password'),
                    ),
                  ],
                ),
              ],
            ),
            body: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (!w.backedUp) BackupReminder(app, w),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Spendable',
                              style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                b == null ? '...' : '${coins(b.confirmed)} $sym',
                                style: t.textTheme.displaySmall?.copyWith(color: t.colorScheme.primary),
                              ),
                            ),
                            if (b != null && b.immature > 0)
                              Text(
                                'Maturing: ${coins(b.immature)} $sym (mined, spendable after ${w.coin.params.coinbaseMaturity} '
                                'confirmations)',
                              ),
                            if (b != null && b.pending > 0) Text('Incoming, unconfirmed: ${coins(b.pending)} $sym'),
                            const SizedBox(height: 8),
                            Text(
                              chain == null
                                  ? 'Connecting to the ${w.chainName} network...'
                                  : (s == null || s.scanned < chain.tip
                                        ? 'Scanning blocks: ${s?.scanned ?? '...'} of ${chain.tip} (${chain.peers} peers)'
                                        : 'Up to date at block ${chain.tip} (${chain.peers} peers)'),
                              style: muted,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: () => showReceive(context, w),
                                  icon: const Icon(Icons.call_received),
                                  label: const Text('Receive'),
                                ),
                                FilledButton.tonalIcon(
                                  onPressed: w.canSend ? () => showSend(context, app, w) : null,
                                  icon: const Icon(Icons.call_made),
                                  label: const Text('Send'),
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
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'This wallet checks the chain itself: it asks peers for the blocks that match its addresses (a '
                        'bloom filter) and verifies each transaction\'s merkle proof against the headers it validated. Its '
                        'recovery words are stored encrypted (ChaCha20-Poly1305) with ${w.hasPassword ? 'your password '
                                  '(Argon2id)' : 'this device\'s key; set a password in the menu to protect them further'}. '
                        'Wallets restored from recovery words see transactions from block ${w.coin.checkpointHeight} on.',
                        style: muted,
                      ),
                    ),
                  ],
                ),
                history.isEmpty
                    ? const Center(child: Text('No transactions yet.'))
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [for (final tx in history) _TxTile(w, tx, chain?.tip ?? 0)],
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TxTile extends StatelessWidget {
  final UtxoWallet w;
  final WalletTx tx;
  final int tip;
  const _TxTile(this.w, this.tx, this.tip);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final h = tx.height;
    final conf = h == null ? 0 : tip - h + 1;
    final state = h == null
        ? 'unconfirmed'
        : (tx.coinbase && conf < w.coin.params.coinbaseMaturity
              ? 'maturing, $conf of ${w.coin.params.coinbaseMaturity}'
              : 'block $h');
    return ListTile(
      dense: true,
      leading: Icon(tx.coinbase ? Icons.bolt : (tx.net >= 0 ? Icons.call_received : Icons.call_made)),
      title: Text('${tx.coinbase ? 'Mined' : (tx.net >= 0 ? 'Received' : 'Sent')}  ·  $state'),
      subtitle: Text('${tx.txid.substring(0, 16)}...', style: const TextStyle(fontFamily: 'monospace')),
      trailing: Text(
        '${tx.net >= 0 ? '+' : ''}${coins(tx.net)} ${w.symbol}',
        style: t.textTheme.bodyLarge?.copyWith(color: tx.net >= 0 ? t.colorScheme.primary : null),
      ),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: tx.txid));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transaction id copied')));
      },
    );
  }
}

void showReceive(BuildContext context, UtxoWallet w) {
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
            const SizedBox(height: 12),
            const Text('A new address appears once this one has received coins; older ones keep working.'),
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

Future<void> showSend(BuildContext context, AppController app, UtxoWallet w) async {
  final txid = await showDialog<String>(context: context, builder: (_) => _SendDialog(app, w));
  if (txid == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sent'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The transaction went to the network. It shows as unconfirmed until a block includes it.'),
            const SizedBox(height: 12),
            SelectableText(txid, style: const TextStyle(fontFamily: 'monospace')),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    ),
  );
}

class _SendDialog extends StatefulWidget {
  final AppController app;
  final UtxoWallet w;
  const _SendDialog(this.app, this.w);

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _to = TextEditingController();
  final _amount = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  String? _fee;
  bool _busy = false;
  Timer? _debounce;

  UtxoWallet get w => widget.w;

  @override
  void dispose() {
    _debounce?.cancel();
    _to.dispose();
    _amount.dispose();
    _password.dispose();
    super.dispose();
  }

  int? get _units => parseCoins(_amount.text, decimals: w.coin.decimals);

  void _preview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final units = _units;
      final h = w.service.handle;
      if (units == null || h == null) {
        setState(() => _fee = null);
        return;
      }
      try {
        final (fee, _) = await h.preview(w.id, units);
        if (mounted) setState(() => _fee = 'Fee ${coins(fee)} ${w.symbol}, total ${coins(units + fee)} ${w.symbol}');
      } catch (e) {
        if (mounted) setState(() => _fee = '$e');
      }
    });
  }

  Future<void> _send() async {
    final to = _to.text.trim();
    final units = _units;
    if (Address.parse(to, w.coin.params) == null) return setState(() => _error = 'Not a ${w.chainName} address');
    if (units == null) return setState(() => _error = 'Enter an amount');
    final h = w.service.handle;
    if (h == null) return setState(() => _error = 'Not connected to the network');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final xprv = await w.unlock(w.hasPassword ? _password.text : null);
      if (xprv == null) {
        setState(() => _error = 'Wrong password');
        return;
      }
      final txid = await h.send(w.id, to, units, xprv);
      if (mounted) Navigator.pop(context, txid);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spendable = w.status?.balance.confirmed ?? 0;
    return AlertDialog(
      title: Text('Send ${w.symbol}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spendable: ${coins(spendable)} ${w.symbol}'),
            TextField(
              controller: _to,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'To address',
                helperText: contactHint(widget.app, w.chain, _to.text),
                suffixIcon: IconButton(
                  tooltip: 'Choose a contact',
                  icon: const Icon(Icons.contacts_outlined),
                  onPressed: () async {
                    final a = await pickContactAddress(context, widget.app, w.chain);
                    if (a != null) setState(() => _to.text = a);
                  },
                ),
              ),
            ),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Amount (${w.symbol})', helperText: _fee),
              onChanged: (_) => _preview(),
            ),
            if (w.hasPassword)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Wallet password'),
                onSubmitted: (_) => _busy ? null : _send(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send'),
        ),
      ],
    );
  }
}
