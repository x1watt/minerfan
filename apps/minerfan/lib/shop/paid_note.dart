// What the customer hands back after paying.
//
//   minerfan-paid:1.<payload>.<signature>
//
// The payload is base64url of JSON {r: reference, c: chain, t: txid,
// u: units, ts: seconds} and the signature is the XPRS short Schnorr over
// sha256 of everything before the last dot, exactly as a contact card is
// signed (contacts/contact_card.dart), so the note speaks for the device
// that made it.
//
// The note is a hint, never proof: the shop looks the txid up in its own
// wallet before it settles anything. What it buys is certainty about
// *which* bill a payment belongs to, which the chain cannot tell us,
// since the description in a payment code stays in the wallet that pays.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xprs_wire/xprs_wire.dart';

/// A customer's word that a bill was paid.
class PaidNote {
  static const prefix = 'minerfan-paid:1.';

  final String reference;
  final String chain;
  final String txid;
  final int units;

  /// Seconds since the epoch.
  final int time;

  /// Who signed it (npub), so a shop can name the customer if it wants.
  final String npub;

  const PaidNote({
    required this.reference,
    required this.chain,
    required this.txid,
    required this.units,
    required this.time,
    required this.npub,
  });
}

/// Signs a note with this device's station key.
String buildPaidNote(
  String privateKeyHex, {
  required String reference,
  required String chain,
  required String txid,
  required int units,
  int? time,
}) {
  final pub = NostrCrypto.derivePublicKey(privateKeyHex);
  final payload = _b64(utf8.encode(jsonEncode({
    'r': reference,
    'c': chain,
    't': txid,
    'u': units,
    'ts': time ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'k': NostrCrypto.encodeNpub(pub),
  })));
  final head = '${PaidNote.prefix}$payload';
  final sig = XprsCrypto.sign(NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(head))),
      BigInt.parse(privateKeyHex, radix: 16));
  return '$head.${_b64(sig)}';
}

/// [text] as a note whose signature checks out, or null.
PaidNote? parsePaidNote(String text) {
  final t = text.trim();
  if (!t.startsWith(PaidNote.prefix)) return null;
  final cut = t.lastIndexOf('.');
  if (cut <= PaidNote.prefix.length) return null;
  final head = t.substring(0, cut);
  try {
    final sig = _unb64(t.substring(cut + 1));
    if (sig.length != 48) return null;
    final m = (jsonDecode(utf8.decode(_unb64(head.substring(PaidNote.prefix.length)))) as Map)
        .cast<String, Object?>();
    final npub = '${m['k'] ?? ''}';
    final key = NostrCrypto.decodeNpub(npub);
    final ok = XprsCrypto.verify(
      NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(head))),
      sig,
      Uint8List.fromList(_hex(key)),
    );
    if (!ok) return null;
    final units = m['u'];
    if (m['r'] is! String || m['c'] is! String || m['t'] is! String || units is! num) return null;
    return PaidNote(
      reference: m['r']! as String,
      chain: m['c']! as String,
      txid: m['t']! as String,
      units: units.toInt(),
      time: (m['ts'] as num?)?.toInt() ?? 0,
      npub: npub,
    );
  } catch (_) {
    return null;
  }
}

// Curve math and base64: off the UI isolate, and top level so the
// closure carries only its arguments.
Future<String> buildPaidNoteInBackground(
  String privateKeyHex, {
  required String reference,
  required String chain,
  required String txid,
  required int units,
}) =>
    Isolate.run(() => buildPaidNote(
          privateKeyHex,
          reference: reference,
          chain: chain,
          txid: txid,
          units: units,
        ));

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) & ~3, '='));

List<int> _hex(String h) => [
      for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
    ];
