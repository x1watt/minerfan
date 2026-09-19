// Payment codes: the text behind the QR a shop shows and a customer scans.
//
// They are the schemes wallets already speak, so a code made here can be
// paid by any wallet, not only minerfan:
//
//   monero:<address>?tx_amount=0.0001&tx_description=...&recipient_name=...
//   cryptoescudo:<address>?amount=1000&message=...&label=...   (BIP21)
//
// The description is a note kept by the wallet that pays; it does not
// travel with the money. It carries the bill's reference so a person can
// read it, and the shop matches the payment by other means (shop/receipt
// and shop/paid_note).
//
// Pure Dart: no Flutter, no chain code. The address itself is checked by
// the caller (ui/field_types.dart knows each coin's rules).

import '../format.dart';

/// How one coin writes a payment code.
class _Scheme {
  final String chain;
  final String write;
  final List<String> read;
  final int decimals;
  final String amountKey;
  final String labelKey;
  final String messageKey;
  const _Scheme(this.chain, this.write, this.read, this.decimals, this.amountKey, this.labelKey, this.messageKey);
}

const _schemes = [
  _Scheme('monero', 'monero', ['monero'], 12, 'tx_amount', 'recipient_name', 'tx_description'),
  // CESC is Cryptoescudo's ticker; BIP21 schemes use the coin's name, and
  // the ticker is taken as well for codes from wallets that write it.
  _Scheme('cryptoescudo', 'cryptoescudo', ['cryptoescudo', 'cesc'], 8, 'amount', 'label', 'message'),
];

_Scheme? _byChain(String chain) {
  for (final s in _schemes) {
    if (s.chain == chain) return s;
  }
  return null;
}

_Scheme? _byScheme(String scheme) {
  for (final s in _schemes) {
    if (s.read.contains(scheme)) return s;
  }
  return null;
}

/// Whether payment codes can be made for [chain].
bool coinHasPaymentUri(String chain) => _byChain(chain) != null;

/// A payment asked for: who to pay, how much, and what it is for.
class PaymentRequest {
  /// Chain id (`monero`, `cryptoescudo`).
  final String chain;
  final String address;

  /// Smallest units, or null when the code leaves the amount open.
  final int? units;

  /// Who is being paid (the shop's name).
  final String label;

  /// What is being paid for, with the bill's reference.
  final String message;

  const PaymentRequest({
    required this.chain,
    required this.address,
    this.units,
    this.label = '',
    this.message = '',
  });

  @override
  String toString() => 'PaymentRequest($chain, $address, $units, $label, $message)';
}

/// The text to put in a QR code for [r].
String buildPaymentUri(PaymentRequest r) {
  final s = _byChain(r.chain);
  if (s == null) throw ArgumentError('no payment code for ${r.chain}');
  final q = <String>[
    if (r.units != null) '${s.amountKey}=${uriAmount(r.units!, s.decimals)}',
    if (r.label.trim().isNotEmpty) '${s.labelKey}=${Uri.encodeComponent(r.label.trim())}',
    if (r.message.trim().isNotEmpty) '${s.messageKey}=${Uri.encodeComponent(r.message.trim())}',
  ];
  return '${s.write}:${r.address}${q.isEmpty ? '' : '?${q.join('&')}'}';
}

/// [text] as a payment we can pay, or null. Use [paymentUriProblem] for
/// the reason to show someone.
PaymentRequest? parsePaymentUri(String text) => _parse(text).$1;

/// Why [text] cannot be paid, in one sentence, or null when it can.
String? paymentUriProblem(String text) => _parse(text).$2;

(PaymentRequest?, String?) _parse(String text) {
  final t = text.trim();
  final colon = t.indexOf(':');
  if (colon <= 0) return (null, 'This code is not a Monero or Cryptoescudo payment.');
  final s = _byScheme(t.substring(0, colon).toLowerCase());
  if (s == null) return (null, 'This code is not a Monero or Cryptoescudo payment.');

  // The address is read from the text as written: Uri lowercases what it
  // takes for a host, and base58 addresses are case sensitive.
  var rest = t.substring(colon + 1);
  final mark = rest.indexOf('?');
  final query = mark < 0 ? '' : rest.substring(mark + 1);
  if (mark >= 0) rest = rest.substring(0, mark);
  // monero:ADDRESS and monero://ADDRESS both appear in the wild.
  while (rest.startsWith('/')) {
    rest = rest.substring(1);
  }
  final address = rest.trim();
  if (address.isEmpty) return (null, 'This payment code has no address.');

  Map<String, String> q;
  try {
    q = query.isEmpty ? const {} : Uri.splitQueryString(query);
  } catch (_) {
    return (null, 'This payment code is damaged.');
  }
  for (final key in q.keys) {
    // BIP21: a wallet that does not understand a req- key must not pay.
    if (key.toLowerCase().startsWith('req-')) {
      return (null, 'This code asks for something this app does not support.');
    }
  }
  if (q.containsKey('tx_payment_id') && (q['tx_payment_id'] ?? '').isNotEmpty) {
    return (null, 'This code asks for a payment id, which this app cannot add.');
  }

  int? units;
  final amount = q[s.amountKey];
  if (amount != null && amount.trim().isNotEmpty) {
    units = parseCoins(amount, decimals: s.decimals);
    if (units == null) return (null, 'The amount in this code is not one this app can pay.');
  }
  return (
    PaymentRequest(
      chain: s.chain,
      address: address,
      units: units,
      label: q[s.labelKey] ?? '',
      message: q[s.messageKey] ?? '',
    ),
    null,
  );
}
