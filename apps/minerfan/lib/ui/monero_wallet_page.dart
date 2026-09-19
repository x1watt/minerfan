import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xmr_core/xmr_core.dart';

import '../app_controller.dart';
import '../format.dart';
import '../shop/payment_uri.dart';
import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';
import 'chat_button.dart';
import 'contact_picker.dart';
import 'wallet_keys_ui.dart';
import 'widgets.dart';

String xmrAmount(int piconero) => coins(piconero, decimals: 12);

/// One Monero wallet: balance, receive and send on one tab, the history on
/// another.
class MoneroWalletPage extends StatelessWidget {
  final AppController app;
  final MoneroWallet w;
  const MoneroWalletPage(this.app, this.w, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([w.service, w]),
      builder: (context, _) {
        final t = Theme.of(context);
        final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
        final s = w.status;
        final chain = w.service.status;
        final history = s?.history ?? const <MoneroTxEntry>[];
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
                ChatButton(app, w.chain, dense: true),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'phrase') showRecoveryPhrase(context, app, w);
                    if (v == 'password') changePassword(context, app, w);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'phrase', child: Text('Show the ${w.backupName}')),
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
                    if (!w.isOpen && w.hasPassword) _UnlockCard(app, w),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w.viewOnly ? 'Received (view-only)' : 'Spendable',
                              style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                s == null ? '...' : '${xmrAmount(w.viewOnly ? s.balance : s.unlocked)} XMR',
                                style: t.textTheme.displaySmall?.copyWith(color: t.colorScheme.primary),
                              ),
                            ),
                            if (s != null && !w.viewOnly && s.balance > s.unlocked)
                              Text(
                                'Locked: ${xmrAmount(s.balance - s.unlocked)} XMR (spendable after 10 blocks, mined coins after 60)',
                              ),
                            if (s != null && s.pendingIn > 0)
                              Text('Incoming, unconfirmed: ${xmrAmount(s.pendingIn)} XMR'),
                            const SizedBox(height: 8),
                            Text(
                              chain == null
                                  ? 'Connecting to the Monero network...'
                                  : !chain.synced
                                  ? 'Syncing the Monero chain: block ${chain.tip} (${chain.peers} peers)'
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
                                  onPressed: () => showMoneroReceive(context, w),
                                  icon: const Icon(Icons.call_received),
                                  label: const Text('Receive'),
                                ),
                                if (!w.viewOnly)
                                  FilledButton.tonalIcon(
                                    onPressed: w.canSend ? () => showMoneroSend(context, app, w) : null,
                                    icon: const Icon(Icons.call_made),
                                    label: const Text('Send'),
                                  ),
                              ],
                            ),
                            if (!w.canSend && w.sendUnavailable != null && !w.viewOnly)
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
                        'This wallet follows the Monero chain itself over the P2P network (checkpoint, difficulty and RandomX '
                        'checks) and scans each block for its outputs with the view key; nobody else sees which outputs are '
                        'yours. ${w.viewOnly ? 'A view-only wallet sees incoming payments but not spends.' : 'Sending asks the '
                                  'node in Settings for decoy outputs and the fee (${app.settings.moneroNode}); your keys never leave '
                                  'this device.'} Its ${w.backupName} are stored encrypted with '
                        '${w.hasPassword ? 'your password' : 'this device\'s key'}. Wallets restored from recovery words see '
                        'transactions from block ${checkpointEndHeight - checkpointHeaders.length + 1} on.',
                        style: muted,
                      ),
                    ),
                  ],
                ),
                history.isEmpty
                    ? const Center(child: Text('No transactions yet.'))
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [for (final tx in history) _TxTile(tx, chain?.tip ?? 0)],
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UnlockCard extends StatefulWidget {
  final AppController app;
  final MoneroWallet w;
  const _UnlockCard(this.app, this.w);

  @override
  State<_UnlockCard> createState() => _UnlockCardState();
}

class _UnlockCardState extends State<_UnlockCard> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.unlockMonero(widget.w, _password.text);
    } catch (e) {
      if (mounted) setState(() => _error = 'Wrong password');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _unlock(),
              decoration: InputDecoration(labelText: 'Password to open this wallet', errorText: _error),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(onPressed: _busy ? null : _unlock, child: const Text('Unlock')),
        ],
      ),
    ),
  );
}

