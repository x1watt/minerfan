import 'package:flutter_test/flutter_test.dart';
import 'package:minerfan/format.dart';
import 'package:minerfan/shop/payment_uri.dart';

const xmrAddress =
    '45GVTQ9WkX5UuDXW48EhPxgTYtrj4az7qjR1HqLh8VGHFHhS9A4unxTdruLGHpJCWZ44Q9yhtDnLLXR7T2ZgbhhTK48Yjji';
const cescAddress = 'CSqd18riXQjBy6vUNcnfi7kwHS7fDGUFE2';

void main() {
  test('amounts are written exactly, with no trailing zeros', () {
    expect(uriAmount(100000000, 12), '0.0001');
    expect(uriAmount(100000000000, 8), '1000');
    expect(uriAmount(1, 12), '0.000000000001');
    expect(uriAmount(250000000, 8), '2.5');
    expect(uriAmount(0, 8), '0');
  });

  test('a Monero code round trips', () {
    final code = buildPaymentUri(const PaymentRequest(
      chain: 'monero',
      address: xmrAddress,
      units: 100000000,
      label: 'Cafe Central',
      message: 'A7K3: 2x Espresso, 1x Pastel de nata',
    ));
    expect(code, startsWith('monero:$xmrAddress?'));
    expect(code, contains('tx_amount=0.0001'));
    expect(code, contains('%20'), reason: 'spaces are percent encoded, never a plus');
    final back = parsePaymentUri(code)!;
    expect(back.chain, 'monero');
    expect(back.address, xmrAddress);
    expect(back.units, 100000000);
    expect(back.label, 'Cafe Central');
    expect(back.message, 'A7K3: 2x Espresso, 1x Pastel de nata');
  });

  test('a Cryptoescudo code round trips and is BIP21 shaped', () {
    final code = buildPaymentUri(const PaymentRequest(
      chain: 'cryptoescudo',
      address: cescAddress,
      units: 100000000000,
      label: 'Cafe Central',
      message: 'A7K3: 2x Espresso',
    ));
    expect(code, startsWith('cryptoescudo:$cescAddress?'));
    expect(code, contains('amount=1000'));
    expect(code, contains('label=Cafe%20Central'));
    final back = parsePaymentUri(code)!;
    expect(back.units, 100000000000);
    expect(back.message, 'A7K3: 2x Espresso');
  });

  test('codes other wallets write are read too', () {
    // The ticker as a scheme, uppercase, slashes, and a plus for a space.
    final a = parsePaymentUri('CESC:$cescAddress?amount=12.5&message=Two+coffees')!;
    expect(a.chain, 'cryptoescudo');
    expect(a.units, 1250000000);
    expect(a.message, 'Two coffees');
    final b = parsePaymentUri('monero://$xmrAddress?tx_amount=1')!;
    expect(b.address, xmrAddress);
    expect(b.units, 1000000000000);
    // No amount at all: the payer types one.
    final c = parsePaymentUri('cryptoescudo:$cescAddress')!;
    expect(c.units, isNull);
    expect(c.message, '');
  });

  test('what cannot be paid says why', () {
    expect(parsePaymentUri('bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT'), isNull);
    expect(paymentUriProblem('bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT'),
        'This code is not a Monero or Cryptoescudo payment.');
    expect(paymentUriProblem('a shopping list'), 'This code is not a Monero or Cryptoescudo payment.');
    expect(paymentUriProblem('cryptoescudo:'), 'This payment code has no address.');
    expect(paymentUriProblem('cryptoescudo:$cescAddress?amount=lots'),
        'The amount in this code is not one this app can pay.');
    expect(paymentUriProblem('cryptoescudo:$cescAddress?amount=0'),
        'The amount in this code is not one this app can pay.');
    expect(paymentUriProblem('cryptoescudo:$cescAddress?amount=1&req-vault=x'),
        'This code asks for something this app does not support.');
    expect(paymentUriProblem('monero:$xmrAddress?tx_amount=1&tx_payment_id=0123456789abcdef'),
        'This code asks for a payment id, which this app cannot add.');
    expect(paymentUriProblem('monero:$xmrAddress?tx_amount=0.0001'), isNull);
  });

  test('only the coins with a scheme offer payment codes', () {
    expect(coinHasPaymentUri('monero'), isTrue);
    expect(coinHasPaymentUri('cryptoescudo'), isTrue);
    expect(coinHasPaymentUri('ethereum'), isFalse);
  });
}
