import 'dart:isolate';
import 'dart:typed_data';

import 'package:xmr_core/xmr_core.dart';

import '../chains/monero_chain.dart';
import 'keyed_wallet.dart';
import 'wallet.dart';

bool validMoneroAddress(String a) {
  final p = MoneroAddress.parse(a.trim());
  return p != null && p.network == MoneroNetwork.mainnet;
}

/// A Monero wallet with its keys on this device: full (25 recovery words)
/// or view-only (address and private view key: sees incoming payments, not
/// spends). Our own wallet service scans the chain over P2P; sending gets
/// decoys from a node.
class MoneroWallet extends KeyedWallet {
  @override
  final String id;
  @override
  String label;
  @override
  final String address;
  final bool viewOnly;

  /// First block to scan: -1 for a new wallet (from the tip), 0 for the
  /// oldest block the light chain holds.
  final int birthday;
  final MoneroChain service;

  MoneroWallet({
    required this.id,
    required this.label,
    required this.address,
    required this.viewOnly,
    required this.birthday,
    required this.service,
    required super.secret,
    required super.deviceKey,
    super.backedUp,
  });

  static MoneroWallet fromJson(Map<String, Object?> m, MoneroChain service, Uint8List deviceKey) => MoneroWallet(
        id: m['id']! as String,
        label: (m['label'] as String?) ?? 'Monero',
        address: m['address']! as String,
        viewOnly: m['kind'] == 'view',
        birthday: (m['birthday'] as int?) ?? 0,
        service: service,
        secret: (m['secret']! as Map).cast<String, Object?>(),
        deviceKey: deviceKey,
        backedUp: (m['backedUp'] as bool?) ?? false,
      );

  @override
  Map<String, Object?> toJson() => {
        'id': id,
        'chain': chain,
        'kind': viewOnly ? 'view' : 'full',
        'label': label,
        'address': address,
        'birthday': birthday,
        'secret': secret,
        'backedUp': backedUp,
      };

  /// A new wallet: 25 recovery words from 32 random bytes.
  static Future<(String words, String address)> generate() => Isolate.run(() {
        final (account, seed) = MoneroAccount.generate();
        return (MoneroMnemonic.fromSeed(seed), account.address.encode());
      });

  /// The address of 25 recovery words, or null when they are not valid.
  static Future<String?> addressOfWords(String words) => Isolate.run(() {
        final seed = MoneroMnemonic.toSeed(words);
        return seed == null ? null : MoneroAccount.fromSeed(seed).address.encode();
      });

  /// Whether [viewKey] (hex) is the private view key of [address].
  static Future<bool> viewKeyMatches(String address, String viewKey) => Isolate.run(() {
        final a = MoneroAddress.parse(address.trim());
        final k = viewKey.trim().toLowerCase();
        if (a == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(k)) return false;
        final bytes = Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(k.substring(i, i + 2), radix: 16)]);
        return MoneroAccount.viewOnly(a, bytes) != null;
      });

  MoneroWalletStatus? get status => service.status?.wallets[id];
  bool get isOpen => service.isOpen(id);

  @override
  String get backupName => viewOnly ? 'private view key' : 'recovery words';
  @override
  String get chain => 'monero';
  @override
  String get chainName => 'Monero';
  @override
  String get symbol => 'XMR';

  @override
  List<WalletAsset> get assets {
    final s = status;
    return [WalletAsset('XMR', 'Monero', balance: s == null ? null : BigInt.from(s.balance + s.pendingIn), decimals: 12)];
  }

  @override
  bool get canReceive => true;
  @override
  bool get canSend => !viewOnly && (status?.unlocked ?? 0) > 0;
  @override
  String? get sendUnavailable {
    if (viewOnly) return 'A view-only wallet cannot send.';
    if (!isOpen) return hasPassword ? 'Unlock the wallet with its password.' : 'Opening the wallet';
    final s = status;
    if (s == null) return 'Connecting to the Monero network';
    if (s.unlocked > 0) return null;
    if (s.balance > 0) return 'Received coins can be spent after 10 blocks (mined ones after 60).';
    return 'Nothing to send yet.';
  }
}

/// A Monero address without keys (the miner's payout address, for
/// example): receive only. Adding its private view key makes it a
/// view-only [MoneroWallet].
class MoneroWatchWallet extends Wallet {
  @override
  final String id;
  @override
  String label;
  @override
  final String address;

  MoneroWatchWallet({required this.id, required this.label, required this.address});

  factory MoneroWatchWallet.fromJson(Map<String, Object?> m) =>
      MoneroWatchWallet(id: m['id']! as String, label: (m['label'] as String?) ?? 'Monero', address: m['address']! as String);

  @override
  Map<String, Object?> toJson() => {'id': id, 'chain': chain, 'label': label, 'address': address};

  @override
  String get chain => 'monero';
  @override
  String get chainName => 'Monero';
  @override
  String get symbol => 'XMR';

  @override
  List<WalletAsset> get assets => const [WalletAsset('XMR', 'Monero', decimals: 12)];

  @override
  bool get canReceive => true;
  @override
  bool get canSend => false;
  @override
  String? get sendUnavailable => 'Only the address is known. Add its private view key (menu) to see its balance.';
}
