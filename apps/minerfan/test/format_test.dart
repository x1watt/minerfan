import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/format.dart';

void main() {
  test('coin amounts format and parse exactly', () {
    expect(coins(2000000000), '20.00');
    expect(coins(123456789), '1.23456789');
    expect(coins(-150000), '-0.0015');
    expect(parseCoins('20'), 2000000000);
    expect(parseCoins('0.001'), 100000);
    expect(parseCoins('1,5'), 150000000);
    expect(parseCoins('.5'), 50000000);
    expect(parseCoins('0.123456789'), isNull); // more than 8 places
    expect(parseCoins('0'), isNull);
    expect(parseCoins('abc'), isNull);
    expect(parseCoins('1.5', decimals: 12), 1500000000000);
  });

  test('hashrates', () {
    expect(hashrate(12.5), '12.5 H/s');
    expect(hashrate(48000), '48.00 kH/s');
    expect(hashrate(610000), '610.00 kH/s');
    expect(hashrate(1.2e6), '1.20 MH/s');
  });
}
