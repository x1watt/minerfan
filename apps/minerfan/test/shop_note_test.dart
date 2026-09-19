import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/shop/paid_note.dart';
import 'package:xprs_wire/xprs_wire.dart';

void main() {
  test('a receipt round trips and names its bill', () {
    final k = NostrCrypto.generateKeyPair();
    final text = buildPaidNote(
      k.privateKeyHex,
      reference: 'A7K3',
      chain: 'cryptoescudo',
      txid: 'c22a1ce28e690dd54858d09ce57ec98b7406730c7a2c7f0dcf50491caa0853b4',
      units: 100000000000,
    );
    expect(text, startsWith(PaidNote.prefix));
    final note = parsePaidNote(text)!;
    expect(note.reference, 'A7K3');
    expect(note.chain, 'cryptoescudo');
    expect(note.txid, 'c22a1ce28e690dd54858d09ce57ec98b7406730c7a2c7f0dcf50491caa0853b4');
    expect(note.units, 100000000000);
    expect(note.npub, k.npub);
    expect(note.time, greaterThan(0));
  });

  test('a changed receipt is refused', () {
    final k = NostrCrypto.generateKeyPair();
    final text = buildPaidNote(k.privateKeyHex, reference: 'A7K3', chain: 'monero', txid: 'ab12', units: 5);
    // One character of the payload changed, signature untouched.
    final cut = text.lastIndexOf('.');
    final head = text.substring(0, cut);
    final swapped = head.substring(0, head.length - 1) + (head.endsWith('A') ? 'B' : 'A') + text.substring(cut);
    expect(parsePaidNote(swapped), isNull);
    expect(parsePaidNote('${text}x'), isNull, reason: 'a changed signature fails too');
  });

  test('anything that is not a receipt reads as nothing', () {
    expect(parsePaidNote('hello'), isNull);
    expect(parsePaidNote('minerfan-paid:1.'), isNull);
    expect(parsePaidNote('minerfan-paid:1.notbase64.notasignature'), isNull);
    expect(parsePaidNote('monero:45GVTQ?tx_amount=1'), isNull);
  });
}
