import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../contacts/contact.dart';
import '../contacts/contact_card.dart';
import '../network/network_keys.dart';
import '../wallets/keyed_wallet.dart';
import '../wallets/monero_wallet.dart';
import '../wallets/wallet.dart';
import 'widgets.dart';
import 'field_types.dart';
import 'fields_editor.dart';

/// This device's card: a QR code others scan to add you, signed with the
/// station key (your npub and callsign), with the name and addresses you
/// choose to share. The first time, the app fills in its own wallets'
/// addresses; you can remove any of them.
class MyCardPage extends StatefulWidget {
  final AppController app;
  const MyCardPage(this.app, {super.key});

  @override
  State<MyCardPage> createState() => _MyCardPageState();
}

class _MyCardPageState extends State<MyCardPage> {
  XprsStation? _me;
  String? _card;
  String? _error;
  late final _name = TextEditingController(text: widget.app.contacts.myName);
  final _editor = GlobalKey<FieldsEditorState>();
  Timer? _debounce;
  int _signing = 0;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  /// Receive addresses of the wallets whose keys this app holds, one per
  /// wallet, and the I2P address while the node is up.
  List<ContactField> _suggestions() {
    final out = <ContactField>[];
    final mine = [
      for (final Wallet w in app.wallets)
        if (w is KeyedWallet && !(w is MoneroWallet && w.viewOnly) && w.canReceive) w,
    ];
    for (final w in mine) {
      // A label only tells wallets of the same coin apart.
      final several = mine.where((x) => x.chain == w.chain).length > 1;
      out.add(ContactField(walletFieldType(w.chain), w.address, label: several ? w.label : ''));
    }
    final i2p = app.privateNetwork.address;
    if (i2p != null) out.add(ContactField('i2p', i2p));
    return out;
  }

  Future<void> _load() async {
    try {
      final keys = await app.privateNetwork.keys();
      final book = app.contacts;
      if (!book.myCardStarted) {
        // Automate the first card: this device's wallets, ready to share.
        final seen = <String>{};
        for (final f in _suggestions()) {
          if (f.type != 'i2p' && seen.add(f.type)) book.myFields.add(f);
        }
        book.myCardStarted = true;
        await book.save();
      }
      if (!mounted) return;
      setState(() => _me = keys.station);
      await _sign();
    } catch (e) {
      if (mounted) setState(() => _error = 'Your key did not load: $e');
    }
  }

  Future<void> _sign() async {
    final me = _me;
    if (me == null) return;
    final n = ++_signing;
    final priv = me.privateKeyHex, name = app.contacts.myName;
    final fields = [
      for (final f in app.contacts.myFields)
        if (f.value.trim().isNotEmpty) ContactField(f.type, f.value, label: f.label),
    ];
    // A signature is curve math: off the UI isolate.
    final card = await encodeCardInBackground(priv, name, fields);
    if (mounted && n == _signing) setState(() => _card = card);
  }

  void _changed() {
    app.contacts.myName = _name.text.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(app.contacts.save());
      unawaited(_sign());
    });
    setState(() {});
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final me = _me;
    final card = _card;
    final missing = [
      for (final f in _suggestions())
        if (!app.contacts.myFields.any((x) => x.sameAs(f))) f,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Your card')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
          Center(child: QrCard(card)),
          const SizedBox(height: 12),
          if (me != null) ...[
            Center(child: Text(me.callsign, style: t.textTheme.headlineSmall?.copyWith(color: t.colorScheme.primary))),
            Center(
              child: SelectableText(me.npub,
                  textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: card == null ? null : () => _copy(card, 'Card'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy the card'),
            ),
            if (me != null)
              OutlinedButton.icon(
                onPressed: () => _copy(me.npub, 'Public key'),
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('Copy the key'),
              ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Whoever scans this code or gets the copied card adds you with this key, its callsign and the addresses '
            'below. The card is signed with your key, so nobody can hand out one with your key and other addresses.',
            style: muted,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Your name (optional)'),
            onChanged: (_) => _changed(),
          ),
          const SizedBox(height: 16),
          Text('What the card shares', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
          FieldsEditor(app.contacts.myFields, key: _editor, onChanged: _changed),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Add from this device', style: muted),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in missing)
                ActionChip(
                  avatar: Icon(fieldIcon(f.type), size: 16),
                  label: Text(f.label.isEmpty ? fieldLabel(f.type) : '${fieldLabel(f.type)}: ${f.label}'),
                  onPressed: () {
                    app.contacts.myFields.add(ContactField(f.type, f.value, label: f.label));
                    _changed();
                  },
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}
