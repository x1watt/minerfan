import 'package:flutter/material.dart';
import 'package:utxo_core/utxo_core.dart' show Address;
import '../wallets/monero_wallet.dart' show validMoneroAddress;

import '../chains/utxo_chain.dart';

/// A kind of contact field the app knows: how to show it and, for wallets,
/// how to check the address. A field of any other type is kept and shown
/// with its own name; the list only helps.
class FieldType {
  final String id;
  final String label;
  final IconData icon;
  final String hint;

  /// For wallet addresses: the chain id a wallet of this app uses, so its
  /// send form can offer the contact.
  final String? chain;
  final String? Function(String value)? check;
  const FieldType(this.id, this.label, this.icon, this.hint, {this.chain, this.check});
}

String? _monero(String v) => validMoneroAddress(v.trim()) ? null : 'Not a Monero address';
String? _cesc(String v) =>
    Address.parse(v.trim(), cryptoescudoCoin.params) == null ? 'Not a Cryptoescudo address' : null;
String? _i2p(String v) =>
    RegExp(r'^[a-z2-7]{52}\.b32\.i2p$').hasMatch(v.trim().toLowerCase()) ? null : 'Not a .b32.i2p address';

final List<FieldType> fieldTypes = [
  const FieldType(
    'monero',
    'Monero wallet',
    Icons.account_balance_wallet_outlined,
    '4... or 8... (95 characters)',
    chain: 'monero',
    check: _monero,
  ),
  const FieldType(
    'cryptoescudo',
    'Cryptoescudo wallet',
    Icons.account_balance_wallet_outlined,
    'C...',
    chain: 'cryptoescudo',
    check: _cesc,
  ),
  const FieldType('i2p', 'I2P address', Icons.shield_outlined, '<52 characters>.b32.i2p', check: _i2p),
  const FieldType('website', 'Website', Icons.language, 'https://...'),
  const FieldType('email', 'Email', Icons.alternate_email, 'name@example.org'),
  const FieldType('irc', 'IRC', Icons.forum_outlined, 'nick@network, for example joao@libera.chat'),
  const FieldType('matrix', 'Matrix', Icons.forum_outlined, '@name:server'),
  const FieldType('xmpp', 'XMPP', Icons.chat_bubble_outline, 'name@server'),
  const FieldType('phone', 'Phone', Icons.phone_outlined, '+351 ...'),
  const FieldType('nostr-relay', 'NOSTR relay', Icons.hub_outlined, 'wss://...'),
];

FieldType? fieldType(String id) {
  for (final t in fieldTypes) {
    if (t.id == id) return t;
  }
  return null;
}

String fieldLabel(String id) => fieldType(id)?.label ?? (id.isEmpty ? 'Field' : id[0].toUpperCase() + id.substring(1));
IconData fieldIcon(String id) => fieldType(id)?.icon ?? Icons.label_outline;

/// The wallet field type of a wallet chain (`monero`, `cryptoescudo`).
String walletFieldType(String chain) => chain;
