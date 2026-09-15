import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:test/test.dart';
import 'package:xprs_wire/xprs_wire.dart';

BigInt scalar(String hex) => BigInt.parse(hex, radix: 16);
Uint8List pub(BigInt d) => XprsCrypto.publicKeyXOnly(d);

void main() {
  final alice = NostrCrypto.generateKeyPair(), bob = NostrCrypto.generateKeyPair();
  final a = scalar(alice.privateKeyHex), b = scalar(bob.privateKeyHex);
  final aCall = alice.callsign, bCall = bob.callsign;

  XprsPacket message() {
    final head = XprsPacket.parse('t:message f:$aCall d:$bCall ts:${xprsNow()}')!;
    final built = xprsBuildDirect(
        head: head, text: 'hello', private: true, recipientKeyHex: bob.publicKeyHex, signingKey: a);
    return built.packets.single;
  }

  test('a direct message gets a signed receipt naming it, which releases it', () {
    final m = message();
    final r = XprsReceipt.compose(m, selfCallsign: bCall, signingKey: b)!;
    expect(r.type, 'receipt');
    expect(r['r'], xprsIdentifier(m));
    expect(r['d'], aCall);
    expect(xprsVerify(r, pub(b)), XprsSigState.verified);

    final released = XprsReceipt.release(r,
        selfCallsign: aCall, keyOf: (c) => c == bCall ? Uint8List.fromList(HEX.decode(bob.publicKeyHex)) : null);
    expect(released, (id: xprsIdentifier(m), state: 'ack'));
  });

  test('no receipt without a key, for a stranger, or for a message to someone else', () {
    final m = message();
    expect(XprsReceipt.compose(m, selfCallsign: bCall, signingKey: null), isNull);
    expect(XprsReceipt.compose(m, selfCallsign: bCall, signingKey: b, exchanged: false), isNull);
    expect(XprsReceipt.compose(m, selfCallsign: 'X1ZZZZ', signingKey: b), isNull);
  });

  test('a receipt that does not verify releases nothing', () {
    final r = XprsReceipt.compose(message(), selfCallsign: bCall, signingKey: b)!;
    final forged = r.with_('r', 'aaaaaa');
    Uint8List? keyOf(String c) => Uint8List.fromList(HEX.decode(bob.publicKeyHex));
    expect(XprsReceipt.release(forged, selfCallsign: aCall, keyOf: keyOf), isNull);
    expect(XprsReceipt.release(r, selfCallsign: aCall, keyOf: (_) => null), isNull);
  });

  test('ts: is the spec form', () {
    expect(xprsNow(DateTime.utc(2026, 8, 8, 14, 26, 40)), '2026-08-08_14:26:40');
  });
}
