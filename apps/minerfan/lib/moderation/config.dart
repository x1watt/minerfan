import 'package:xprs_wire/xprs_wire.dart';

/// Who runs the coin rooms' moderation (docs/architecture.md, "Coin
/// rooms"): the admin's station key, which grants the bought moderator
/// terms, and the address each room's rights are bought with.
///
/// Built in, and overridable at build time for tests:
///   flutter build ... --dart-define=ROOM_ADMIN_NPUB=npub1...
///     --dart-define=MOD_ADDR_MONERO=4... --dart-define=MOD_ADDR_CRYPTOESCUDO=C...
/// While the admin or a room's address is empty, that room has no moderation.
abstract final class ModerationConfig {
  /// The rooms' admin (X1WATT). Empty until the key is published.
  static const _adminNpub = String.fromEnvironment('ROOM_ADMIN_NPUB');

  static const _addresses = {
    'monero': String.fromEnvironment('MOD_ADDR_MONERO'),
    'cryptoescudo': String.fromEnvironment('MOD_ADDR_CRYPTOESCUDO'),
  };

  /// How long a claim is kept and resent before it is given up.
  static const claimLife = Duration(hours: 48);

  static final String? adminKeyHex = () {
    if (_adminNpub.isEmpty) return null;
    try {
      return NostrCrypto.decodeNpub(_adminNpub);
    } catch (_) {
      return null;
    }
  }();

  static String? get adminCallsign => adminKeyHex == null ? null : 'X1${NostrCrypto.deriveCallsign(adminKeyHex!)}';

  /// Where [coinId]'s room rights are bought, or null.
  static String? address(String coinId) {
    final a = _addresses[coinId] ?? '';
    return a.isEmpty ? null : a;
  }

  static bool on(String coinId) => adminKeyHex != null && address(coinId) != null;

  /// What a payment's proof signs: the room and the buyer's callsign, then
  /// the txid (so the proof speaks for that buyer and payment only).
  static String claimMessage(String room, String callsign) => 'minerfan moderator claim|$room|$callsign|';
}