class _TxTile extends StatelessWidget {
  final MoneroTxEntry tx;
  final int tip;
  const _TxTile(this.tx, this.tip);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final h = tx.height;
    final conf = h == null ? 0 : tip - h + 1;
    final lockBlocks = tx.coinbase ? 60 : 10;
    final state = h == null ? 'unconfirmed' : (conf < lockBlocks ? 'locked, $conf of $lockBlocks' : 'block $h');
    final net = tx.net;
    return ListTile(
      dense: true,
      leading: Icon(tx.coinbase ? Icons.bolt : (net >= 0 ? Icons.call_received : Icons.call_made)),
      title: Text('${tx.coinbase ? 'Mined (P2Pool)' : (net >= 0 ? 'Received' : 'Sent')}  ·  $state'),
      subtitle: Text(
        '${tx.txid.substring(0, 16)}...${tx.fee > 0 && net < 0 ? '  fee ${xmrAmount(tx.fee)}' : ''}',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      trailing: Text(
        '${net >= 0 ? '+' : ''}${xmrAmount(net)} XMR',
        style: t.textTheme.bodyLarge?.copyWith(color: net >= 0 ? t.colorScheme.primary : null),
      ),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: tx.txid));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transaction id copied')));
      },
    );
  }
}

void showMoneroReceive(BuildContext context, MoneroWallet w) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Receive XMR'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Send only Monero (XMR) to this address:'),
            const SizedBox(height: 12),
            Center(child: QrCard(buildPaymentUri(PaymentRequest(chain: w.chain, address: w.address)), size: 220)),
            const SizedBox(height: 12),
            SelectableText(w.address, style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 12),
            const Text('It is also a P2Pool payout address: mining payouts arrive here directly.'),
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

Future<void> showMoneroSend(BuildContext context, AppController app, MoneroWallet w) async {
  final r = await showDialog<(String, int)>(context: context, builder: (_) => _SendDialog(app, w));
  if (r == null || !context.mounted) return;
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
            Text(
              'The node accepted the transaction and it is on its way to the network (fee ${xmrAmount(r.$2)} XMR). '
              'It shows as unconfirmed until a block includes it.',
            ),
            const SizedBox(height: 12),
            SelectableText(r.$1, style: const TextStyle(fontFamily: 'monospace')),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    ),
  );
}

class _SendDialog extends StatefulWidget {
  final AppController app;
  final MoneroWallet w;
  const _SendDialog(this.app, this.w);

  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _to = TextEditingController();
  final _amount = TextEditingController();
  final _password = TextEditingController();
  String? _error, _fee;
  bool _busy = false;
  String _step = '';
  Timer? _debounce;

  MoneroWallet get w => widget.w;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_to, _amount, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _units => parseCoins(_amount.text, decimals: 12);

  void _preview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final units = _units, h = w.service.handle;
      if (units == null || h == null) return setState(() => _fee = null);
      try {
        final fee = await h.estimateFee(w.id, units);
        if (mounted) setState(() => _fee = 'Fee about ${xmrAmount(fee)} XMR');
      } catch (e) {
        if (mounted) setState(() => _fee = '$e');
      }
    });
  }

  Future<void> _send() async {
    final to = _to.text.trim(), units = _units;
    if (!validMoneroAddress(to)) return setState(() => _error = 'Not a Monero address');
    if (units == null) return setState(() => _error = 'Enter an amount');
    final h = w.service.handle;
    if (h == null) return setState(() => _error = 'Not connected');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (w.hasPassword) {
        setState(() => _step = 'Checking the password');
        final box = w.secret, key = w.deviceKey, pw = _password.text;
        if (await Isolate.run(() => KeyedWallet.open(box, key, pw)) == null) {
          setState(() => _error = 'Wrong password');
          return;
        }
      }
      setState(() => _step = 'Picking decoys, signing and sending (up to a minute)');
      final r = await h.send(w.id, to, units);
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = w.status;
    return AlertDialog(
      title: const Text('Send XMR'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spendable: ${xmrAmount(s?.unlocked ?? 0)} XMR'),
            TextField(
              controller: _to,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'To address',
                helperText: contactHint(widget.app, 'monero', _to.text),
                suffixIcon: IconButton(
                  tooltip: 'Choose a contact',
                  icon: const Icon(Icons.contacts_outlined),
                  onPressed: () async {
                    final a = await pickContactAddress(context, widget.app, 'monero');
                    if (a != null) setState(() => _to.text = a);
                  },
                ),
              ),
            ),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Amount (XMR)', helperText: _fee),
              onChanged: (_) => _preview(),
            ),
            if (w.hasPassword)
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Wallet password'),
              ),
            if (_busy && _step.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_step)),
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
