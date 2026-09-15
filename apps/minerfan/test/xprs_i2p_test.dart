import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:i2p/i2p.dart' show I2pMessage, i2pBase32;
import 'package:minerfan/network/network_keys.dart';
import 'package:minerfan/network/xprs_i2p.dart';
import 'package:xprs_wire/xprs_wire.dart';

/// Two links wired back to back: what one sends arrives at the other as an
/// I2P message from the sender's address.
class _Pair {
  final aIn = StreamController<I2pMessage>.broadcast();
  final bIn = StreamController<I2pMessage>.broadcast();
  final a = XprsStation(NostrCrypto.generateKeyPair().privateKeyHex);
  final b = XprsStation(NostrCrypto.generateKeyPair().privateKeyHex);
  late final XprsI2pLink la, lb;
  final aLog = <String>[], bLog = <String>[];
  static final aHash = Uint8List(32)..[0] = 1, bHash = Uint8List(32)..[0] = 2;
  static final aB32 = '${i2pBase32(aHash)}.b32.i2p', bB32 = '${i2pBase32(bHash)}.b32.i2p';

  _Pair() {
    Future<bool> Function(String, int, Uint8List) wire(Uint8List from, Map<String, StreamController<I2pMessage>> to) =>
        (b32, port, payload) async {
          to[b32]!.add(I2pMessage(from, port, payload, DateTime.now()));
          return true;
        };
    final routes = {aB32: aIn, bB32: bIn};
    la = XprsI2pLink(aIn.stream, wire(aHash, routes), a, log: aLog.add);
    lb = XprsI2pLink(bIn.stream, wire(bHash, routes), b, log: bLog.add);
  }
}

Future<T> _first<T>(Stream<T> s) => s.first.timeout(const Duration(seconds: 30));

