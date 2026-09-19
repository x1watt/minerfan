import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xprs_wire/xprs_wire.dart' show NostrCrypto;

import '../network/network_keys.dart';
import '../network/private_network.dart';

/// The secret key as the user may type it: 64 hex characters, or the nsec a
/// NOSTR client shows. Returns null when it is neither.
String? accountKeyHex(String input) {
  final s = input.trim();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return s.toLowerCase();
  if (s.toLowerCase().startsWith('nsec1')) {
    try {
      final hex = NostrCrypto.decodeNsec(s.toLowerCase()).toLowerCase();
      return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
    } catch (_) {
      return null;
    }
  }
  return null;
}

// Curve math, so it runs off the UI isolate.
Future<String> _callsignOf(String hex) => Isolate.run(() => XprsStation(hex).callsign);

/// The account rows of the private network settings: back up this account
/// (its nsec, shown only after a tap) and move another account here.
class AccountRows extends StatefulWidget {
  final PrivateNetwork network;
  const AccountRows(this.network, {super.key});

  @override
  State<AccountRows> createState() => _AccountRowsState();
}

class _AccountRowsState extends State<AccountRows> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final station = widget.network.station;
    if (station == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        SizedBox(width: 92, child: Text('Secret key', style: t.textTheme.bodySmall)),
        Expanded(
          child: _shown
              ? SelectableText(station.nsec, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))
              : Text('hidden', style: muted),
        ),
        if (_shown)
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: station.nsec));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Secret key copied')));
            },
          ),
        TextButton(
          onPressed: () => _shown ? setState(() => _shown = false) : _reveal(),
          child: Text(_shown ? 'Hide' : 'Back up'),
        ),
      ]),
      if (_shown)
        Text(
          'This is the whole account. Anyone who has it can sign as ${station.callsign}, read the messages sent to '
          'this callsign and take it over on another device. Keep it where you keep your wallet words, and do not '
          'send it to anyone.',
          style: muted,
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: _importSheet, child: const Text('Use another account')),
      ),
    ]);
  }

  Future<void> _reveal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Show the secret key?'),
        content: const Text(
            'The secret key is this account itself: whoever holds it can sign and read as this callsign. Show it '
            'only when nobody else can see the screen, and write it down somewhere safe.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Show it')),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _shown = true);
  }

  Future<void> _importSheet() async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ImportSheet(widget.network),
    );
    if (done == true && mounted) setState(() => _shown = false);
  }
}

class _ImportSheet extends StatefulWidget {
  final PrivateNetwork network;
  const _ImportSheet(this.network);

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _field = TextEditingController();
  String? _hex;
  String? _callsign;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final hex = accountKeyHex(_field.text);
    if (hex == null) {
      setState(() {
        _hex = null;
        _callsign = null;
        _error = 'That is not a secret key. Paste the nsec, or the 64 characters of the key.';
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final callsign = await _callsignOf(hex);
      if (!mounted) return;
      setState(() {
        _hex = hex;
        _callsign = callsign;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hex = null;
        _callsign = null;
        _error = 'That key is not on the curve NOSTR uses.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use() async {
    final hex = _hex;
    if (hex == null) return;
    setState(() => _busy = true);
    try {
      await widget.network.useStation(hex);
      if (!mounted) return;
      Navigator.pop(context, true);
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('This device signs as $_callsign'),
          content: const Text(
              'The old key was kept aside in the app folder. Start minerfan again so the callsign, the chat '
              'rooms and the contact card follow the new account.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Use another account', style: t.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'Type or paste the secret key of an account you already have, as an nsec or as 64 characters. This '
          'device then signs everything with it and the account here is kept aside.',
          style: muted,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _field,
          autofocus: true,
          maxLines: 2,
          minLines: 1,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(labelText: 'nsec1... or 64 characters', border: OutlineInputBorder()),
          onChanged: (_) => setState(() {
            _hex = null;
            _callsign = null;
            _error = null;
          }),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
        ],
        if (_callsign != null) ...[
          const SizedBox(height: 8),
          Text('This key signs as $_callsign.', style: t.textTheme.bodyMedium),
        ],
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          if (_callsign == null)
            FilledButton(onPressed: _busy ? null : _check, child: const Text('Check this key'))
          else
            FilledButton(onPressed: _busy ? null : _use, child: Text('Sign as $_callsign')),
        ]),
      ]),
    );
  }
}
