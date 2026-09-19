import 'package:crypto_core/crypto_core.dart' show Bip39;
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../chains/utxo_chain.dart';
import 'widgets.dart';

/// Adds wallets, as many per blockchain as the user wants: pick the chain,
/// then what to do (create, restore, view-only, watch an address), then a
/// short form.
class AddWalletPage extends StatefulWidget {
  final AppController app;
  const AddWalletPage(this.app, {super.key});

  @override
  State<AddWalletPage> createState() => _AddWalletPageState();
}

class _AddWalletPageState extends State<AddWalletPage> {
  String? _chain;
  String? _mode; // new, restore, view, address
  bool _wroteDown = false;
  bool _busy = false;
  bool _usePassword = false;
  String? _error;
  final _label = TextEditingController();
  final _address = TextEditingController();
  final _phrase = TextEditingController();
  final _viewKey = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  late String _newPhrase = Bip39.generate(words: 12);
  final _scroll = ScrollController();

  /// Brings the next step into view after a choice.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
        }
      });

  AppController get app => widget.app;
  UtxoCoin? get _coin => app.chains[_chain]?.coin;
  bool get _monero => _chain == 'monero';

  @override
  void dispose() {
    for (final c in [_label, _address, _phrase, _viewKey, _password, _password2]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  List<(String, String, String, IconData)> get _chains => [
        ('monero', 'Monero (XMR)', 'Private payments; P2Pool mining payouts arrive directly.', Icons.shield_outlined),
        for (final c in app.chains.values)
          (c.coin.id, '${c.coin.name} (${c.coin.symbol})', 'Solo mining pays blocks straight into it.', Icons.token_outlined),
      ];

  List<(String, String, String, IconData)> get _modes => [
        ('new', 'Create a new wallet', 'New keys on this device, with recovery words to write down.', Icons.add_circle_outline),
        (
          'restore',
          'Restore from recovery words',
          _monero ? 'The 25 words of a Monero wallet.' : 'A 12 to 24 word recovery phrase (BIP39).',
          Icons.restore
        ),
        if (_monero)
          (
            'view',
            'View-only',
            'An address and its private view key: see payments and mining payouts, cannot spend.',
            Icons.visibility_outlined
          ),
        if (_monero) ('address', 'Watch an address', 'Receive only; the balance stays unknown without keys.', Icons.alternate_email),
      ];

  Future<void> _add() async {
    final password = _usePassword && _password.text.isNotEmpty ? _password.text : null;
    if (_usePassword && _mode != 'address') {
      if (_password.text.length < 8) return setState(() => _error = 'The password needs at least 8 characters');
      if (_password.text != _password2.text) return setState(() => _error = 'The passwords differ');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? e;
    try {
      if (_monero) {
        e = switch (_mode) {
          'new' => await app.createMoneroWallet(_label.text, password: password),
          'restore' => await app.restoreMoneroWallet(_label.text, _phrase.text, password: password),
          'view' => await app.addMoneroViewKey(_label.text, _address.text, _viewKey.text, password: password),
          _ => app.addWallet('monero', _label.text, _address.text),
        };
      } else {
        final restore = _mode == 'restore';
        e = await app.addUtxoWallet(_coin!, _label.text, restore ? _phrase.text : _newPhrase,
            password: password, restore: restore, backedUp: restore || _wroteDown);
      }
    } catch (err) {
      e = '$err';
    }
    if (!mounted) return;
    if (e == null) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wallet added')));
    } else {
      setState(() {
        _busy = false;
        _error = e;
      });
    }
  }

  Widget _choice(String value, String title, String subtitle, IconData icon, String? selected, ValueChanged<String> onTap,
      {bool enabled = true}) {
    final c = Theme.of(context).colorScheme;
    final on = value == selected;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: on ? c.primary : c.outlineVariant, width: on ? 2 : 1),
      ),
      child: ListTile(
        enabled: enabled && !_busy,
        leading: Icon(icon, color: on ? c.primary : null),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: on ? Icon(Icons.check_circle, color: c.primary) : null,
        onTap: () => onTap(value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Add a wallet')),
      body: SafeArea(
        child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          const SectionTitle('1. Blockchain'),
          for (final (id, title, sub, icon) in _chains)
            _choice(id, title, sub, icon, _chain, (v) => setState(() {
                  _chain = v;
                  if (!_monero && (_mode == 'view' || _mode == 'address')) _mode = null;
                  _error = null;
                  _reveal();
                })),
          _choice('ethereum', 'Ethereum (ETH) and tokens', 'Planned.', Icons.hexagon_outlined, _chain, (_) {},
              enabled: false),
          if (_chain != null) ...[
            const SectionTitle('2. What to do'),
            for (final (id, title, sub, icon) in _modes)
              _choice(id, title, sub, icon, _mode, (v) => setState(() {
                    _mode = v;
                    _error = null;
                    _reveal();
                  })),
          ],
          if (_chain != null && _mode != null) ...[
            const SectionTitle('3. Details'),
            TextField(controller: _label, decoration: const InputDecoration(labelText: 'Name (optional)')),
            const SizedBox(height: 8),
            ...switch (_mode) {
              'new' when _monero => [
                  Text('Its 25 recovery words are shown on the wallet page; a reminder stays until you write them '
                      'down.', style: muted),
                ],
              'new' => [
                  const Text('The recovery phrase. Write these words down in order and keep them offline: they are the '
                      'only backup of this wallet.'),
                  const SizedBox(height: 8),
                  SelectableText(_newPhrase, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
                  Row(children: [
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _newPhrase = Bip39.generate(words: 12)),
                      child: const Text('Other words'),
                    ),
                  ]),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _wroteDown,
                    onChanged: _busy ? null : (v) => setState(() => _wroteDown = v ?? false),
                    title: const Text('I wrote the words down (you can also do it later)'),
                  ),
                ],
              'restore' => [
                  TextField(
                    controller: _phrase,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                        labelText: _monero ? 'Recovery words (25 words)' : 'Recovery phrase (12 to 24 words)'),
                  ),
                  const SizedBox(height: 6),
                  Text('The wallet sees transactions from the built-in checkpoint on (a few days before this '
                      'version).', style: muted),
                ],
              'view' => [
                  TextField(controller: _address, decoration: const InputDecoration(labelText: 'Primary address')),
                  TextField(controller: _viewKey, decoration: const InputDecoration(labelText: 'Private view key (64 hex)')),
                ],
              _ => [TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address'))],
            },
            if (_mode != 'address') ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Protect with a password'),
                subtitle: const Text('Asked for every payment and to show the backup; cannot be recovered. Without '
                    'one, the keys are encrypted with the device key.'),
                value: _usePassword,
                onChanged: _busy ? null : (v) => setState(() => _usePassword = v),
              ),
              if (_usePassword) ...[
                TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                TextField(
                    controller: _password2, obscureText: true, decoration: const InputDecoration(labelText: 'Password again')),
              ],
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _add,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(switch (_mode) { 'new' => 'Create the wallet', 'restore' => 'Restore the wallet', _ => 'Add the wallet' }),
            ),
          ],
        ]),
      ),
    );
  }
}