void main() {
  test('a sealed direct message opens at the recipient and a receipt comes back', () async {
    final p = _Pair();
    p.lb.addContact(p.a.npub, b32: _Pair.aB32);
    final got = _first(p.lb.received);
    final receipt = _first(p.la.receipts);
    final sent = await p.la.sendDirect(_Pair.bB32, p.b.npub, 'hello over i2p');
    expect(sent.sent, isTrue);
    final m = await got;
    expect(m.text, 'hello over i2p');
    expect(m.sealed, isTrue);
    expect(m.from, p.a.callsign);
    expect(m.packet.has('m'), isFalse, reason: 'the body travelled sealed');
    final r = await receipt;
    expect(r.id, xprsIdentifier(sent.body.identityPacket!));
    expect(r.state, 'ack');
  });

  test('a long message arrives in parts and is rejoined', () async {
    final p = _Pair();
    final text = List.generate(60, (i) => 'word$i').join(' ');
    final got = _first(p.lb.received);
    final sent = await p.la.sendDirect(_Pair.bB32, p.b.npub, text);
    expect(sent.body.packets.length, greaterThan(1));
    expect((await got).text, text);
  });

  test('a stranger gets no receipt', () async {
    final p = _Pair(); // b has not added a as a contact
    final got = _first(p.lb.received);
    await p.la.sendDirect(_Pair.bB32, p.b.npub, 'hi');
    await got;
    final receipts = <Object>[];
    p.la.receipts.listen(receipts.add);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(receipts, isEmpty);
  });

  test('a changed sealed body is dropped, the same packet twice arrives once', () async {
    final p = _Pair();
    final head = XprsPacket.parse('t:message f:${p.a.callsign} d:${p.b.callsign} ts:${xprsNow()}')!;
    final packet = xprsBuildDirect(
            head: head, text: 'once', private: true, recipientKeyHex: p.b.publicKeyHex, signingKey: p.a.scalar)
        .packets
        .single;
    final x = packet['x']!;
    final changed = packet.with_('x', '${x[0] == 'A' ? 'B' : 'A'}${x.substring(1)}');

    final inbox = <XprsInbound>[];
    p.lb.received.listen(inbox.add);
    await p.la.send(_Pair.bB32, [changed.encode()]);
    await p.la.send(_Pair.bB32, [packet.encode()]);
    await p.la.send(_Pair.bB32, [packet.encode()]);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(inbox.map((m) => m.text), ['once'],
        reason: 'the forged copy (same identifier) must not stand in for the real one');
    expect(p.bLog.any((l) => l.contains('forged')), isTrue);
  });

  test('a callsign that does not derive from its key teaches nothing', () async {
    final p = _Pair();
    final mallory = NostrCrypto.generateKeyPair();
    // Mallory announces a's callsign with their own key, then signs a message.
    final fake = xprsSign(
        XprsPacket.parse('t:identity f:${p.a.callsign} ts:${xprsNow()} k:${mallory.npub}')!,
        BigInt.parse(mallory.privateKeyHex, radix: 16));
    final msg = xprsSign(
        XprsPacket.parse('t:message f:${p.a.callsign} d:${p.b.callsign} ts:${xprsNow()} m:pay mallory')!,
        BigInt.parse(mallory.privateKeyHex, radix: 16));
    final inbox = <XprsInbound>[];
    p.lb.received.listen(inbox.add);
    p.bIn.add(I2pMessage(Uint8List(32), xprsI2pPort,
        Uint8List.fromList('${fake.encode()}\n${msg.encode()}'.codeUnits), DateTime.now()));
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(inbox, isEmpty);
  });

  test('a long plain message arrives in parts, verified once rejoined', () async {
    final p = _Pair();
    final text = List.generate(80, (i) => 'plain$i').join(' ');
    final head = XprsPacket.parse('t:message f:${p.a.callsign} d:${p.b.callsign} ts:${xprsNow()}')!;
    final built = xprsBuildDirect(head: head, text: text, private: false, signingKey: p.a.scalar);
    expect(built.packets.length, greaterThan(1));
    final got = _first(p.lb.received);
    await p.la.send(_Pair.bB32, [for (final x in built.packets) x.encode()]);
    final m = await got;
    expect(m.text, text);
    expect(m.sealed, isFalse);
  });

  test('a changed part of a plain message drops the whole message', () async {
    final p = _Pair();
    final text = List.generate(80, (i) => 'plain$i').join(' ');
    final head = XprsPacket.parse('t:message f:${p.a.callsign} d:${p.b.callsign} ts:${xprsNow()}')!;
    final parts = xprsBuildDirect(head: head, text: text, private: false, signingKey: p.a.scalar).packets;
    final changed = [
      parts.first.with_('m', 'somebody else wrote this'),
      ...parts.skip(1),
    ];
    final inbox = <XprsInbound>[];
    p.lb.received.listen(inbox.add);
    await p.la.send(_Pair.bB32, [for (final x in changed) x.encode()]);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(inbox, isEmpty);
    expect(p.bLog.any((l) => l.contains('does not verify')), isTrue);
  });

  test('a group post gets no receipt, and the identity line carries the nick', () async {
    final p = _Pair();
    p.lb.addContact(p.a.npub, b32: _Pair.aB32);
    p.la.nick = 'João Miner!';
    final post = xprsSign(
        XprsPacket.parse('t:message f:${p.a.callsign} d:MONERO ts:${xprsNow()} m:hash rates today?')!, p.a.scalar);
    final raw = <String>[];
    p.bIn.stream.listen((m) => raw.add(String.fromCharCodes(m.payload)));
    final got = _first(p.lb.received);
    await p.la.send(_Pair.bB32, [post.encode()]);
    expect((await got).text, 'hash rates today?');
    expect(raw.single.split('\n').first, contains('nick:Joao_Miner'));
    final receipts = <Object>[];
    p.la.receipts.listen(receipts.add);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(receipts, isEmpty);
  });
}
