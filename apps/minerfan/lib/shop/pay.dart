// Paying a code, from a wallet in this app.
//
// The same shape as moderation/claims.dart's payForModeration, without
// the proofs: pick the wallet, unlock it if it has a password, hand the
// address and the amount to the coin's service, and give back the txid.

import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';
import 'payment_uri.dart';

/// Why a payment could not be made, in words for the person paying.
class PayError implements Exception {
  final String message;
  const PayError(this.message);
  @override
  String toString() => message;
}

/// Pays [req] from [wallet] and returns the transaction id. [units]
/// overrides the amount in the code (a code may leave it open).
Future<String> payRequest({
  required Wallet wallet,
  required PaymentRequest req,
  int? units,
  String? password,
}) async {
  final amount = units ?? req.units;
  if (amount == null || amount <= 0) throw const PayError('This code does not say how much to pay.');
  if (wallet.chain != req.chain) throw const PayError('That wallet holds another coin.');
  switch (wallet) {
    case MoneroWallet w when !w.viewOnly:
      final h = w.service.handle ?? (throw const PayError('The Monero wallet is not connected.'));
      if (w.hasPassword && await w.recoveryPhrase(password) == null) throw const PayError('Wrong password');
      final (txid, _) = await h.send(w.id, req.address, amount);
      return txid;
    case UtxoWallet w:
      final h = w.service.handle ?? (throw const PayError('The wallet is not connected.'));
      final xprv = await w.unlock(w.hasPassword ? password : null) ?? (throw const PayError('Wrong password'));
      return h.send(w.id, req.address, amount, xprv);
    default:
      throw const PayError('This wallet cannot send.');
  }
}
