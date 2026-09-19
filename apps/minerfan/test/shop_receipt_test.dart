import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/shop/receipt.dart';

const price = 100000000000; // 1000 CESC
final billTime = DateTime(2026, 9, 19, 10).millisecondsSinceEpoch ~/ 1000;

Bill bill({Set<String>? before, int units = price}) => Bill(
      reference: 'A7K3',
      chain: 'cryptoescudo',
      address: 'CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2',
      units: units,
      description: 'Cafe Central A7K3: 2x Espresso',
      time: billTime,
      before: before,
    );

IncomingTx tx(String id, int amount, {int? height, int? time, bool coinbase = false}) =>
    IncomingTx(id, height, amount, time ?? billTime + 30, coinbase: coinbase);

void main() {
  test('an exact payment settles the bill, unconfirmed then confirmed', () {
    final seen = settle([tx('aa', price)], bill());
    expect(seen!.txid, 'aa');
    expect(seen.confirmed, isFalse);
    final mined = settle([tx('aa', price, height: 3204500)], bill());
    expect(mined!.confirmed, isTrue);
    expect(mined.received, price);
  });

  test('a tip settles it too, and too little does not', () {
    expect(settle([tx('aa', price + 20000000000)], bill())!.received, price + 20000000000);
    expect(settle([tx('aa', price - 1)], bill()), isNull);
  });

  test('money that was there before, or older than the bill, is not it', () {
    expect(settle([tx('old', price)], bill(before: {'old'})), isNull);
    expect(settle([tx('aa', price, time: billTime - 3600)], bill()), isNull);
    // A few minutes of clock difference between devices is allowed.
    expect(settle([tx('aa', price, time: billTime - 120)], bill()), isNotNull);
  });

  test('a mined block of exactly the price does not pay for the coffee', () {
    expect(settle([tx('block', price, coinbase: true)], bill()), isNull);
  });

  test('two bills of the same price cannot take one payment', () {
    final history = [tx('aa', price)];
    final first = settle(history, bill())!;
    final second = settle(history, bill(), claimed: {first.txid});
    expect(second, isNull, reason: 'the second bill waits for its own payment');
  });

  test('the customer\'s note names its payment, even among identical ones', () {
    final history = [tx('aa', price, time: billTime + 10), tx('bb', price, time: billTime + 20)];
    // Another bill already took the first payment.
    final mine = settle(history, bill(), claimed: {'aa'}, noteTxid: 'bb');
    expect(mine!.txid, 'bb');
    // A note about a payment the wallet does not have settles nothing.
    expect(settle(history, bill(), claimed: {'aa', 'bb'}, noteTxid: 'cc'), isNull);
  });

  test('the oldest matching payment is taken first', () {
    final history = [tx('late', price, time: billTime + 90), tx('early', price, time: billTime + 10)];
    expect(settle(history, bill())!.txid, 'early');
  });
}
