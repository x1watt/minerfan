import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:xprs_wire/xprs_wire.dart';

import 'contact.dart';
import 'qr_decode.dart';

/// A contact card, the text a QR code carries:
///
/// ```
/// xprs-contact:1.<payload>.<signature>
/// ```
///
/// `payload` is base64url (no padding) of a JSON object: `k` the npub, `c`
/// the callsign, `n` the name, `f` the fields as `[type, value, label?]`,
/// `t` when it was made (seconds). `signature` is base64url of the XPRS
/// short-Schnorr signature (48 bytes, docs XPRS.md 9.1.2) over sha256 of
/// everything before the last dot, made with the key in `k`. So a card
/// proves its fields were published by whoever holds that key: nobody can
/// hand out a card with someone's npub and their own wallet address.
///
/// Unknown payload keys are allowed (and signed), for later versions.
class ContactCard {
  static const prefix = 'xprs-contact:1.';

  final String npub;
  final String callsign;
  final String name;
  final List<ContactField> fields;
  final DateTime made;
  ContactCard(this.npub, this.callsign, this.name, this.fields, this.made);

  /// A new contact from this card.
  Contact toContact() => Contact(
        npub: npub,
        callsign: callsign,
        name: name,
        fields: [for (final f in fields) ContactField(f.type, f.value, label: f.label)],
        verified: true,
      );

  /// Signs a card with the private key [privateKeyHex] (curve math: run it
  /// off the UI isolate).
  static String encode(String privateKeyHex,
      {String? callsign, String name = '', List<ContactField> fields = const [], int? time}) {
    final pub = NostrCrypto.derivePublicKey(privateKeyHex);
    final npub = NostrCrypto.encodeNpub(pub);
    final payload = <String, Object?>{
      'k': npub,
      'c': Contact.checkedCallsign(npub, callsign),
      if (name.trim().isNotEmpty) 'n': name.trim(),
      'f': [
        for (final f in fields)
          if (f.value.trim().isNotEmpty) [f.type, f.value.trim(), if (f.label.trim().isNotEmpty) f.label.trim()],
      ],
      't': time ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    final head = '$prefix${_b64(utf8.encode(jsonEncode(payload)))}';
    final sig = XprsCrypto.sign(_digest(head), BigInt.parse(privateKeyHex, radix: 16));
    return '$head.${_b64(sig)}';
  }

  /// The card in [text] with its signature checked, or null when it is not
  /// a card, is damaged or the signature does not match its key. A bare
  /// `npub1...` is not a card: use [Contact.parseKey] for that.
  static ContactCard? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    final dot = t.lastIndexOf('.');
    if (dot <= prefix.length) return null;
    try {
      final head = t.substring(0, dot);
      final sig = _unb64(t.substring(dot + 1));
      final payload = jsonDecode(utf8.decode(_unb64(head.substring(prefix.length)))) as Map<String, Object?>;
      final npub = '${payload['k']}';
      final hex = Contact.keyHex(npub);
      if (hex == null || sig.length != 48) return null;
      if (!XprsCrypto.verify(_digest(head), sig, Uint8List.fromList(HEX.decode(hex)))) return null;
      final fields = <ContactField>[];
      for (final f in (payload['f'] as List?) ?? const []) {
        if (f is List && f.length >= 2) {
          fields.add(ContactField('${f[0]}', '${f[1]}', label: f.length > 2 ? '${f[2]}' : ''));
        }
      }
      return ContactCard(
        npub,
        Contact.checkedCallsign(npub, payload['c'] as String?),
        '${payload['n'] ?? ''}',
        fields,
        DateTime.fromMillisecondsSinceEpoch(((payload['t'] as num?) ?? 0).toInt() * 1000),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _digest(String head) => NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(head)));
  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
  static Uint8List _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) & ~3, '='));
}

/// Merges a verified card into an existing contact: the name when there is
/// none, and every card field that is not there yet. Fields typed in here
/// stay. Returns how many fields were added.
int mergeCard(Contact c, ContactCard card) {
  var added = 0;
  if (c.name.trim().isEmpty) c.name = card.name;
  c.callsign = card.callsign;
  for (final f in card.fields) {
    if (!c.fields.any((x) => x.sameAs(f))) {
      c.fields.add(ContactField(f.type, f.value, label: f.label));
      added++;
    }
  }
  c.verified = true;
  c.updated = DateTime.now();
  return added;
}

/// [ContactCard.parse] on a short-lived isolate (signature check).
Future<ContactCard?> parseCardInBackground(String text) => Isolate.run(() => ContactCard.parse(text));

/// A signed card whose QR code this app's reader finds. A few QR layouts in
/// a hundred defeat zxing2's finder-pattern search even when perfectly
/// drawn; the card's time is part of what it encodes, so the next second
/// gives another layout. Curve math and a decode: run it off the UI isolate.
String encodeReadableCard(String privateKeyHex, String name, List<ContactField> fields) {
  final t0 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var card = '';
  for (var i = 0; i < 8; i++) {
    card = ContactCard.encode(privateKeyHex, name: name, fields: fields, time: t0 + i);
    if (qrReadable(card)) break;
  }
  return card;
}

/// [encodeReadableCard] on a short-lived isolate.
Future<String> encodeCardInBackground(String privateKeyHex, String name, List<ContactField> fields) =>
    Isolate.run(() => encodeReadableCard(privateKeyHex, name, fields));
