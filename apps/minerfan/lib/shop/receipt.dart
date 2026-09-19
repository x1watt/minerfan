// A bill on the counter, and how the app tells that it was paid.
//
// The shop watches the wallet that takes the coin. A payment settles a
// bill when it is new (the wallet did not have it when the bill was
// made), not a mining reward, not already counted for another bill, and
// at least what the bill asks for, so a tip settles it too.
//
// The reference written on the bill cannot be read off the chain: the
// description in a payment code stays in the wallet that pays. When the
// customer pays with minerfan their app hands the shop a signed note
// naming the bill and the transaction (shop/paid_note.dart), and that
// txid is then looked up here. Without a note the shop falls back to the
// amount and the time, and can always settle a bill by hand.

import '../wallets/monero_wallet.dart';
import '../wallets/utxo_wallet.dart';
import '../wallets/wallet.dart';

/// Money that came in, as both kinds of wallet report it.
class IncomingTx {
  final String txid;

  /// Null while it is still only in the mempool.
  final int? height;

  /// Smallest units received by this wallet.
  final int received;

  /// Seconds since the epoch, when it was first seen.
  final int time;

  final bool coinbase;

  const IncomingTx(this.txid, this.height, this.received, this.time, {this.coinbase = false});
}

/// What [w] has received, newest entries included, or an empty list when
/// the wallet has no status yet.
List<IncomingTx> incomingOf(Wallet w) {
  switch (w) {
    case MoneroWallet():
      return [
        for (final e in w.status?.history ?? const [])
          if (e.received > 0) IncomingTx(e.txid, e.height, e.received, e.time, coinbase: e.coinbase),
      ];
    case UtxoWallet():
      return [
        for (final e in w.status?.history ?? const [])
          if (e.received > 0) IncomingTx(e.txid, e.height, e.received, e.time, coinbase: e.coinbase),
      ];
    default:
      return const [];
  }
}

/// A bill: what is owed, in which coin, to which address.
class Bill {
  final String reference;
  final String chain;
  final String address;
  final int units;
  final String description;

  /// Seconds since the epoch, when the bill was made.
  final int time;

  /// The transactions the wallet already had when the bill was made: none
  /// of them can pay it.
  final Set<String> before;

  Bill({
    required this.reference,
    required this.chain,
    required this.address,
    required this.units,
    required this.description,
    required this.time,
    Set<String>? before,
  }) : before = before ?? {};
}

/// How a bill was settled.
class Settled {
  final String txid;

  /// True once the payment is in a block.
  final bool confirmed;

  /// What actually arrived, which may be more than the bill (a tip).
  final int received;

  const Settled(this.txid, this.confirmed, this.received);
}

/// Five minutes of slack between this device's clock and the time a peer
/// first saw the payment.
const _clockSlack = 300;

/// The payment that settles [bill], or null while none has.
///
/// [claimed] holds the transactions other bills already took, so two
/// coffees at the same price cannot both be settled by one payment.
/// [noteTxid] is the transaction the customer's app says it sent, which
/// is believed only if the wallet really has it.
Settled? settle(
  List<IncomingTx> history,
  Bill bill, {
  Set<String> claimed = const {},
  String? noteTxid,
}) {
  IncomingTx? best;
  for (final tx in history) {
    if (tx.coinbase) continue;
    if (bill.before.contains(tx.txid)) continue;
    if (tx.received < bill.units) continue;
    if (tx.time < bill.time - _clockSlack) continue;
    if (tx.txid == noteTxid) {
      // The customer's app named this one: it wins, claimed by another
      // bill or not, because we know which bill it belongs to.
      return Settled(tx.txid, tx.height != null, tx.received);
    }
    if (claimed.contains(tx.txid)) continue;
    if (best == null || tx.time < best.time) best = tx;
  }
  return best == null ? null : Settled(best.txid, best.height != null, best.received);
}

/// What Monero holds in the mempool for this wallet, which is the only
/// sign of an unconfirmed Monero payment (it carries no txid).
int pendingInOf(Wallet w) => w is MoneroWallet ? (w.status?.pendingIn ?? 0) : 0;
