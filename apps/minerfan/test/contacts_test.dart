import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:minerfan/contacts/contact.dart';
import 'package:minerfan/contacts/contact_book.dart';
import 'package:minerfan/contacts/contact_card.dart';
import 'package:minerfan/contacts/qr_decode.dart';
import 'package:minerfan/wallets/monero_wallet.dart' show validMoneroAddress;
import 'package:xprs_wire/xprs_wire.dart';

// A valid mainnet address (made by the app for a test wallet).
const monero =
    '45sP4tRk9LbYHJFwWzNJoUGCXKJAzExdrb9FHFMCfGEe4z7LMXP8DDkRco7893q6SDA3pFJHsopDpZamqTEKCAC2HB4cLpq';

(Uint8List, int) qrPixels(String text, {int scale = 4}) => qrLuminance(text, scale: scale);

void main() {
  final me = NostrCrypto.generateKeyPair();
  final myFields = [
    ContactField('monero', monero, label: 'main'),
    ContactField('i2p', 'evkrojmuriz43ildfwpyhmpelz2fsck2istuy2ydhbno2wz4mrta.b32.i2p'),
    ContactField('irc', 'joao@libera.chat'),
  ];

  test('the test address is a valid Monero address', () => expect(validMoneroAddress(monero), isTrue));

  group('contact', () {
    test('keeps keys it does not know, at every level', () {
      final m = {
        'npub': me.npub,
        'callsign': me.callsign,
        'name': 'Joao',
        'pronouns': 'they/them',
        'fields': [
          {'type': 'monero', 'value': monero, 'label': 'main', 'priority': 2},
          {'type': 'matrix', 'value': '@j:example.org'},
        ],
        'added': '2026-09-15T10:00:00.000Z',
        'updated': '2026-09-15T10:00:00.000Z',
      };
      final c = Contact.fromJson(m);
      expect(c.title, 'Joao');
      expect(c.fields.first.label, 'main');
      final back = c.toJson();
      expect(back['pronouns'], 'they/them');
      expect((back['fields'] as List).first, containsPair('priority', 2));
      expect((back['fields'] as List)[1], containsPair('type', 'matrix'));
    });

    test('the callsign comes from the key', () {
      final c = Contact(npub: me.npub);
      expect(c.callsign, me.callsign);
      expect(Contact.checkedCallsign(me.npub, 'X1ZZZZ'), me.callsign, reason: 'a callsign that is not derived is replaced');
      expect(Contact.parseKey(me.publicKeyHex), me.npub);
      expect(Contact.parseKey('npub1nothing'), isNull);
      expect(ContactField('Web Site', 'x').type, 'web-site');
    });
  });

  group('card', () {
    test('signed card round trip', () {
      final text = ContactCard.encode(me.privateKeyHex, name: 'Joao', fields: myFields);
      expect(text, startsWith(ContactCard.prefix));
      final card = ContactCard.parse(text)!;
      expect(card.npub, me.npub);
      expect(card.callsign, me.callsign);
      expect(card.name, 'Joao');
      expect([for (final f in card.fields) '${f.type}=${f.value}'], [for (final f in myFields) '${f.type}=${f.value}']);
      expect(card.fields.first.label, 'main');
      final c = card.toContact();
      expect(c.verified, isTrue);
    });

    test('a changed card or someone else\'s key does not verify', () {
      final text = ContactCard.encode(me.privateKeyHex, name: 'Joao', fields: myFields);
      final dot = text.lastIndexOf('.');
      final payload = text.substring(ContactCard.prefix.length, dot);
      // Swap the Monero address for another in the signed payload.
      final json = utf8.decode(base64Url.decode(payload.padRight((payload.length + 3) & ~3, '=')));
      final forged = base64Url.encode(utf8.encode(json.replaceFirst(monero, '4${monero.substring(1, 94)}X'))).replaceAll('=', '');
      expect(ContactCard.parse('${ContactCard.prefix}$forged${text.substring(dot)}'), isNull);

      // Mallory signs a card that names someone else's key.
      final mallory = NostrCrypto.generateKeyPair();
      final theirs = ContactCard.encode(mallory.privateKeyHex, name: 'Joao', fields: myFields);
      final mjson = jsonDecode(utf8.decode(base64Url.decode(
          theirs.substring(ContactCard.prefix.length, theirs.lastIndexOf('.')).padRight(
              (theirs.lastIndexOf('.') - ContactCard.prefix.length + 3) & ~3, '=')))) as Map<String, Object?>;
      mjson['k'] = me.npub;
      final swapped = base64Url.encode(utf8.encode(jsonEncode(mjson))).replaceAll('=', '');
      expect(ContactCard.parse('${ContactCard.prefix}$swapped${theirs.substring(theirs.lastIndexOf('.'))}'), isNull);
      expect(ContactCard.parse('hello'), isNull);
    });

    test('merging a card adds new fields and keeps the ones typed here', () {
      final c = Contact(npub: me.npub, fields: [ContactField('website', 'https://example.org')]);
      final card = ContactCard.parse(ContactCard.encode(me.privateKeyHex, name: 'Joao', fields: myFields))!;
      expect(mergeCard(c, card), 3);
      expect(c.name, 'Joao');
      expect(c.fields.length, 4);
      expect(mergeCard(c, card), 0);
    });
  });

  group('book', () {
    test('saves and loads, unknown keys included', () async {
      final dir = await Directory.systemTemp.createTemp('contacts');
      addTearDown(() => dir.delete(recursive: true));
      final b = ContactBook(dir.path);
      b.myName = 'Me';
      b.myFields.add(ContactField('website', 'https://me.example'));
      await b.put(Contact(npub: me.npub, name: 'Joao', fields: [ContactField('monero', monero)]));
      final raw = jsonDecode(await File('${dir.path}/contacts.json').readAsString()) as Map<String, Object?>;
      raw['groups'] = ['family'];
      await File('${dir.path}/contacts.json').writeAsString(jsonEncode(raw));

      final again = ContactBook(dir.path);
      await again.load();
      expect(again.contacts.single.name, 'Joao');
      expect(again.myName, 'Me');
      expect(again.whoHas('monero', monero)?.npub, me.npub);
      expect(again.withField('monero').length, 1);
      await again.save();
      final saved = jsonDecode(await File('${dir.path}/contacts.json').readAsString()) as Map<String, Object?>;
      expect(saved['groups'], ['family']);
    });
  });

  group('QR', () {
    final text = encodeReadableCard(me.privateKeyHex, 'Joao', myFields);

    test('reads a card from a camera plane with row padding', () {
      final (y, size) = qrPixels(text);
      const stride = 16;
      final padded = Uint8List((size + stride) * size);
      for (var r = 0; r < size; r++) {
        padded.setRange(r * (size + stride), r * (size + stride) + size, y, r * size);
      }
      expect(decodeLuminance(padded, size, size, size + stride), text);
    });

    test('cards the app shows are always found by the camera reader', () {
      for (var i = 0; i < 25; i++) {
        final k = NostrCrypto.generateKeyPair();
        final card = encodeReadableCard(k.privateKeyHex, 'Joao', myFields);
        expect(ContactCard.parse(card)?.npub, k.npub);
        expect(qrReadable(card), isTrue, reason: 'card $i');
      }
    });

    test('reads a card from a PNG and a JPEG', () {
      final (y, size) = qrPixels(text, scale: 5);
      final image = img.Image(width: size, height: size);
      for (var i = 0; i < size * size; i++) {
        final v = y[i];
        image.setPixelRgb(i % size, i ~/ size, v, v, v);
      }
      expect(decodeImageFile(img.encodePng(image)), text);
      expect(decodeImageFile(img.encodeJpg(image, quality: 85)), text);
      expect(decodeImageFile(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
